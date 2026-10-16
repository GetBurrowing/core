defmodule Platform.Social.Source.File do
  @moduledoc """
  A clip source from core's Files (Social 5/7): the clip's `source_file_id`
  video and `transcript_file_id` transcript, read through `Platform.Files`
  and `Platform.Files.Storage` (never a Repo query on core's table). Both
  files must be in the profile's project; the transcript's format comes from
  its content type or extension (VTT, SRT or JSON).
  """

  @behaviour Platform.Social.Source

  alias Platform.Files
  alias Platform.Social.Transcript

  @impl true
  def fetch(clip, profile, dir) do
    with {:ok, video} <- file(clip.source_file_id, profile, "the source video"),
         {:ok, transcript} <- file(clip.transcript_file_id, profile, "the transcript"),
         {:ok, format} <-
           Transcript.format_for(
             transcript.content_type,
             transcript.original_filename || transcript.name
           ),
         {:ok, text} <- read(transcript),
         {:ok, segments} <- Transcript.parse(text, format),
         video_path = Path.join(dir, "source" <> ext(video)),
         :ok <- copy(video, video_path) do
      {:ok, %{video_path: video_path, segments: segments, offset_s: 0.0}}
    end
  end

  defp file(nil, _profile, what), do: {:error, "#{what} is not set on the clip"}

  defp file(id, profile, what) do
    case Files.get_file(id) do
      %{project_id: project_id} = file
      when project_id == profile.project_id and not is_nil(project_id) ->
        {:ok, file}

      %{} ->
        {:error, "#{what} is not in the profile's project"}

      nil ->
        {:error, "#{what} no longer exists in Files"}
    end
  end

  defp read(file) do
    with {:ok, stream} <- Files.Storage.get(file.storage_key) do
      {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
    else
      _ -> {:error, "the transcript's bytes could not be read from Files"}
    end
  rescue
    _ -> {:error, "the transcript's bytes could not be read from Files"}
  end

  defp copy(file, path) do
    with {:ok, stream} <- Files.Storage.get(file.storage_key) do
      stream |> Stream.into(Elixir.File.stream!(path)) |> Stream.run()
      :ok
    else
      _ -> {:error, "the source video's bytes could not be read from Files"}
    end
  rescue
    _ -> {:error, "the source video's bytes could not be read from Files"}
  end

  defp ext(file) do
    case Path.extname(file.original_filename || file.name || "") do
      "" -> ".mp4"
      ext -> String.downcase(ext)
    end
  end
end
