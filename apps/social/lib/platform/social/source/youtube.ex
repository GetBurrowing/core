defmodule Platform.Social.Source.YouTube do
  @moduledoc """
  A clip source from a YouTube URL via yt-dlp (Social 5/7).

  Downloads only a section around the clip (`--download-sections
  '*<start-5>-<end+5>'`, keyframes forced at the cuts) at up to 1080p, plus
  English subtitles (`--write-subs --write-auto-subs --sub-langs 'en.*'`,
  VTT). Extra arguments come from `config :social, :yt_dlp_extra_args`
  (default `["--extractor-args", "youtube:player_client=android"]`).

  Production does not ship yt-dlp (Debian's package goes stale against
  YouTube and server IPs are often bot-challenged), so there this reads
  "yt-dlp is not installed on this node"; a bot challenge or 403 reads
  "YouTube refused this node (bot check); upload the video and transcript
  to Files and use a file source".
  """

  @behaviour Platform.Social.Source

  alias Platform.Social.{Toolchain, Transcript}
  alias Platform.Social.Renderer.Ffmpeg

  @pad_s 5.0
  @refused "YouTube refused this node (bot check); upload the video and transcript to Files and use a file source"

  @impl true
  def fetch(clip, _profile, dir) do
    start_s = clip.requested_start_s || clip.start_s || 0.0
    end_s = clip.requested_end_s || clip.end_s || start_s
    from = max(start_s - @pad_s, 0.0)
    to = end_s + @pad_s

    with {:ok, yt_dlp} <- Toolchain.fetch(:yt_dlp),
         {:ok, _out} <- download(yt_dlp, clip.source_url, from, to, dir),
         {:ok, video} <- find(dir, ~w(.mp4 .mkv .webm), "the video"),
         {:ok, subs} <- subtitles(dir),
         {:ok, segments} <- Transcript.parse(File.read!(subs), :vtt) do
      {:ok, %{video_path: video, segments: segments, offset_s: from}}
    end
  end

  defp download(yt_dlp, url, from, to, dir) do
    ffmpeg_args =
      case Toolchain.ffmpeg_path() do
        nil -> []
        path -> ["--ffmpeg-location", path]
      end

    args =
      [
        "--no-playlist",
        "--no-progress",
        "-f",
        "bv*[height<=1080]+ba/b[height<=1080]",
        "--merge-output-format",
        "mp4",
        "--download-sections",
        "*#{num(from)}-#{num(to)}",
        "--force-keyframes-at-cuts",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        "en.*",
        "--sub-format",
        "vtt",
        "-o",
        Path.join(dir, "source.%(ext)s")
      ] ++ ffmpeg_args ++ extra_args() ++ [url]

    case Ffmpeg.run(yt_dlp, args, Application.get_env(:social, :yt_dlp_timeout_ms, 600_000)) do
      {:ok, out} ->
        {:ok, out}

      {:error, message} ->
        if Regex.match?(~r/not a bot|Sign in to confirm|HTTP Error 403/i, message),
          do: {:error, @refused},
          else: {:error, "yt-dlp could not fetch the episode: " <> message}
    end
  end

  defp extra_args,
    do:
      Application.get_env(:social, :yt_dlp_extra_args, [
        "--extractor-args",
        "youtube:player_client=android"
      ])

  defp subtitles(dir) do
    case Path.wildcard(Path.join(dir, "source*.vtt")) |> Enum.sort_by(&prefer_manual/1) do
      [first | _] ->
        {:ok, first}

      [] ->
        {:error,
         "YouTube has no English subtitles for this video; upload a transcript to Files and use a file source"}
    end
  end

  # Manual English subtitles (source.en.vtt) before auto ones (en-orig etc.).
  defp prefer_manual(path), do: if(String.ends_with?(path, ".en.vtt"), do: 0, else: 1)

  defp find(dir, exts, what) do
    case Enum.find(Path.wildcard(Path.join(dir, "source.*")), &(Path.extname(&1) in exts)) do
      nil -> {:error, "yt-dlp produced no file for #{what}"}
      path -> {:ok, path}
    end
  end

  defp num(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end
