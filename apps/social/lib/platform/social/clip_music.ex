defmodule Platform.Social.ClipMusic do
  @moduledoc "Project-owned music assets. Files remains the storage and retention authority."
  alias Platform.Social
  @max_bytes 25 * 1024 * 1024
  @types ~w(audio/mpeg audio/mp3 audio/wav audio/x-wav audio/mp4 audio/ogg audio/flac)
  def max_bytes, do: @max_bytes

  def settings(look) do
    Map.merge(
      %{"file_id" => nil, "gain_db" => -18, "muted" => true},
      Map.get(look || %{}, "music_track") || %{}
    )
  end

  def resolve(profile, id) when is_binary(id) do
    with {:ok, project} <- Social.render_project(profile),
         true <- is_nil(project.archived_at),
         %{project_id: project_id} = file <- Platform.Files.get_file(id),
         true <- project_id == project.id and file.org_id == profile.org_id,
         true <- playable?(file) do
      {:ok, file}
    else
      _ -> {:error, :music_unavailable}
    end
  end

  def resolve(_, _), do: {:error, :music_unavailable}

  def playable?(file),
    do:
      Platform.Files.finalized_upload?(file) and file.content_type in @types and
        file.byte_size <= @max_bytes

  def list(profile, user_id) do
    with fresh when not is_nil(fresh) <- Social.get_profile(profile.org_id, profile.id),
         :ok <- Social.approver_check(fresh.org_id, fresh, user_id),
         {:ok, project} <- Social.render_project(fresh),
         true <- is_nil(project.archived_at) do
      {:ok,
       Platform.Files.list_files_for_project(project.id, limit: nil)
       |> Enum.filter(&(&1.org_id == fresh.org_id and playable?(&1)))}
    else
      _ -> {:error, :music_unavailable}
    end
  end

  def upload(profile, user_id, bytes, name, mime) do
    mime =
      case mime do
        "audio/x-m4a" -> "audio/mp4"
        "audio/x-flac" -> "audio/flac"
        "audio/vnd.wave" -> "audio/wav"
        other -> other
      end

    with fresh when not is_nil(fresh) <- Social.get_profile(profile.org_id, profile.id),
         :ok <- Social.approver_check(fresh.org_id, fresh, user_id),
         {:ok, project} <- Social.render_project(fresh),
         true <- byte_size(bytes) in 1..@max_bytes and mime in @types,
         true <- audio_bytes?(bytes, mime) do
      case Platform.Files.add_bytes(project, bytes, Path.basename(name), mime,
             uploaded_by_user_id: user_id,
             ingest: false
           ) do
        {:ok, file, _} ->
          {:ok, file}

        {:error, %Ecto.Changeset{}} = error ->
          hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

          case Platform.Files.list_files_for_project(project.id, limit: nil)
               |> Enum.find(&(&1.content_hash == hash and playable?(&1))) do
            nil -> error
            file -> {:ok, file}
          end

        error ->
          error
      end
    else
      _ -> {:error, :invalid_music_upload}
    end
  end

  # Refuse renamed text/video uploads; the renderer performs full decode validation.
  defp audio_bytes?(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>, type),
    do: type in ~w(audio/wav audio/x-wav)

  defp audio_bytes?(<<"ID3", _::binary>>, type), do: type in ~w(audio/mpeg audio/mp3)

  defp audio_bytes?(<<255, b, _::binary>>, type) when b >= 224,
    do: type in ~w(audio/mpeg audio/mp3)

  defp audio_bytes?(<<"OggS", _::binary>>, "audio/ogg"), do: true
  defp audio_bytes?(<<"fLaC", _::binary>>, "audio/flac"), do: true
  defp audio_bytes?(<<_::binary-size(4), "ftyp", _::binary>>, "audio/mp4"), do: true
  defp audio_bytes?(_, _), do: false

  def payload(profile, look) do
    track = settings(look)
    id = track["file_id"]

    with :ok <-
           if(is_nil(id),
             do: :ok,
             else:
               case resolve(profile, id) do
                 {:ok, _} -> :ok
                 error -> error
               end
           ),
         true <- track["muted"] or is_binary(id) do
      {:ok,
       %{
         "file_id" => id,
         "enabled" => not track["muted"] and is_binary(id),
         "level_db" => track["gain_db"]
       }}
    else
      _ -> {:error, :music_unavailable}
    end
  end
end
