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
    # Decode before taking the profile lock. Human revocation/project changes
    # during a slow probe must remain observable at the final authorization.
    with {:ok, initial, _} <- authorize(org_id, profile_id, user_id),
         {:ok, requested} <- settings(initial, attrs),
         {:ok, verified} <- prepare_asset(initial, requested.file_id) do
      Repo.transaction(fn ->
        lock_profile(profile_id)
        {profile, _project} = authorized!(org_id, profile_id, user_id)
        if profile.project_id != initial.project_id, do: Repo.rollback(:project_changed)

        settings =
          case settings(profile, attrs) do
            {:ok, settings} -> settings
            {:error, reason} -> Repo.rollback(reason)
          end

        if settings.file_id != requested.file_id, do: Repo.rollback(:settings_changed)

        if settings.file_id do
          case register(profile, lock_file(settings.file_id), verified) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        {fresh_profile, _} = authorized!(org_id, profile_id, user_id)

        fresh_profile
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:closing_video, Map.from_struct(settings))
        |> Repo.update!()
      end)
    end
  end

  def save(_, _, _, _), do: {:error, :invalid_settings}

  defp settings(profile, attrs) do
    ClosingVideoSettings.changeset(profile.closing_video || %ClosingVideoSettings{}, attrs)
    |> Ecto.Changeset.apply_action(:update)
  end

  defp prepare_asset(_profile, nil), do: {:ok, nil}

  defp prepare_asset(profile, id) do
    file = Files.get_file(id)

    with :ok <- eligible_file(profile, file),
         {:ok, measurements} <- measure(file) do
      {:ok,
       {Map.take(file, [:id, :project_id, :org_id, :content_hash, :byte_size, :content_type]),
        measurements}}
    end
  end

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

  @doc "Serialize show-default changes and render enqueue on this profile row. Caller owns the transaction."
  def lock_profile(id) do
    unless Repo.in_transaction?(), do: raise("closing snapshot requires a transaction")
    if uuid?(id), do: Repo.one(from(p in Profile, where: p.id == ^id, lock: "FOR UPDATE"))
  end

  @doc "Build a validated immutable contract from the locked current show default."
  def snapshot(%Profile{} = profile) do
    settings = profile.closing_video || %ClosingVideoSettings{}

    base = %{
      "file_id" => settings.file_id,
      "enabled" => settings.enabled,
      "audio" => to_string(settings.audio),
      "org_id" => profile.org_id,
      "project_id" => profile.project_id,
      "profile_id" => profile.id
    }

    with {:ok, attrs} <- snapshot_asset(profile, settings, base),
         {:ok, typed} <-
           Ecto.Changeset.apply_action(
             Platform.Social.ClosingVideoSnapshot.changeset(
               %Platform.Social.ClosingVideoSnapshot{},
               attrs
             ),
             :insert
           ) do
      {:ok, Platform.Social.ClosingVideoSnapshot.dump(typed)}
    else
      _ -> {:error, :closing_video_unavailable}
    end
  end

  defp snapshot_asset(_profile, %{enabled: false}, base), do: {:ok, base}

  defp snapshot_asset(profile, settings, base) do
    file = Files.get_file(settings.file_id)
    asset = Repo.get_by(ClosingAsset, profile_id: profile.id, file_id: settings.file_id)

    with :ok <- eligible_file(profile, file),
         %ClosingAsset{} <- asset,
         true <- asset.org_id == profile.org_id and asset.project_id == profile.project_id,
         true <- asset.content_hash == file.content_hash and asset.byte_size == file.byte_size do
      {:ok,
       Map.merge(base, %{
         "content_hash" => asset.content_hash,
         "content_type" => file.content_type,
         "byte_size" => asset.byte_size,
         "duration_s" => asset.duration_s,
         "width" => asset.width,
         "height" => asset.height
       })}
    else
      _ -> {:error, :closing_video_unavailable}
    end
  end

  @doc "Resolve only the exact pinned asset inside the claimer transaction; a changed default has no bearing on this check."
  def resolve_snapshot(profile, snapshot) when is_map(snapshot) do
    with %{"enabled" => true, "file_id" => id, "audio" => audio} <- snapshot,
         true <- audio in ["keep", "mute"],
         true <-
           snapshot["org_id"] == profile.org_id and snapshot["profile_id"] == profile.id and
             snapshot["project_id"] == profile.project_id,
         %{org_id: org_id, archived_at: nil} <-
           Repo.get(Platform.Tasks.Project, profile.project_id),
         true <- org_id == profile.org_id,
         true <- uuid?(id),
         file when not is_nil(file) <- lock_file(id),
         :ok <- eligible_file(profile, file),
         %ClosingAsset{} = registered <-
           Repo.get_by(ClosingAsset, profile_id: profile.id, file_id: id),
         true <-
           registered.org_id == profile.org_id and registered.project_id == profile.project_id,
         true <-
           file.content_hash == snapshot["content_hash"] and
             file.byte_size == snapshot["byte_size"] and
             file.content_type == snapshot["content_type"] and
             registered.content_hash == snapshot["content_hash"],
         {:ok, measurements} <- measure(file),
         true <-
           measurements.duration_s == snapshot["duration_s"] and
             measurements.width == snapshot["width"] and measurements.height == snapshot["height"],
         %{org_id: ^org_id, archived_at: nil} <-
           Repo.get(Platform.Tasks.Project, profile.project_id) do
      {:ok, file}
    else
      _ -> {:error, :closing_video_unavailable}
    end
  end

  def resolve_snapshot(_, _), do: {:error, :closing_video_unavailable}

  defp register(profile, file, verified \\ nil) do
    with :ok <- eligible_file(profile, file),
         true <-
           not Repo.exists?(
             from(j in ClipJob, where: j.source_file_id == ^file.id and j.kind == "episode")
           ) ||
             {:error, :already_an_episode},
         {:ok, measurements} <- register_measurements(file, verified) do
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

  defp register_measurements(file, nil), do: measure(file)

  defp register_measurements(file, {identity, measurements}) do
    if Map.take(file, Map.keys(identity)) == identity,
      do: {:ok, measurements},
      else: {:error, :asset_unavailable}
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
