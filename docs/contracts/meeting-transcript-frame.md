# Meeting transcript frame

**Status:** STABLE from the merge of task `01a06672-b193-7001-a5a1-0eac1b8cf949`
**Owner task:** `01a06672-b193-7001-a5a1-0eac1b8cf949` (Agents hear the room: transcript frame and reply budget)
**Consumed by:** `claude-code-suite-channel` (separate repo; listener added in `63229eb`, ack added by task `01a06dfb-2a34-7001-99ec-2d3f3678afe0` stage 1), any runtime client on `PlatformWeb.RuntimeSocket`
**Source-of-truth references:**
- Delivery: `apps/platform/lib/platform/meetings.ex`, `Platform.Meetings.deliver_transcript_segment/2`
- Persist seam: `apps/platform/lib/platform/meetings.ex`, `Platform.Meetings.append_segment/2`
- Ack seam: `apps/platform/lib/platform_web/channels/runtime_channel.ex`, `handle_in("meeting_transcript_ack", ...)`
- Capability proofs: `apps/platform/lib/platform/federation/runtime_presence.ex`, `prove/2`
- Reply budget: `apps/platform/lib/platform/meetings.ex`, `Platform.Meetings.say/4` and `check_reply_budget/2`
- Ledger: `apps/platform/lib/platform/meetings/say_registry.ex`
- Tool envelopes: `apps/platform/lib/platform/federation/tool_surface.ex`, `meeting_say_error/2`
- Classifier guard: `apps/platform/lib/platform/meetings/intent_classifier.ex`, guard 1 (`:agent_speaker`)
- Meetings ADR: `docs/decisions/0030-meetings-livekit-voice-video.md`

## Direction and transport

Core to the agent's brain runtime socket. One frame per persisted final transcript segment, per seated agent:

```elixir
PlatformWeb.Endpoint.broadcast("runtime:<runtime_id>", "meeting_transcript", payload)
```

The runtime is resolved by `Platform.Meetings.IntentRuntimeAdapter.resolve_target/1`, which reads `agent.runtime_id`: the brain, the same socket that receives intents and `meeting_join`. The voice worker row (`Federation.register_voice_runtime/3`, the row `meeting_join` and `meeting_say` are dispatched to) never receives this frame.

The sender is `Platform.Meetings.deliver_transcript_segment/2`. It is called from the success branch of `Platform.Meetings.append_segment/2`, the one persist point for transcript segments, so both writers (the `meeting-transcriber` POST to `/api/meetings/segments` and the LiveKit webhook) are covered without knowing about it. It is a direct call, not a `meeting:transcript_chunk` subscriber, and it runs after the row is on disk.

## Payload

All keys are always present. Values are strings unless stated; nullable keys say so.

| Key | Type | Value |
|---|---|---|
| `room_name` | string | LiveKit room name, the same value as `room_name` in the `meeting_join` payload |
| `meeting_id` | uuid or null | The `meetings` row for the transcript's space, bounded by the transcript's start; null when the space has no meeting |
| `segment_id` | uuid | Stable per segment; also stored on the transcript segment as `id` |
| `text` | string | The transcribed text |
| `participant_identity` | string | `user:<uuid>`, `agent:<slug>` or `guest:<uuid>` |
| `speaker_name` | string or null | Display name the transcriber supplied |
| `speaker_kind` | `"human"` or `"agent"` | Derived from `participant_identity`; guests are `"human"` |
| `spoken_at` | ISO8601 UTC string | Server append time, not audio time |

`segment_id` and `spoken_at` are minted in `append_segment/2` before the row is written, so the stored JSONB segment, the `transcript_chunk` PubSub broadcast and this frame all name the same segment.

Example:

```json
{
  "room_name": "space-01a066cb-60c7-7001-a8e9-5af52dcf4811",
  "meeting_id": "01a066d1-7813-7001-a3b2-8199c44c2af6",
  "segment_id": "01a06700-1234-7001-b000-0eac1b8cf949",
  "text": "Can one of you pick up the deploy?",
  "participant_identity": "user:019d1357-cb08-7023-b165-fd19e9462316",
  "speaker_name": "Rowan",
  "speaker_kind": "human",
  "spoken_at": "2026-09-03T10:31:07.412Z"
}
```

## Guarantees

