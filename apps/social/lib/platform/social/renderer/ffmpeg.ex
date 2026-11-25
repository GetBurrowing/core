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

  require Logger

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

  @doc """
  Probe an explicitly caller-owned input copy. The caller owns its input and
  must retain it if child exit is unconfirmed. On lifecycle failure the private
  details identify whether input was used, child exit was confirmed, and an
  output directory needs operator cleanup. Error reasons and lifecycle details
  are internal: callers must map failures to fixed outward text. Older probes
  use merged stdout and retain its warning-contamination limitation.
  """
  @spec probe_owned(String.t()) :: {:ok, map()} | {:error, term()}
  def probe_owned(path), do: probe_owned(path, 60_000)

  @doc false
  def probe_owned(path, timeout_ms) do
    with {:ok, ffprobe} <- Toolchain.fetch(:ffprobe),
         true <- File.regular?(path) || {:error, "the video file is missing"},
         args =
           ~w(-v error -show_entries format=duration,format_name:stream=codec_type,codec_name,width,height -of json),
         {:ok, json} <- probe_json(ffprobe, args, path, timeout_ms),
         :ok <- valid_probe_document(json),
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

  # A help call is deliberately uncached. Unknown/older probes retain the
  # previous merged-output path, including its warning-contamination limit.
  defp output_option?(ffprobe) do
    case run_probe_reaped(ffprobe, ["-h"], 5_000, 262_144) do
      {:terminal, {:ok, help}} ->
        {:ok, Regex.match?(~r/(?m)^-o[ \t]+<output_file>(?:[ \t]|$)/, help)}

      {:terminal, _} ->
        {:ok, false}

      {:unreaped, _} ->
        {:error,
         {:probe_lifecycle, %{child_exit: :unconfirmed, input_used?: false, output_dir: nil}}}
    end
  end

  defp probe_json(ffprobe, args, path, timeout_ms) do
    case output_option?(ffprobe) do
      {:ok, true} ->
        with {:ok, dir} <- private_probe_dir() do
          output = Path.join(dir, "result.json")

          case run_probe_reaped(ffprobe, args ++ ["-o", output, path], timeout_ms) do
            {:terminal, result} ->
              result = probe_file_result(result, output)

              case File.rm_rf(dir) do
                {:ok, _} ->
                  result

                {:error, _, _} ->
                  {:error,
                   {:probe_lifecycle,
                    %{child_exit: :confirmed, input_used?: true, output_dir: dir}}}
              end

            {:unreaped, _reason} ->
              {:error,
               {:probe_lifecycle, %{child_exit: :unconfirmed, input_used?: true, output_dir: dir}}}
          end
        end

      {:ok, false} ->
        case run_probe_reaped(ffprobe, args ++ [path], timeout_ms) do
          {:terminal, result} ->
            result

          {:unreaped, _} ->
            {:error,
             {:probe_lifecycle, %{child_exit: :unconfirmed, input_used?: true, output_dir: nil}}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_file_result(result, output) do
    try do
      with {:ok, diagnostics} <- result,
           :ok <- log_probe_diagnostics(diagnostics),
           {:ok, json} <- File.read(output),
           :ok <- valid_probe_document(json) do
        {:ok, json}
      else
        {:error, reason} when is_atom(reason) -> {:error, "ffprobe output could not be read"}
        error -> error
      end
    rescue
      _ -> {:error, "ffprobe output processing failed"}
    catch
      _, _ -> {:error, "ffprobe output processing failed"}
    end
  end

  defp valid_probe_document(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} ->
        streams = Map.get(doc, "streams", [])
        format = Map.get(doc, "format", %{})

        if is_list(streams) and Enum.all?(streams, &is_map/1) and is_map(format),
          do: :ok,
          else: {:error, "ffprobe returned unreadable output"}

      _ ->
        {:error, "ffprobe returned unreadable output"}
    end
  end

  defp log_probe_diagnostics(""), do: :ok

  defp log_probe_diagnostics(_diagnostics) do
    Logger.warning("ffprobe emitted diagnostics")
    :ok
  end

  # mkdir -m creates the directory exclusively with private permissions; a
  # random name avoids process-local counter collisions across BEAMs.
  defp private_probe_dir do
    base = Application.get_env(:social, :render_tmp_dir) || System.tmp_dir!()
    name = "ffprobe-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    dir = Path.join(base, name)

    with mkdir when is_binary(mkdir) <- System.find_executable("mkdir"),
         {_output, 0} <- System.cmd(mkdir, ["-m", "700", dir], stderr_to_stdout: true) do
      private? =
        case File.lstat(dir) do
          {:ok, %{type: :directory, mode: mode}} -> Bitwise.band(mode, 0o777) == 0o700
          _ -> false
        end

      if private? do
        {:ok, dir}
      else
        case File.rm_rf(dir) do
          {:ok, _} ->
            {:error, "ffprobe temporary directory unavailable"}

          {:error, _, _} ->
            {:error,
             {:probe_lifecycle, %{child_exit: :not_started, input_used?: false, output_dir: dir}}}
        end
      end
    else
      _ ->
        case File.lstat(dir) do
          {:error, reason} when reason in [:enoent, :enotdir] ->
            {:error, "ffprobe temporary directory unavailable"}

          _ ->
            {:error,
             {:probe_lifecycle, %{child_exit: :not_started, input_used?: false, output_dir: dir}}}
        end
    end
  rescue
    _ -> {:error, "ffprobe temporary directory unavailable"}
  end

  # Probe-only runner: on timeout, retain the Port until its exit_status
  # confirms the OS process has stopped; never delete its directory first.
  # run/3 and its ffmpeg/downloader behavior remain unchanged.
  defp run_probe_reaped(cmd, args, timeout_ms, limit \\ :infinity) do
    {exe, argv} =
      case System.find_executable("nice") do
        nil -> {cmd, args}
        nice -> {nice, ["-n", "10", cmd | args]}
      end

    result =
      try do
        {:ok,
         Port.open({:spawn_executable, exe}, [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           :hide,
           args: argv
         ])}
      rescue
        e -> {:error, "ffprobe could not start: #{Exception.message(e)}"}
      end

    case result do
      {:ok, port} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        try do
          collect_probe(port, [], 0, false, limit, deadline, timeout_ms)
        rescue
          _ -> {:unreaped, "ffprobe process monitoring failed"}
        catch
          _, _ -> {:unreaped, "ffprobe process monitoring failed"}
        end

      {:error, reason} ->
        {:terminal, {:error, reason}}
    end
  end

  defp collect_probe(port, acc, bytes, overflow?, limit, deadline, timeout_ms) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    if left == 0 do
      terminate_probe(port, timeout_ms)
    else
      receive do
        {^port, {:data, data}} ->
          bytes = bytes + byte_size(data)
          overflow? = overflow? or (limit != :infinity and bytes > limit)
          acc = if overflow?, do: [], else: [data | acc]
          collect_probe(port, acc, bytes, overflow?, limit, deadline, timeout_ms)

        {^port, {:exit_status, 0}} when overflow? ->
          {:terminal, {:error, "ffprobe capability output exceeded its limit"}}

        {^port, {:exit_status, 0}} ->
          {:terminal, {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}}

        {^port, {:exit_status, status}} ->
          out = acc |> Enum.reverse() |> IO.iodata_to_binary()
          {:terminal, {:error, "ffprobe failed (exit #{status}): #{tail(out)}"}}
      after
        left -> terminate_probe(port, timeout_ms)
      end
    end
  end

  defp terminate_probe(port, timeout_ms) do
    reason = "ffprobe timed out after #{div(timeout_ms, 1000)}s"

    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        kill_probe(pid)

      _ ->
        :error
    end

    await_probe_exit(port, reason, System.monotonic_time(:millisecond) + 2_000)
  end

  # A stuck kill helper must not turn the probe deadline into an unbounded wait.
  defp kill_probe(pid) do
    case System.find_executable("kill") do
      nil ->
        :error

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: ["-9", Integer.to_string(pid)]
          ])

        await_kill_helper(port, System.monotonic_time(:millisecond) + 1_000)
    end
  rescue
    _ -> :error
  end

  defp await_kill_helper(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> await_kill_helper(port, deadline)
    after
      remaining -> Port.close(port)
    end
  end

  defp await_probe_exit(port, reason, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    if left == 0 do
      receive do
        {^port, {:exit_status, _}} -> {:terminal, {:error, reason <> " and was stopped"}}
      after
        0 -> {:unreaped, reason}
      end
    else
      receive do
        {^port, {:exit_status, _}} -> {:terminal, {:error, reason <> " and was stopped"}}
        {^port, {:data, _}} -> await_probe_exit(port, reason, deadline)
      after
        left -> {:unreaped, reason}
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
