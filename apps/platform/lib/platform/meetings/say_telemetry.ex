defmodule Platform.Meetings.SayTelemetry do
  @moduledoc """
  The `:telemetry` emits for one `meeting_say` (task 01a07400 stage 1).

  Three events trace an utterance end to end. Each carries `utterance_id`,
  `agent_id` and `room_name` in its metadata, so a single utterance can be
  followed across the three moments it is observable from core:

    * `[:platform, :meetings, :say, :dispatch]` — the broadcast went out.
      Emitted by `Platform.Meetings.say/4` IMMEDIATELY AFTER the caller has
      subscribed to `"meetings:say:<utterance_id>"` and before the
      broadcast. The order matters and is not negotiable: see the
      "Subscribe, then send" note in `say/4`'s `@doc`. An emit placed above
      the subscribe would not itself lose an ack, but it invites the next
      editor to move the subscribe with it, and the inverted order is a
      race no test reliably catches.

    * `[:platform, :meetings, :say, :ack]` — a runtime answered.
      Measurements are `latency_ms` (dispatch to ack, from the registry's
      own `inserted_at_ms` stamp) and `duration_s` (what the runtime
      reported); metadata carries `status`, the LITERAL string the runtime
      sent, never a re-derivation of it. `"spoken"`, `"failed"`,
      `"unknown"` and anything else a worker invents are all relayed as
      they arrived — the whole point of the event is to be able to see what
      actually came back.

    * `[:platform, :meetings, :say, :posted]` — the dispatched text reached
      the room's chat space. Emitted only when `Chat.post_message/1`
      actually committed, so the event means what its name says. The four
      ways a `"spoken"` ack posts nothing (registry miss, agent mismatch,
      writer not authorized, insert failure) emit nothing here; they are
      already logged where they happen.

  ## Why the numbers are omitted rather than nil

  `Platform.Audit.TelemetryHandler.ensure_json_safe/1` stringifies atoms,
  and `nil` is an atom — a nil measurement would persist as the string
  `"nil"`. So `latency_ms` (absent when the registry row has expired or the
  id was never dispatched) and `duration_s` (absent when the worker did not
  report one) are left out of the measurement map entirely rather than set
  to nil. A consumer checks for the key.

  ## The Audit sink

  There is no second sink. All three events are registered in
  `Platform.Audit.TelemetryHandler`'s `@events`, which is what turns them
  into `Platform.Audit.Event` rows — CLAUDE.md's "Audit is the
  telemetry-driven event log". Registration there is load-bearing: an emit
  with no matching entry fails SILENTLY, the audit row simply never
  appears. The `actor_type` / `resource_type` / `action` keys in the
  metadata below are what that handler lifts into the audit row's columns.

  This module only OBSERVES. Nothing here changes ack timing, what gets
  posted, or what any caller returns.
  """

  alias Platform.Meetings.SayRegistry

  @dispatch [:platform, :meetings, :say, :dispatch]
  @ack [:platform, :meetings, :say, :ack]
  @posted [:platform, :meetings, :say, :posted]

  @resource_type "meeting_utterance"

  @doc "The three event names, in the order an utterance passes through them."
  @spec events() :: [[atom()]]
  def events, do: [@dispatch, @ack, @posted]

  @doc "`[:platform, :meetings, :say, :dispatch]`."
  @spec dispatch_event() :: [atom()]
  def dispatch_event, do: @dispatch

  @doc "`[:platform, :meetings, :say, :ack]`."
  @spec ack_event() :: [atom()]
  def ack_event, do: @ack

  @doc "`[:platform, :meetings, :say, :posted]`."
  @spec posted_event() :: [atom()]
  def posted_event, do: @posted

  @doc """
  The dispatch emit. Called from `say/4` between the ack subscribe and the
  broadcast.
  """
  @spec dispatch(binary(), binary() | nil, String.t() | nil) :: :ok
  def dispatch(utterance_id, agent_id, room_name) do
    :telemetry.execute(
      @dispatch,
      %{system_time: System.system_time()},
      base(utterance_id, agent_id, room_name, "dispatch")
    )
  end

  @doc """
  The ack emit. `status` is passed through verbatim — this function must
  never substitute a value of its own for it, or the event stops being
  evidence about the runtime and becomes evidence about this line.

  `latency_ms` is derived from the `SayRegistry` row's `inserted_at_ms`,
  which `say/4` stamps immediately before the broadcast. A missing row (an
  ack for an id this node never dispatched, or one past the registry ttl)
  means no latency can be computed and the key is omitted.
  """
  @spec ack(binary(), binary() | nil, String.t() | nil, String.t(), term()) :: :ok
  def ack(utterance_id, agent_id, room_name, status, duration_s) do
    entry = SayRegistry.get(utterance_id)

    measurements =
      %{system_time: System.system_time()}
      |> put_present(:latency_ms, latency_ms(entry))
      |> put_present(:duration_s, duration_s)

    metadata =
      utterance_id
      |> base(agent_id, room_name || entry_room_name(entry), "ack")
      |> Map.put(:status, status)

    :telemetry.execute(@ack, measurements, metadata)
  end

  @doc """
  The posted emit. Called once `Chat.post_message/1` has committed the
  dispatched text into the room's space.
  """
  @spec posted(binary(), binary() | nil, String.t() | nil) :: :ok
  def posted(utterance_id, agent_id, room_name) do
    :telemetry.execute(
      @posted,
      %{system_time: System.system_time()},
      base(utterance_id, agent_id, room_name, "posted")
    )
  end

  # -- Internals --

  defp base(utterance_id, agent_id, room_name, action) do
    %{
      utterance_id: utterance_id,
      agent_id: agent_id,
      room_name: room_name,
      actor_id: agent_id,
      actor_type: "agent",
      resource_type: @resource_type,
      resource_id: utterance_id,
      action: action
    }
  end

  defp latency_ms(%{inserted_at_ms: at_ms}) when is_integer(at_ms) do
    System.monotonic_time(:millisecond) - at_ms
  end

  defp latency_ms(_entry), do: nil

  defp entry_room_name(%{room_name: room_name}), do: room_name
  defp entry_room_name(_entry), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