- Only segments with `final: true` are delivered. Interim segments are persisted and never leave the database.
- Recipients are agents with an active `meeting_participants` row for the room (`left_at IS NULL`), resolved from `active_participants/1`. Human participants are not recipients.
- The speaking agent never receives its own segment. Exclusion is a string compare of `participant_identity` against `agent:<slug>`, the identity the voice worker publishes under.
- Agent segments are not classified as intents. `Platform.Meetings.IntentClassifier` guard 1 skips any chunk whose speaker is an agent with `%{reason: :agent_speaker}` (`intent_classifier.ex`). Delivery is history, not classification: `deliver_transcript_segment/2` never touches the intent queue.
- Ordering is per append. Within a burst of appends the frames leave in append order, but delivery across agents is best effort and a client should order by `spoken_at` if it cares.
- The runtime is expected to ack each frame with `meeting_transcript_ack` (below), but the ack is advisory: it is fire-and-forget, core never waits for it, and its absence changes nothing about delivery. Delivery never fails the append: an agent with no linked runtime is skipped and logged at `:info`, and an exception inside delivery is caught and logged.
- An agent with a voice row but no brain row is skipped (`:no_runtime`): there is no brain socket to deliver to.

## Reply budget

`Platform.Meetings.say/4` refuses two shapes of runaway reply. Both checks run inside `say/4` after the participant guard and before any token is minted, so every caller is covered. Rate is checked first, then chain, so an exhausted agent sees `reply_budget_exhausted` even when the chain rule would also apply.

| Refusal | Limit | `meeting_say` envelope |
|---|---|---|
| Rate | 6 accepted says per agent per room per trailing 60 000 ms | `code: :reply_budget_exhausted`, `recoverable: true` |
| Chain | Last 3 utterances in the room all agents, no human between | `code: :agent_chain_too_deep`, `recoverable: true` |

The chain rule fires on either of two readings, whichever trips first: the room's transcript ends in 3 final agent segments, or the say ledger holds 3 accepted says (by any agent) since the room's last final human segment. The second reading exists because agent audio is transcribed seconds after the say went out, and two agents firing `say/4` at each other would otherwise outrun the transcript. The ledger and the last-human marker live in `Platform.Meetings.SayRegistry` (ETS, rows swept once older than 5 minutes). The marker is written by `deliver_transcript_segment/2` for every final human segment.

Budget is spent on acceptance, not on ack. A `no_ack` say still counts. The ledger row is removed only if the broadcast itself fails.

What to do on each:

- `reply_budget_exhausted`: stop speaking for the rest of the minute. Post what remains as a chat message in the meeting's space; do not retry `meeting_say` in a loop.
- `agent_chain_too_deep`: wait for a human transcript frame (`speaker_kind: "human"`) in the room before calling `meeting_say` again. Another agent's frame does not reopen the floor.

The constants are exposed as `Meetings.meeting_say_budget_per_minute/0` and `Meetings.meeting_say_max_agent_chain/0`.

## Return frame: `meeting_transcript_ack`

Shipped by task `01a06dfb-2a34-7001-99ec-2d3f3678afe0`. `claude-code-suite-channel` surfaces `meeting_transcript` as an inbound message tagged with `room_name` and `meeting_id` (the way `space` messages arrive with `space_id`) and sends this receipt back on the same socket.

Runtime to core, on the brain's `runtime:<runtime_id>` channel, one per frame handled:

```json
{
  "segment_id": "01a06700-1234-7001-b000-0eac1b8cf949",
  "room_name": "space-01a066cb-60c7-7001-a8e9-5af52dcf4811",
  "build": "0.4.0"
}
```

| Key | Type | Value |
|---|---|---|
| `segment_id` | uuid | The `segment_id` of the frame being acked. Required; a frame without a binary `segment_id` does not match the clause |
| `room_name` | string | The room the frame named. Logged only |
| `build` | string | The plugin's package.json `version`. Logged only |

Handled by `PlatformWeb.RuntimeChannel.handle_in("meeting_transcript_ack", ...)`. Fire-and-forget in the shape of `meeting_say_ack` and `meeting_join_ack`: the receipt is logged, nothing is pushed back down the socket, and no row is written.

Its one effect is `RuntimePresence.prove(runtime_id, "meeting_transcript")`, which stamps the capability and advances `last_seen_at` (`prove/2` subsumes `touch/1`; it is not called alongside one). This ack is the **only** thing that can prove `meeting_transcript`. The proof is deliberately NOT stamped at `deliver_transcript_segment/2`'s broadcast site: that frame is one core sent, and recording a proof from it would be core certifying its own outbound send — every connected runtime would read as able to hear meetings. The discriminating case is `test/platform/meetings/transcript_delivery_test.exs`, "delivering a transcript records NO proof, even when the client declared the feature", which declares the feature in `client_info.features`, asserts the broadcast fired, and still asserts `proven == %{}`.

Proofs do not survive a reconnect (`RuntimePresence.track/1` resets `proven`), so a runtime that reconnects reads `never` for the transcript path until it acks another frame.

The frame above is stable from task `01a06672`'s merge. Keys will only be added, never renamed or removed; a client should read the keys it knows and ignore the rest.
