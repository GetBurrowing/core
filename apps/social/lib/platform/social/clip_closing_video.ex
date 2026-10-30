defmodule Platform.Social.ClipClosingVideo do
  @moduledoc "Human-owned show closing videos and durable discovery exclusion (task 01a18ab6)."
  import Ecto.Query
  alias Platform.{Files, Repo, Social}
  alias Platform.Files.File, as: SourceFile
  alias Platform.Social.{ClosingAsset, ClosingVideoSettings, ClipJob, Profile, Toolchain}
  alias Platform.Social.Renderer.Ffmpeg

  @max_bytes 200 * 1024 * 1024
  @types ~w(video/mp4 video/quicktime video/webm)
  def max_bytes, do: @max_bytes
  def content_types, do: @types

  # Both discovery enqueue and registration lock this exact row. A scan that
  # saw a pre-registration candidate must recheck eligibility after taking it.
  def lock_file(id) do
    if uuid?(id), do: Repo.one(from(f in SourceFile, where: f.id == ^id, lock: "FOR UPDATE"))
  end

  def asset?(id), do: Repo.exists?(from(a in ClosingAsset, where: a.file_id == ^id))

  def list(org_id, profile_id, user_id) do
    with {:ok, profile, _project} <- authorize(org_id, profile_id, user_id) do
      {:ok,
       Files.list_files_for_project(profile.project_id, limit: nil)
       |> Enum.filter(
         &(Files.finalized_upload?(&1) and &1.content_type in @types and
             &1.byte_size <= @max_bytes and &1.org_id in [nil, profile.org_id])
       )}
    end
  end

  def save(org_id, profile_id, user_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      {profile, _project} = authorized!(org_id, profile_id, user_id)

      changeset =
        ClosingVideoSettings.changeset(profile.closing_video || %ClosingVideoSettings{}, attrs)

      settings =
        case Ecto.Changeset.apply_action(changeset, :update) do
          {:ok, settings} -> settings
          {:error, error} -> Repo.rollback(error)
        end

      if settings.file_id do
        file = lock_file(settings.file_id)

        case register(profile, file) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      # Probe/download can take time; do not rely on the initial human lookup.
      {fresh_profile, _} = authorized!(org_id, profile_id, user_id)
      if fresh_profile.project_id != profile.project_id, do: Repo.rollback(:project_changed)

      fresh_profile
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:closing_video, Map.from_struct(settings))
      |> Repo.update!()
    end)
  end

  def save(_, _, _, _), do: {:error, :invalid_settings}

  def remove(org_id, profile_id, user_id),
    do: save(org_id, profile_id, user_id, %{file_id: nil, enabled: false, audio: :mute})

  @doc "Picker upload: registration commits even if the human never saves the show default."
  def upload(org_id, profile_id, user_id, bytes, filename, type) do
    with {:ok, _profile, project} <- authorize(org_id, profile_id, user_id),
         :ok <- valid_bytes(bytes, type),
         true <-
           (is_binary(filename) and String.trim(filename) != "") || {:error, :invalid_filename} do
      Files.add_bytes_registered(
        project,
        bytes,
        filename,
        type,
        [uploaded_by_user_id: user_id],
        fn file ->
          with {:ok, profile, _} <- authorize(org_id, profile_id, user_id),
               {:ok, asset} <- register(profile, lock_file(file.id)),
               {:ok, current, _} <- authorize(org_id, profile_id, user_id),
               true <- current.project_id == file.project_id || {:error, :project_changed} do
            {:ok, %{file: file, asset: asset}}
          end
        end
      )
    end
  end

  defp register(profile, file) do
    with :ok <- eligible_file(profile, file),
         true <-
           not Repo.exists?(
             from(j in ClipJob, where: j.source_file_id == ^file.id and j.kind == "episode")
           ) ||
             {:error, :already_an_episode},
         {:ok, measurements} <- measure(file) do
      values =
        Map.merge(measurements, %{
          org_id: profile.org_id,
          project_id: profile.project_id,
          profile_id: profile.id,
          file_id: file.id,
          content_hash: file.content_hash,
          byte_size: file.byte_size
        })

      %ClosingAsset{}
      |> Ecto.Changeset.change(values)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :file_id])
      |> case do
        {:ok, _} -> {:ok, Repo.get_by!(ClosingAsset, profile_id: profile.id, file_id: file.id)}
        error -> error
      end
    end
  end

  defp eligible_file(profile, %SourceFile{} = file) do
    cond do
      file.project_id != profile.project_id or file.org_id not in [nil, profile.org_id] ->
        {:error, :foreign_asset}

      not Files.finalized_upload?(file) ->
        {:error, :asset_unavailable}

      file.content_type not in @types ->
        {:error, :not_a_video}

      file.byte_size > @max_bytes ->
        {:error, :video_too_large}

      true ->
        :ok
    end
  end

  defp eligible_file(_, _), do: {:error, :asset_unavailable}

  defp measure(file) do
    with {:ok, path} <- Files.Extractor.local_path(file),
         {:ok, %{size: actual_size}} <- File.stat(path),
         true <- actual_size == file.byte_size and actual_size > 0 and actual_size <= @max_bytes,
         {:ok, bytes} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == file.content_hash,
         {:ok, m} <- Ffmpeg.probe(path),
         true <- supported_container?(m.format_name, file.content_type),
         true <-
           is_number(m.duration_s) and m.duration_s > 0 and m.duration_s < 1.0e100 and
             is_integer(m.width) and m.width > 0 and is_integer(m.height) and m.height > 0,
         {:ok, ffmpeg} <- Toolchain.fetch(:ffmpeg),
         {:ok, _} <-
           Ffmpeg.run(
             ffmpeg,
             [
               "-v",
               "error",
               "-xerror",
               "-i",
               path,
               "-map",
               "0:v:0",
               "-frames:v",
               "1",
               "-f",
               "null",
               "-"
             ],
             60_000
           ) do
      {:ok, Map.take(m, [:duration_s, :width, :height])}
    else
      _ -> {:error, :invalid_video}
    end
  rescue
    _ -> {:error, :invalid_video}
  end

  defp supported_container?(name, type) when is_binary(name) do
    formats = String.split(name, ",")

    case type do
      "video/webm" -> "webm" in formats
      type when type in ["video/mp4", "video/quicktime"] -> "mov" in formats or "mp4" in formats
      _ -> false
    end
  end

  defp supported_container?(_, _), do: false

  defp valid_bytes(bytes, type) do
    cond do
      type not in @types -> {:error, :not_a_video}
      not is_binary(bytes) or byte_size(bytes) == 0 -> {:error, :invalid_video}
      byte_size(bytes) > @max_bytes -> {:error, :video_too_large}
      true -> :ok
    end
  end

  defp authorized!(org_id, profile_id, user_id) do
    case authorize(org_id, profile_id, user_id) do
      {:ok, profile, project} -> {profile, project}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize(org_id, profile_id, user_id) do
    with true <- uuid?(org_id) and uuid?(profile_id) and uuid?(user_id),
         %Profile{} = profile <- Social.get_profile(org_id, profile_id),
         :ok <- Social.approver_check(org_id, profile, user_id),
         true <- uuid?(profile.project_id),
         %{org_id: ^org_id, archived_at: nil} = project <-
           Repo.get(Platform.Tasks.Project, profile.project_id) do
      {:ok, profile, project}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp uuid?(id), do: Platform.UUID.valid?(id)
end
