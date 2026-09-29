defmodule Platform.Experiments.Surfaces.GameStreamRoster do
  @moduledoc """
  The `game_stream.roster` surface: how a multiplayer play session opens and
  how many peers it admits. Task 01a0dbd6 stage 2 (multiplayer game_stream),
  on the experimentation layer of ADR-0052, mirroring
  `Platform.Experiments.Surfaces.GameStreamEncoder`.

  Resolved in `Platform.GameStream.start_session/2` for the task being
  played, at the one target `"play_session.start"`, with `Surfaces.resolve/4`
  (which never raises). The session keeps the payload for its lifetime. The
  metric that judges an arm is `game_stream_input_to_photon`, read per
  session from the WORST slot (`Platform.GameStream.SessionRecord`); lower
  is better. The row records the arm in `roster_experiment_id` /
  `roster_variant_slug`, next to the encoder's own pair.

  ## Payload

  All three keys, every arm:

    * `open_as` — `watch` or `join`. `watch`: opening the canvas attaches as a
      spectator, and a player slot is an explicit Join. `join`: opening also
      takes the next free slot, when there is one.
    * `max_players` — 1..8 player slots.
    * `max_spectators` — 0..16 peers without a slot.

  ## The control, and the conflict it settles

  `%{open_as: "watch", max_players: 4, max_spectators: 4}`.

  NAMED CONFLICT: the ticket's spectator clause ("opens while slots are
  full, or picks Watch") implies an open with a free slot could join. Saru's
  design (canvas 01a0e954-b12f) dropped auto-join: opening never makes
  anyone a player. The control is Saru's `watch`; `open_as: "join"` is the
  data variant, so the question stays answerable by experiment instead of
  being settled by code.

  NAMED DECISION: the spectator cap of 4 bounds the host's upstream. Every
  peer, player or spectator, receives the same encode (stage 1's control is
  8000 kbit/s); at about 8.7 Mbit/s on the wire per relayed viewer, 4
  players and 4 spectators is about 70 Mbit/s of host upstream.
  """

  @behaviour Platform.Experiments.Surface

  @target "play_session.start"

  @open_as ~w(watch join)

  @ranges %{
    "max_players" => 1..8,
    "max_spectators" => 0..16
  }

  @keys ~w(open_as max_players max_spectators)

  @control %{"open_as" => "watch", "max_players" => 4, "max_spectators" => 4}

  @doc "The control payload, for callers that need it without a resolution."
  @spec control() :: map()
  def control, do: @control

  @impl true
  def key, do: "game_stream.roster"

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
        "open_as" => %{
          "type" => "string",
          "enum" => @open_as,
          "description" =>
            "watch: opening attaches as a spectator; join: opening also takes a free slot."
        },
        "max_players" => int.("max_players", "Player slots in a session."),
        "max_spectators" => int.("max_spectators", "Peers without a slot in a session.")
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
        (Map.has_key?(payload, "open_as") and payload["open_as"] not in @open_as) &&
          "open_as must be watch or join"
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
