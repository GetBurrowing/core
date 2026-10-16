defmodule Platform.Social.Source do
  @moduledoc """
  Where a clip's footage and transcript come from (task 01a140a9-69b7,
  Social 5/7). A source fetches into a per-job directory and returns:

      {:ok, %{video_path, segments, offset_s}}

  `segments` are `Platform.Social.Transcript` segments in SOURCE seconds;
  `offset_s` is where the local video starts in the source (0 for a whole
  file, the section start for a YouTube section download), so the renderer
  is handed `start_s - offset_s`.

  Implementations:

    * `Platform.Social.Source.File` - a video and its transcript in core's
      Files, both in the profile's project;
    * `Platform.Social.Source.YouTube` - yt-dlp, section download plus
      subtitles;
    * `Platform.Social.Source.MeetingRecording` - DEFERRED: there is no
      scoped read of a meeting recording yet, so it always refuses.

  `for_clip/1` picks one from the clip's columns.
  """

  @type fetched :: %{video_path: String.t(), segments: [map()], offset_s: float()}

  @callback fetch(clip :: map(), profile :: map(), dir :: String.t()) ::
              {:ok, fetched()} | {:error, String.t()}

  @doc "The source module for a clip."
  @spec for_clip(map()) :: module()
  def for_clip(%{source_file_id: id}) when is_binary(id), do: Platform.Social.Source.File
  def for_clip(%{source_url: url}) when is_binary(url), do: Platform.Social.Source.YouTube
end
