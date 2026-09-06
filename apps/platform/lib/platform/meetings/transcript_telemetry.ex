defmodule Platform.Meetings.TranscriptTelemetry do
  @moduledoc """
  The `:telemetry` emits for the INBOUND half of a meeting turn (task
  01a07400 stage 2): a transcript frame going out to an agent, and that
  agent's first say afterwards.

  Stage 1 (`Platform.Meetings.SayTelemetry`) traces one utterance from
  dispatch to posted. This module covers what comes before it — the frame the
  agent was answering — so a turn can be read end to end:

    * `[:platform, :meetings, :transcript, :delivered]` — one per RECIPIENT
      agent, emitted from `Platform.Meetings.deliver_transcript_segment/2`
      immediately after the frame is broadcast on that agent's brain runtime
      topic. Metadata `agent_id` / `meeting_id` / `segment_id`; measurement
      `lag_ms`, wall-clock milliseconds from the segment's `spoken_at` to the
      broadcast.

    * `[:platform, :meetings, :agent, :responded]` — emitted from
      `Platform.Meetings.say/4`, at the same instant as stage 1's
      `:say :dispatch`, when the speaking agent had a delivered frame
      outstanding in that room. Measurement `response_ms`, monotonic
      milliseconds from that frame's delivery to this dispatch.

  ## What `response_ms` is, and what it is NOT

  `response_ms` is **frame delivery to first say dispatch**. It is not, and
  must not be presented as, the time the model took to produce its first
  token. Core cannot observe an agent's tokens at all: the agent runs on a
  federated runtime and core sees only the actions that runtime takes. What
  the number contains is therefore everything between the two observable
  points — network out, plugin queueing, whatever the agent was already busy
  with, the model's own thinking, and the round trip back into `say/4`.

  It is the closest quantity obtainable from core, and it is a genuinely
  useful one: it is what a human in the room actually waits through. But the
  gap is real and is stated rather than papered over. A true first-token
  measurement requires the runtime to self-report one, which is a change on
  the far side of the federation boundary and a separate ticket. If a later
  edit is tempted to rename this field to something that implies token
  timing, that rename would be the defect — the name is the contract.

  ## What `:delivered` means, and what it does NOT

  It means core BROADCAST the frame on the agent's runtime topic. It does not
  mean the far end received it, and it must never be read that way:
  `Phoenix.Endpoint.broadcast/3` returns `:ok` into a topic nobody is
  listening on, and a channel plugin older than `63229eb` has no
  `meeting_transcript` listener and drops the frame in silence. That limit is
  the same one `deliver_transcript_segment/2` documents where it declines to
  record a `RuntimePresence.prove/2` for the frame, and for the same reason.

  So `lag_ms` measures speech-end to SEND, not speech-end to hearing.

  ## Correlation state

  Per `{meeting_id, agent_id}`, in ETS, held by
  `Platform.Meetings.SayRegistry` under the same five-minute ceiling and the
  same sweep as its other tables — see that module's "Delivered transcript
  frames" section. The row is overwritten by each new frame and REMOVED when
  it is answered, so one frame is credited to at most one say.

  It is diagnostic state with no schema, no migration and no Postgres table
  behind it. Nothing reads it to make a decision; losing a row costs one
  measurement.

  ## Sinks

  `:responded` is registered in `Platform.Audit.TelemetryHandler`'s `@events`,
  like stage 1's three: it fires at most once per say, and a say is already
  capped at six a minute per agent, so the volume is the same one that
  handler's sync path was accepted for.

  `:delivered` is deliberately NOT registered there, and the omission is a
  decision rather than an oversight. It fires once per recipient agent per
  final segment — every sentence anyone speaks, multiplied by the room's
  agent roster, with no cap anywhere. Writing an audit row per frame would
  make the audit log mostly transcript delivery. It is a `:telemetry` event
  for a metrics reporter to attach to; if a durable record of it is ever
  wanted, that wants an aggregate, not a row per frame.

  This module only OBSERVES. Nothing here changes what is delivered, what is
  said, or what any caller returns.
  """

  alias Platform.Meetings.SayRegistry

  @delivered [:platform, :meetings, :transcript, :delivered]
  @responded [:platform, :meetings, :agent, :responded]

  @doc "`[:platform, :meetings, :transcript, :delivered]`."
  @spec delivered_event() :: [atom()]
  def delivered_event, do: @delivered

  @doc "`[:platform, :meetings, :agent, :responded]`."
  @spec responded_event() :: [atom()]
  def responded_event, do: @responded

  @doc "Both event names."
  @spec events() :: [[atom()]]
  def events, do: [@delivered, @responded]

  @doc """
  One delivered frame, for ONE recipient agent. Called from
  `deliver_transcript_segment/2`'s per-agent branch, after the broadcast, so
  it is emitted exactly as often as a frame actually goes out — never for a
  skipped agent, never once for a fan-out of many.

  `frame` is the transcript frame payload itself
  (`transcript_frame_payload/2`), so the ids in the event are the same ids
  the runtime received and not a second derivation of them.

  `lag_ms` is omitted, rather than set to nil, when `spoken_at` cannot be
  parsed — `Platform.Audit.TelemetryHandler.ensure_json_safe/1` stringifies
  atoms, so a nil measurement would persist as the string `"nil"`. Same
  convention as stage 1. It is NOT clamped at zero: a negative value means
  the transcriber's clock is ahead of this node's, which is worth seeing.

  Recording the correlation mark is part of this call and not a second one at
  the call site, so the two can never drift apart. A frame for a room with no
  live `meetings` row has no `{meeting_id, agent_id}` key to be filed under;
  it is still emitted, it simply cannot be answered later.
  """
  @spec delivered(map(), binary()) :: :ok
  def delivered(frame, agent_id) when is_map(frame) and is_binary(agent_id) do
    :telemetry.execute(
      @delivered,
      put_present(%{system_time: System.system_time()}, :lag_ms, lag_ms(frame[:spoken_at])),
      %{
        agent_id: agent_id,
        meeting_id: frame[:meeting_id],
        segment_id: frame[:segment_id]
      }
    )

    note_frame(frame[:meeting_id], agent_id, frame)
  end

  def delivered(_frame, _agent_id), do: :ok

  @doc """
  The agent's first say after a delivered frame. Called from `say/4` at the
  dispatch instant, alongside stage 1's `:say :dispatch`.

  Emits NOTHING when the agent has no outstanding frame in this room. That is
  the whole discrimination the event makes: an unprompted say — a scribe
  announcing itself, an agent answering a chat message, a second sentence
  after one already credited — is not a response, and attributing it to some
  frame it never received would put a fabricated latency in the record. There
  is no fallback instant to measure from, and inventing one is the failure
  mode this clause exists to prevent.
  """
  @spec responded(binary(), String.t(), binary()) :: :ok
  def responded(agent_id, room_name, utterance_id)
      when is_binary(agent_id) and is_binary(room_name) do
    case SayRegistry.take_delivered_frame(agent_id, room_name) do
      %{at_ms: at_ms, meeting_id: meeting_id, segment_id: segment_id} ->
        :telemetry.execute(
          @responded,
          %{
            system_time: System.system_time(),
            response_ms: System.monotonic_time(:millisecond) - at_ms
          },
          %{
            agent_id: agent_id,
            meeting_id: meeting_id,
            segment_id: segment_id,
            room_name: room_name,
            utterance_id: utterance_id,
            actor_id: agent_id,
            actor_type: "agent",
            resource_type: "meeting_utterance",
            resource_id: utterance_id,
            action: "responded"
          }
        )

      nil ->
        :ok
    end
  end

  def responded(_agent_id, _room_name, _utterance_id), do: :ok

  # -- Internals --

  defp note_frame(meeting_id, agent_id, %{room_name: room_name} = frame)
       when is_binary(meeting_id) and is_binary(room_name) do
    SayRegistry.note_delivered_frame(meeting_id, agent_id, %{
      room_name: room_name,
      segment_id: frame[:segment_id]
    })
  end

  defp note_frame(_meeting_id, _agent_id, _frame), do: :ok

  defp lag_ms(spoken_at) when is_binary(spoken_at) do
    case DateTime.from_iso8601(spoken_at) do
      {:ok, spoken, _offset} -> DateTime.diff(DateTime.utc_now(), spoken, :millisecond)
      {:error, _reason} -> nil
    end
  end

  defp lag_ms(_spoken_at), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
