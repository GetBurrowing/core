defmodule Platform.Social.Renderer.Ffmpeg do
  @moduledoc """
  The plain-ffmpeg clip renderer (task 01a140a9-69b7, Social 5/7), the
  default `Platform.Social.Renderer`.

  One ffmpeg run per clip:

    1. ffprobe the source; a clip ending past the source is refused with
       both numbers in the error.
    2. Input-seek to `start_s` (`-ss` before `-i`), keeping 2s of extra
       audio for the card's fade.
    3. Video: scale to COVER 1080x1920, crop 1080 wide centred at `crop_x`
       (STATIC in v1, see `Platform.Social.Renderer`), burn the caption ASS
       with `fontsdir` pointing at the bundled fonts (never a system font).
    4. End card: a solid `brand.end_card_ground` colour source for
       `end_card_s`, its own ASS (name, call to action, handle), and the
       logo overlaid in its slot when a `logo_path` is given. Hard cut.
    5. Audio: the source's audio carried into the card and faded out over
       it (silence when the source has none).
    6. H.264 (yuv420p) + AAC, `+faststart`, 30 fps.
    7. ffprobe the output for `duration_s`, `width`, `height`; `byte_size`
       from the file.

  Runs through a Port under `nice` (when present) with a timeout
  (`config :social, :render_timeout_ms`, default 900_000); a timeout kills
  the OS process. Failures carry the last lines of ffmpeg's stderr.
  """

  @behaviour Platform.Social.Renderer

  alias Platform.Social.{Brand, Captions, Renderer, Toolchain}

  @fps 30
  @tail_bytes 1_500

  @impl true
  def preflight, do: Toolchain.capabilities()

  @impl true
  def render(input) do
    input = Map.merge(Renderer.defaults(), input)

    with :ok <- preflight(),
         {:ok, ffmpeg} <- Toolchain.fetch(:ffmpeg),
         {:ok, probe} <- probe(input.source_path),
         :ok <- within_source(input, probe),
         {:ok, workdir} <- workdir(input.out_path) do
      try do
        encode(ffmpeg, input, probe, workdir)
      after
        File.rm_rf(workdir)
      end
    end
  end

  defp encode(ffmpeg, input, probe, workdir) do
    with {:ok, args} <- args(input, probe, workdir),
         {:ok, _} <- run(ffmpeg, args, timeout()),
         {:ok, out} <- probe(input.out_path) do
      {:ok,
       %{
         path: input.out_path,
         duration_s: out.duration_s,
         width: out.width,
         height: out.height,
         byte_size: File.stat!(input.out_path).size
       }}
    end
  end

  defp timeout, do: Application.get_env(:social, :render_timeout_ms, 900_000)

  # ── Probe ────────────────────────────────────────────────────────────

  @doc "ffprobe a file: `{:ok, %{duration_s, width, height, audio?, video_codec}}`."
  @spec probe(String.t()) :: {:ok, map()} | {:error, String.t()}
  def probe(path) do
    with {:ok, ffprobe} <- Toolchain.fetch(:ffprobe),
         true <- File.regular?(path) || {:error, "the video file is missing"},
         {:ok, json} <-
           run(
             ffprobe,
             ~w(-v error -show_entries format=duration,format_name:stream=codec_type,codec_name,width,height -of json) ++
               [path],
             60_000
           ),
         {:ok, decoded} <- decode(json) do
      streams = decoded["streams"] || []
      video = Enum.find(streams, &(&1["codec_type"] == "video"))

      case {video, parse_float(get_in(decoded, ["format", "duration"]))} do
        {nil, _} ->
          {:error, "the file has no video stream"}

        {_, nil} ->
          {:error, "ffprobe could not read the video's duration"}

        {v, duration} ->
          {:ok,
           %{
             format_name: get_in(decoded, ["format", "format_name"]),
             duration_s: duration,
             width: v["width"],
             height: v["height"],
             video_codec: v["codec_name"],
             audio?: Enum.any?(streams, &(&1["codec_type"] == "audio")),
             audio_codec:
               Enum.find_value(streams, &(&1["codec_type"] == "audio" && &1["codec_name"]))
           }}
      end
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      _ -> {:error, "ffprobe returned unreadable output"}
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp within_source(%{start_s: s, end_s: e}, %{duration_s: d}) do
    cond do
      e <= s ->
        {:error, "the clip's end (#{fmt(e)}s) is not after its start (#{fmt(s)}s)"}

      s < 0 ->
        {:error, "the clip's start (#{fmt(s)}s) is before the source begins"}

      e > d + 0.05 ->
        {:error, "the clip ends at #{fmt(e)}s but the source video is only #{fmt(d)}s long"}

      true ->
        :ok
    end
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  # ── Command ──────────────────────────────────────────────────────────

  defp workdir(out_path) do
    dir = Path.join(Path.dirname(out_path), "render-#{System.unique_integer([:positive])}")

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, "could not create a work directory: #{inspect(reason)}"}
    end
  end

  defp args(input, probe, workdir) do
    brand = Map.merge(Brand.defaults(), input.brand || %{})
    clip_s = input.end_s - input.start_s
    card_s = input.end_card_s * 1.0
    total = clip_s + card_s
    {w, h} = {input.width, input.height}

    words =
      for word <- input.words,
          word.end_s > input.start_s and word.start_s < input.end_s do
        %{
          word
          | start_s: max(word.start_s - input.start_s, 0.0),
            end_s: min(word.end_s - input.start_s, clip_s)
        }
      end

    speakers =
      for sp <- input.speakers || [],
          (sp[:start_s] || 0) < input.end_s do
        %{start_s: max((sp[:start_s] || 0) - input.start_s, 0.0), name: sp[:name]}
      end

    captions = Path.join(workdir, "captions.ass")
    card = Path.join(workdir, "endcard.ass")
    logo? = is_binary(input[:logo_path]) and File.regular?(input[:logo_path] || "")

    File.write!(captions, Captions.captions(words, speakers, brand, clip_s))
    File.write!(card, Captions.end_card(brand, card_s, logo?: logo?))

    fonts = Brand.fonts_dir()
    ground = "0x" <> String.trim_leading(brand["end_card_ground"], "#")
    crop_x = min(max(input.crop_x * 1.0, 0.0), 1.0)

    video =
      "[0:v]scale=w='if(gt(iw/ih,#{w}/#{h}),-2,#{w})':h='if(gt(iw/ih,#{w}/#{h}),#{h},-2)'," <>
        "crop=#{w}:#{h}:x='(iw-#{w})*#{crop_x}':y='(ih-#{h})/2',setsar=1,fps=#{@fps}," <>
        "trim=duration=#{clip_s},setpts=PTS-STARTPTS,format=yuv420p," <>
        "subtitles=filename='#{esc(captions)}':fontsdir='#{esc(fonts)}'[clip]"

    card_bg = "color=c=#{ground}:s=#{w}x#{h}:r=#{@fps}:d=#{card_s},format=yuv420p"

    {card_chain, logo_inputs} =
      if logo? do
        slot = Captions.logo_slot()

        {"#{card_bg}[bg];[2:v]scale=w=#{slot.max_w}:h=#{slot.max_h}:force_original_aspect_ratio=decrease[logo];" <>
           "[bg][logo]overlay=x=(W-w)/2:y=#{slot.y}-h/2,format=yuv420p," <>
           "subtitles=filename='#{esc(card)}':fontsdir='#{esc(fonts)}'[card]",
         ["-i", input.logo_path]}
      else
        {"#{card_bg},subtitles=filename='#{esc(card)}':fontsdir='#{esc(fonts)}'[card]", []}
      end

    audio =
      if probe.audio? do
        "[0:a]aresample=48000,aformat=channel_layouts=stereo,apad,atrim=0:#{total}," <>
          "asetpts=PTS-STARTPTS,afade=t=out:st=#{clip_s}:d=#{card_s}[a]"
      else
        "anullsrc=r=48000:cl=stereo,atrim=0:#{total}[a]"
      end

    filter = Enum.join([video, card_chain, "[clip][card]concat=n=2:v=1:a=0[v]", audio], ";")

    # extra audio past end_s for the fade, bounded by the source
    read_s = min(total, probe.duration_s - input.start_s)

    {:ok,
     [
       "-hide_banner",
       "-nostdin",
       "-y",
       "-ss",
       num(input.start_s),
       "-t",
       num(read_s),
       "-i",
       input.source_path
     ] ++
       logo_inputs ++
       ["-filter_complex", filter, "-map", "[v]", "-map", "[a]"] ++
       ~w(-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -profile:v high -r 30) ++
       ~w(-c:a aac -b:a 160k -ar 48000 -movflags +faststart -t) ++
       [num(total), input.out_path]}
  end

  # Inside a single-quoted filter argument only ' and \ need escaping; the
  # filtergraph parser then needs \ , ; [ ] escaped at its level.
  defp esc(path) do
    path
    |> String.replace("\\", "\\\\\\\\")
    |> String.replace("'", "'\\\\''")
  end

  defp num(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)

  # ── Process ──────────────────────────────────────────────────────────

  @doc false
  # Runs `cmd args` under nice (when present) with a timeout, collecting
  # stdout+stderr; returns {:ok, output} on exit 0, else {:error, readable}.
  def run(cmd, args, timeout_ms) do
    {exe, argv} =
      case System.find_executable("nice") do
        nil -> {cmd, args}
        nice -> {nice, ["-n", "10", cmd | args]}
      end

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: argv
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, [], deadline, {Path.basename(cmd), timeout_ms})
  rescue
    e -> {:error, "#{Path.basename(cmd)} could not start: #{Exception.message(e)}"}
  end

  defp collect(port, acc, deadline, {name, timeout_ms} = who) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | acc], deadline, who)

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        out = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, "#{name} failed (exit #{status}): #{tail(out)}"}
    after
      left ->
        kill(port)
        {:error, "#{name} timed out after #{div(timeout_ms, 1000)}s and was stopped"}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end

  defp tail(out) do
    out = String.trim(out)

    if byte_size(out) > @tail_bytes,
      do: "..." <> binary_part(out, byte_size(out) - @tail_bytes, @tail_bytes),
      else: out
  end
end
