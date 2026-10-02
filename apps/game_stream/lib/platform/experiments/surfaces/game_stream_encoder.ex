defmodule Platform.Experiments.Surfaces.GameStreamEncoder do
  @moduledoc """
  The `game_stream.encoder_preset` surface: the NVENC settings a play
  session's host encodes with. Task 01a0db5f stage 2 (playable review
  builds), on the experimentation layer of ADR-0052.

  Resolved in `Platform.GameStream.start_session/2` for the task being
  played, at the one target `"play_session.start"`; the resolved payload is
  sent to the host verbatim as `play_session_start.encoder`. The metric that
  judges an arm is `game_stream_input_to_photon` (lower is better).

  ## Payload

  All seven keys, every arm:

    * `preset` — `p1`..`p7` (NVENC; p1 fastest, p7 best quality);
    * `tune` — `ll` (low latency) or `ull` (ultra low latency);
    * `bitrate_kbps` — 500..50_000;
    * `fps` — 15..120;
    * `width` — 320..3840, `height` — 240..2160;
    * `gop_frames` — 1..600.

  ## The control is stage 1's measured winner

  The control arm is the preset task 01a0db5f stage 1 chose from its sweep
  on wave (`docs/spike-01a0db5f.md` in `Startup-Suite/play-host`, commit
  c98447a7; recorded on that stage's test_pass evidence as
  `chosen_control_preset`): preset `p1`, tune `ll`, 8000 kbit/s CBR,
  1280x720 at 60 fps, a 120-frame GOP. Over the frame path stage 1 chose
  (in-engine `get_image()` readback), p1/ll measured input-to-photon
  p50/p95 of 41.6/51.7 ms over 150 probes on the LAN with 0 lost. It was
  picked on p95, loss and receive p50, NOT on p50 alone: the run-to-run
  spread (p4/ll 34-42 ms p50) is as large as the p1..p4 differences, which
  is exactly why the encoder is an experiment surface and not a constant.

  The session-0 desktop on wave is 1024x768 and clamps the Godot window, so
  stage 1's delivered frames were narrower than the requested 1280 (its
  evidence records 1028x720). The payload names what is requested; the
  host reports what it got.
  """

  @behaviour Platform.Experiments.Surface

  @target "play_session.start"

  @presets ~w(p1 p2 p3 p4 p5 p6 p7)
  @tunes ~w(ll ull)

  @ranges %{
    "bitrate_kbps" => 500..50_000,
    "fps" => 15..120,
    "width" => 320..3840,
    "height" => 240..2160,
    "gop_frames" => 1..600
  }

  @keys ~w(preset tune bitrate_kbps fps width height gop_frames)

  # Stage 1's chosen preset — see the moduledoc.
  @control %{
    "preset" => "p1",
    "tune" => "ll",
    "bitrate_kbps" => 8000,
    "fps" => 60,
    "width" => 1280,
    "height" => 720,
    "gop_frames" => 120
  }

  @doc "The control payload, for callers that need it without a resolution."
  @spec control() :: map()
  def control, do: @control

  @impl true
  def key, do: "game_stream.encoder_preset"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    int = fn key, desc ->
      range = Map.fetch!(@ranges, key)

      %{
        "type" => "integer",
        "minimum" => range.first,
        "maximum" => range.last,
        "description" => desc
      }
    end

    %{
      "type" => "object",
      "required" => @keys,
      "properties" => %{
        "preset" => %{
          "type" => "string",
          "enum" => @presets,
          "description" => "NVENC preset, p1 (fastest) .. p7 (best quality)."
        },
        "tune" => %{
          "type" => "string",
          "enum" => @tunes,
          "description" => "NVENC tune: ll (low latency) or ull (ultra low latency)."
        },
        "bitrate_kbps" => int.("bitrate_kbps", "Target CBR bitrate in kbit/s."),
        "fps" => int.("fps", "Encode frame rate."),
        "width" => int.("width", "Encode width in pixels."),
        "height" => int.("height", "Encode height in pixels."),
        "gop_frames" => int.("gop_frames", "Frames between forced IDR frames.")
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
    unknown = payload |> Map.keys() |> Enum.reject(&(&1 in @keys)) |> Enum.sort()
    missing = Enum.reject(@keys, &Map.has_key?(payload, &1))

    errors =
      [
        missing != [] && "missing keys: #{Enum.join(missing, ", ")}",
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}",
        (Map.has_key?(payload, "preset") and payload["preset"] not in @presets) &&
          "preset must be one of #{Enum.join(@presets, ", ")}",
        (Map.has_key?(payload, "tune") and payload["tune"] not in @tunes) &&
          "tune must be ll or ull"
      ] ++
        for {key, range} <- @ranges,
            Map.has_key?(payload, key),
            not (is_integer(payload[key]) and payload[key] in range) do
          "#{key} must be an integer in #{range.first}..#{range.last}"
        end

    case Enum.filter(errors, &is_binary/1) do
      [] -> {:ok, Map.take(payload, @keys)}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, @control}

  @impl true
  def subject_attributes(task_id),
    do: Platform.Experiments.Surfaces.DispatchPrompt.subject_attributes(task_id)
end
