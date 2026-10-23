defmodule Platform.Social.RenderJob do
  @moduledoc """
  One clip render, run by `Platform.Social.RenderQueue` in a task under
  Social's own Task.Supervisor (Social 5/7), never in a LiveView,
  controller or tool-call process.

  Steps, every failure ending the clip `failed` with a readable `error`:

    1. stamp `render_started_at`, bump `attempts`;
    2. re-check the profile's project is in its org (Files storage target);
    3. fetch the source into a per-job tmp dir (`Platform.Social.Source`);
    4. refuse an end past the source's length, naming both;
    5. snap the requested times to sentences (`Platform.Social.Segmenter`),
       writing `requested_*` and the snapped `start_s`/`end_s`;
    6. pre-check member 2's `Platform.Social.MediaRules` for every target
       platform on the EXPECTED length (clip + end card) BEFORE encoding;
    7. render with `Platform.Social.Renderer.impl/0`;
    8. post-check MediaRules on the real output;
    9. store the MP4 in Files under the profile's project
       (`ingest_intent: "human_only"`: video has no extractor);
   10. in one transaction set `render_file_id`, `duration_s`, `width`,
       `height`, `byte_size`, `rendered_at`, status `rendered`, and review
       `pending` unless the clip is already approved (Clip Studio 1/9).

  The tmp dir is always removed. A Files row written before a later failure
  is deleted again, so a failed clip leaves no orphan.

  The job reads its clip and profile directly: the caller's scope was
  checked by `Platform.Social.render_clip/3` before enqueue, and every
  core read (Files, projects) goes through core's public API.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{Account, Brand, Clip, MediaRules, Profile, Renderer, Segmenter, Source}

  @expected_card_s 2.0

  @doc "Runs the render for `clip_id`. Returns `{:ok, clip}` or `{:error, message}` (the clip is updated either way)."
  @spec run(Ecto.UUID.t()) :: {:ok, Clip.t()} | {:error, String.t()}
  def run(clip_id) do
    with %Clip{} = clip <- Repo.get(Clip, clip_id),
         {:ok, clip} <- start(clip) do
      dir = tmp_dir(clip.id)

      try do
        case work(clip, dir) do
          {:ok, clip} ->
            {:ok, clip}

          {:error, message} ->
            fail(clip.id, message)
            {:error, message}
        end
      rescue
        e ->
          message = "render crashed: " <> Exception.message(e)
          fail(clip.id, message)
          {:error, message}
      after
        File.rm_rf(dir)
      end
    else
      nil -> {:error, "the clip no longer exists"}
      {:error, message} -> {:error, message}
    end
  end

  @doc "Marks a clip failed with `message` (used by the queue for a crashed task too)."
  @spec fail(Ecto.UUID.t(), String.t()) :: :ok
  def fail(clip_id, message) do
    case Repo.get(Clip, clip_id) do
      nil ->
        :ok

      clip ->
        {:ok, clip} =
          clip
          |> Clip.render_changeset(%{status: "failed", error: String.slice(message, 0, 4000)})
          |> Repo.update()

        Platform.Social.broadcast_clip(clip)
        :ok
    end
  end

  defp start(%Clip{} = clip) do
    clip
    |> Clip.render_changeset(%{
      status: "rendering",
      attempts: (clip.attempts || 0) + 1,
      render_started_at: DateTime.utc_now(),
      error: nil
    })
    |> Repo.update()
    |> case do
      {:ok, clip} -> {:ok, clip}
      {:error, _} -> {:error, "could not start the render"}
    end
  end

  defp tmp_dir(clip_id) do
    base = Application.get_env(:social, :render_tmp_dir) || System.tmp_dir!()
    dir = Path.join(base, "social-render-#{clip_id}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp work(clip, dir) do
    profile = Repo.get!(Profile, clip.profile_id)

    with {:ok, project} <- Platform.Social.render_project(profile),
         {:ok, fetched} <- Source.for_clip(clip).fetch(clip, profile, dir),
         duration = source_duration(fetched),
         req_start = clip.requested_start_s || clip.start_s,
         req_end = clip.requested_end_s || clip.end_s,
         :ok <- within_source(req_end, fetched.offset_s, duration),
         sentences = Segmenter.sentences(fetched.segments),
         {:ok, snapped} <- snap(sentences, req_start, req_end, fetched.offset_s, duration),
         {:ok, clip} <- save_times(clip, req_start, req_end, snapped),
         accounts = accounts(profile),
         :ok <- media_check(clip.platforms, accounts, expected(snapped), nil),
         out = Path.join(dir, "clip.mp4"),
         {:ok, rendered} <- render(clip, profile, fetched, snapped, sentences, out, dir),
         :ok <- media_check(clip.platforms, accounts, rendered.duration_s, rendered.byte_size),
         {:ok, file} <- store(project, clip, rendered) do
      finish(clip, file, rendered)
    end
  end

  # ── Steps ────────────────────────────────────────────────────────────

  defp source_duration(%{video_path: path}) do
    case Renderer.Ffmpeg.probe(path) do
      {:ok, %{duration_s: d}} -> d
      _ -> nil
    end
  end

  defp within_source(_req_end, _offset, nil), do: :ok

  defp within_source(req_end, offset, duration) do
    source_end = offset + duration

    if req_end > source_end + 0.05,
      do:
        {:error,
         "the clip ends at #{fmt(req_end)}s but the source video is only #{fmt(source_end)}s long"},
      else: :ok
  end

  defp snap(sentences, req_start, req_end, offset, duration) do
    opts = if duration, do: [duration_s: offset + duration], else: []

    case Segmenter.snap(sentences, req_start, req_end, opts) do
      {:ok, snapped} ->
        {:ok, snapped}

      {:error, :invalid_range} ->
        {:error,
         "the requested range #{fmt(req_start)}s-#{fmt(req_end)}s cannot be snapped to the transcript: " <>
           "it must run 5 to 600 seconds and stay after its start once moved to sentence boundaries"}
    end
  end

  defp save_times(clip, req_start, req_end, snapped) do
    clip
    |> Clip.render_changeset(%{
      requested_start_s: req_start,
      requested_end_s: req_end,
      start_s: snapped.start_s,
      end_s: snapped.end_s
    })
    |> Repo.update()
    |> case do
      {:ok, clip} -> {:ok, clip}
      {:error, cs} -> {:error, "could not save the snapped times: #{inspect(cs.errors)}"}
    end
  end

  defp expected(snapped), do: snapped.end_s - snapped.start_s + @expected_card_s

  defp accounts(profile) do
    from(a in Account, where: a.profile_id == ^profile.id and is_nil(a.archived_at))
    |> Repo.all()
  end

  # Member 2's rules, per target platform, on one MP4 of the given length
  # and size (nil = not yet known).
  defp media_check(platforms, accounts, duration_s, byte_size) do
    item = %{content_type: "video/mp4", duration_s: duration_s, byte_size: byte_size}

    messages =
      Enum.flat_map(platforms || [], fn platform ->
        account = Enum.find(accounts, &(&1.platform == platform))

        case MediaRules.check(platform, account, [item]) do
          :ok -> []
          {:error, messages} -> messages
        end
      end)

    case messages do
      [] -> :ok
      _ -> {:error, Enum.join(messages, "; ")}
    end
  end

  defp render(clip, profile, fetched, snapped, sentences, out, dir) do
    offset = fetched.offset_s
    brand = Brand.resolve(profile)

    input = %{
      source_path: fetched.video_path,
      start_s: snapped.start_s - offset,
      end_s: snapped.end_s - offset,
      words:
        sentences
        |> Enum.flat_map(& &1.words)
        |> Enum.map(&%{&1 | start_s: &1.start_s - offset, end_s: &1.end_s - offset}),
      speakers: speakers(sentences, offset),
      crop_x: clip.crop_x || 0.5,
      brand: brand,
      logo_path: logo(brand["logo_file_id"], profile, dir),
      out_path: out
    }

    case Renderer.impl().render(input) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, message} -> {:error, message}
      other -> {:error, "the renderer returned #{inspect(other)}"}
    end
  end

  defp speakers(sentences, offset) do
    sentences
    |> Enum.reject(&is_nil(&1.speaker))
    |> Enum.map(&%{start_s: &1.start_s - offset, name: &1.speaker})
  end

  # The logo is read through Files; when it cannot be, the card simply has
  # no logo.
  defp logo(nil, _profile, _dir), do: nil

  defp logo(file_id, profile, dir) do
    with %{} = file <- Platform.Files.get_file(file_id),
         true <- file.project_id == profile.project_id or file_in_org?(file, profile.org_id),
         {:ok, stream} <- Platform.Files.Storage.get(file.storage_key) do
      path = Path.join(dir, "logo" <> Path.extname(file.original_filename || ".png"))
      stream |> Stream.into(File.stream!(path)) |> Stream.run()
      path
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp file_in_org?(%{project_id: project_id}, org_id) when is_binary(project_id) do
    match?(%{org_id: ^org_id}, Platform.Tasks.get_project(project_id))
  end

  defp file_in_org?(_, _), do: false

  defp store(project, clip, rendered) do
    filename = "clip-#{clip.id}.mp4"

    with {:ok, %{storage_key: key, content_hash: hash, byte_size: size}} <-
           Platform.Files.Storage.put({:path, rendered.path}, project.id, filename: filename),
         {:ok, file} <-
           Platform.Files.create_file(%{
             project_id: project.id,
             org_id: project.org_id,
             name: filename,
             original_filename: filename,
             content_type: "video/mp4",
             byte_size: size,
             storage_key: key,
             content_hash: hash,
             ingest_intent: "human_only"
           }) do
      {:ok, file}
    else
      {:error, reason} -> {:error, "could not store the render in Files: #{inspect(reason)}"}
    end
  end

  defp finish(clip, file, rendered) do
    result =
      Repo.transaction(fn ->
        clip
        |> Clip.render_changeset(%{
          status: "rendered",
          render_file_id: file.id,
          duration_s: rendered.duration_s,
          width: rendered.width,
          height: rendered.height,
          byte_size: rendered.byte_size,
          rendered_at: DateTime.utc_now(),
          error: nil
        })
        |> to_review(clip)
        |> Repo.update()
        |> case do
          {:ok, clip} -> clip
          {:error, cs} -> Repo.rollback(cs)
        end
      end)

    case result do
      {:ok, clip} ->
        Platform.Social.broadcast_clip(clip)
        {:ok, clip}

      {:error, reason} ->
        # A system action, attributed to the clip whose render it was.
        _ = Platform.Files.delete_file(%{id: clip.id, type: "system"}, file)
        {:error, "could not record the render: #{inspect(reason)}"}
    end
  end

  # Clip Studio 1/9: a new render goes to review as pending, unless the clip
  # is already approved (a forced re-render of an approved clip stays so).
  defp to_review(changeset, %Clip{review_status: "approved"}), do: changeset
  defp to_review(changeset, _clip), do: Clip.review_changeset(changeset, :reset_pending)

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
end
