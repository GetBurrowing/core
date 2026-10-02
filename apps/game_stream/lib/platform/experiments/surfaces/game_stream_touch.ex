defmodule Platform.Experiments.Surfaces.GameStreamTouch do
  @moduledoc """
  The `game_stream.touch` surface: how a phone player's touches are
  forwarded to the game. Task 01a0fe45 stage 1, on the experimentation layer
  of ADR-0052, mirroring `Platform.Experiments.Surfaces.GameStreamRoster`.

  Resolved in `Platform.GameStream.start_session/2` for the task being
  played, at the one target `"play_session.start"`, with `Surfaces.resolve/4`
  (which never raises). The session keeps the payload for its lifetime and
  hands it to the browser in its `touch` map (see
  `Platform.GameStream.Protocol`, "Touch").

  ## Payload

  Both keys, every arm:

    * `slop_px` — 0..32 CSS pixels. How far a pressed touch must travel
      before its first `move` is forwarded. This is the tap-versus-drag
      decision point: finger jitter must not reach a Godot ScrollContainer as
      a drag and cancel a button press. A value above 0 trades a later drag
      start for a single activation.
    * `move_hz` — 15..120. The most `move` messages per second per touch id;
      the browser coalesces to the latest position in between.

  Long-press timing is NOT a decision point here. Forwarding keeps the raw
  down/up timing, and the game owns long-press.

  ## The control

  `%{slop_px: 8, move_hz: 60}`.

  NAMED GAP: no metric judges this surface yet. Touch never transits core
  and the play host reports no tap or drag counter, so an arm is recorded
  only in the session's state and public status, not on the
  `game_stream_sessions` row. A judging metric is a follow-up.
  """

  @behaviour Platform.Experiments.Surface

  @target "play_session.start"

  @ranges %{
    "slop_px" => 0..32,
    "move_hz" => 15..120
  }

  @keys ~w(slop_px move_hz)

  @control %{"slop_px" => 8, "move_hz" => 60}

  @doc "The control payload, for callers that need it without a resolution."
  @spec control() :: map()
  def control, do: @control

  @impl true
  def key, do: "game_stream.touch"

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
        "slop_px" =>
          int.("slop_px", "CSS px a pressed touch travels before its first move is forwarded."),
        "move_hz" => int.("move_hz", "Most move messages per second per touch id.")
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
        unknown != [] && "unknown keys: #{Enum.join(unknown, ", ")}"
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
