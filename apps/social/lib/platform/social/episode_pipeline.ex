defmodule Platform.Social.EpisodePipeline do
  @moduledoc """
  Persistent activation boundary for automatic episode discovery (task 01a17e37).
  The first sweep records a cutoff once per configured profile and pipeline
  version. Restarts retain it, so missed uploads are recovered without replaying
  the historical catalog. A new version must be explicitly activated.

  The episode's pick plan and child identities are persisted under the parent
  ClipJobs row lock. Children use the canonical headline-review/1 runner and
  immutable version completion; the parent completes only after its children.
  Generated headline text remains local to the runner.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{ClipJob, ClipJobs}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "social_episode_pipelines" do
    belongs_to(:profile, Platform.Social.Profile)
    field(:version, :string)
    field(:activated_at, :utc_datetime_usec)
    timestamps()
  end

  @doc "Bounded background reconciliation; timestamps are runner heartbeats, never browser activity."
  def reconcile_jobs(now \\ DateTime.utc_now(), opts \\ []) do
    queued_before = DateTime.add(now, -Keyword.get(opts, :queued_timeout_s, 3600), :second)
    running_before = DateTime.add(now, -Keyword.get(opts, :runner_timeout_s, 1800), :second)
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(100)

    ids =
      Repo.all(
        from(j in ClipJob,
          where: j.kind == "episode" or fragment("?->>'episode_job_id' IS NOT NULL", j.payload),
          where:
            (j.status == "queued" and j.updated_at < ^queued_before) or
              (j.status in ["claimed", "running"] and j.updated_at < ^running_before),
          order_by: [asc: j.updated_at, asc: j.id],
          limit: ^limit,
          select: j.id
        )
      )

    Enum.flat_map(ids, fn id ->
      case Repo.transaction(fn ->
             job =
               Repo.one(from(j in ClipJob, where: j.id == ^id, lock: "FOR UPDATE SKIP LOCKED"))

             if job &&
                  ((job.status == "queued" &&
                      DateTime.compare(job.updated_at, queued_before) == :lt) ||
                     (job.status in ["claimed", "running"] &&
                        DateTime.compare(job.updated_at, running_before) == :lt)) do
               code = if job.status == "queued", do: "RUNNER_UNAVAILABLE", else: "RUNNER_TIMEOUT"
               job |> ClipJob.finish_changeset(:failed, code) |> Repo.update!()
             end
           end) do
        {:ok, %ClipJob{} = job} ->
          ClipJobs.broadcast_job(job)
          child_failed(job)
          [job]

        _ ->
          []
      end
    end)
  end

  @doc false
  def child_failed(%ClipJob{payload: %{"episode_job_id" => parent_id}} = child) do
    # A terminal child failure marks its parent incomplete without touching any
    # successful pending clip, its immutable render, or still-running siblings.
    now = DateTime.utc_now()

    from(j in ClipJob,
      where: j.id == ^parent_id and j.profile_id == ^child.profile_id and j.kind == "episode",
      where: j.status in ["queued", "claimed", "running"],
      select: j
    )
    |> Repo.update_all(
      set: [status: "failed", error: "EPISODE_INCOMPLETE", finished_at: now, updated_at: now]
    )
    |> case do
      {1, [parent]} -> ClipJobs.broadcast_job(parent)
      _ -> :ok
    end
  end

  def child_failed(_), do: :ok

  def changeset(pipeline, attrs) do
    pipeline
    |> cast(attrs, [:profile_id, :version, :activated_at])
    |> validate_required([:profile_id, :version, :activated_at])
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :version])
  end
end
