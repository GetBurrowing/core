defmodule Platform.Social.EpisodeDiscovery do
  @moduledoc """
  Reconciles storage-ready episode uploads into runner jobs (task 01a17e37).

  Configure `config :social, :episode_discovery, profile_ids: [htc_profile_id]`
  or `SOCIAL_EPISODE_PROFILE_IDS` (comma-separated UUIDs) on the background
  runtime. The first scan durably activates each profile; existing uploads
  stay historical. Repeated scans and restarts reuse the activation boundary.
  This deliberately polls committed Files rows instead of ingest events: a
  video may be `human_only`, and presigned reservation is not byte completion.

  Provenance requires a human uploader. Runner-generated files have no human
  uploader, and registered clip renders, post covers and profile brand assets
  are additionally excluded. Shared source assets such as an outro can be
  registered in `asset_file_ids` in the same configuration; names are never
  used to guess whether a file is an episode.
  """
  use GenServer
  import Ecto.Query
  require Logger

  alias Platform.Repo
  alias Platform.Files.File, as: SourceFile
  alias Platform.Social.{Clip, ClipJob, ClipJobs, ClipRender, EpisodePipeline, Post, Profile}

  @version "episode-v1"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep, :infinity)

  @doc "Records first activation only; never moves the cutoff during a restart."
  def activate(%Profile{} = profile, now \\ DateTime.utc_now()) do
    attrs = %{profile_id: profile.id, version: @version, activated_at: now}

    with {:ok, _} <-
           %EpisodePipeline{}
           |> EpisodePipeline.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :version]) do
      {:ok, Repo.get_by!(EpisodePipeline, profile_id: profile.id, version: @version)}
    end
  end

  @doc false
  def configured_profile_ids do
    case Keyword.get(config(), :profile_ids) do
      nil -> System.get_env("SOCIAL_EPISODE_PROFILE_IDS", "") |> String.split(",", trim: true)
      ids when is_list(ids) -> ids
    end
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
  end

  @doc "One reconciliation, exposed for deterministic fake-runner tests."
  def sweep(profile_ids, now \\ DateTime.utc_now()) do
    Enum.flat_map(profile_ids, fn id ->
      # A misconfigured cross-tenant project/profile pairing never consumes files.
      profile =
        Repo.one(
          from(p in Profile,
            join: project in assoc(p, :project),
            where: p.id == ^id and p.org_id == project.org_id and is_nil(project.archived_at),
            select: p
          )
        )

      with %Profile{} <- profile,
           {:ok, pipeline} <- activate(profile, now) do
        seen =
          Repo.all(
            from(j in ClipJob,
              where: j.episode_pipeline_id == ^pipeline.id,
              select: j.source_file_id
            )
          )
          |> MapSet.new()

        Platform.Files.list_recent_files_for_projects([profile.project_id],
          since: pipeline.activated_at,
          limit: nil
        )
        |> Enum.reject(&MapSet.member?(seen, &1.id))
        |> Enum.filter(&eligible?(&1, profile, pipeline))
        |> Enum.map(&ClipJobs.enqueue_episode(pipeline.id, &1.id))
      else
        _ -> [{:error, :episode_profile_unavailable}]
      end
    end)
  end

  @doc false
  def eligible?(%SourceFile{} = file, %Profile{} = profile, %EpisodePipeline{} = pipeline) do
    pipeline.profile_id == profile.id and pipeline.version == @version and
      profile.project_id == file.project_id and file.org_id in [nil, profile.org_id] and
      Platform.Files.finalized_upload?(file) and
      is_binary(file.uploaded_by_user_id) and String.starts_with?(file.content_type, "video/") and
      DateTime.compare(file.inserted_at, pipeline.activated_at) != :lt and
      not asset?(file.id, profile)
  end

  defp asset?(id, profile) do
    id in Keyword.get(config(), :asset_file_ids, []) or
      id in brand_file_ids(profile.brand) or
      Repo.exists?(from(c in Clip, where: c.render_file_id == ^id)) or
      Repo.exists?(from(r in ClipRender, where: r.file_id == ^id)) or
      Repo.exists?(from(p in Post, where: p.cover_file_id == ^id))
  end

  defp brand_file_ids(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.ends_with?(key, "file_id"), do: [value], else: []

      {_key, nested} when is_map(nested) ->
        brand_file_ids(nested)

      _ ->
        []
    end)
  end

  defp brand_file_ids(_), do: []

  @impl true
  def init(opts) do
    state = %{
      profile_ids: Keyword.get(opts, :profile_ids),
      interval_ms: Keyword.get(opts, :interval_ms, Keyword.get(config(), :interval_ms, 15_000)),
      notify: Keyword.get(opts, :notify)
    }

    schedule(state)

    if Keyword.get(opts, :boot_sweep, Keyword.get(config(), :boot_sweep, true)),
      do: {:ok, state, {:continue, :sweep}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:sweep, state) do
    reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    reconcile(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, reconcile(state), state}

  defp reconcile(state) do
    EpisodePipeline.reconcile_jobs()
    results = sweep(state.profile_ids || configured_profile_ids())

    if Enum.any?(results, &match?({:error, _}, &1)),
      do: Logger.error("[social] episode discovery enqueue failed")

    if state.notify, do: send(state.notify, {:episode_discovery, results})
    results
  end

  defp schedule(%{interval_ms: :infinity}), do: :ok
  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval_ms)
  defp config, do: Application.get_env(:social, :episode_discovery, [])
end
