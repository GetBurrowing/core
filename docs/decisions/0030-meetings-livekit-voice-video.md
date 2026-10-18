# ADR 0030: Meetings — LiveKit-Powered Voice & Video Chat

- **Status:** Accepted
- **Date:** 2026-03-26
- **Owners:** the product owner

## Context

Burrow currently has text-based chat with spaces (channels, DMs, execution spaces). Users and agents communicate exclusively through messages. There is no real-time voice or video capability.

Discord-style persistent voice/video channels are a natural extension: users drop in and out of a voice room associated with a space, see who's connected, and optionally share video or screens. Agents should also be able to join calls, enabling voice-driven interaction alongside the existing text channel.

### Existing Infrastructure

- **LiveKit 1.9.11** already runs on build-host (`~/docker/stacks/livekit/`)
- **SIP trunk** (Telnyx) with phone number `+1 555-010-0100` for inbound/outbound calls
- **Voice agent SDK** (Python, LiveKit Agents SDK 1.4.4) already handles phone-based agent conversations
- **LiveKit Egress** available for recording
- **LiveKit MCP** at `http://192.0.2.12:8090/mcp/` for room management

The infrastructure exists. This decision is about how Burrow consumes it.

## Decision

### Architecture: Burrow as LiveKit client, not media server

Burrow generates LiveKit access tokens and manages room lifecycle. LiveKit handles all media transport (WebRTC, SFU, simulcast, ICE/STUN/TURN). This mirrors how Discord, Slack, and Teams separate chat servers from media servers.

```
┌──────────────────────────────────┐     ┌─────────────────────┐
│         Burrow Platform          │     │      LiveKit SFU     │
│                                  │     │                      │
│  Meetings context                │     │  Rooms               │
│  ├─ create/destroy rooms ───────────►  │  ├─ media routing    │
│  ├─ generate JWT tokens  ───────────►  │  ├─ ICE/STUN/TURN   │
│  ├─ track participants (PubSub)  │     │  ├─ simulcast        │
│  └─ webhook receiver     ◄───────────  │  └─ recording (Egress)│
│                                  │     │                      │
│  LiveView UI                     │     └─────────────────────┘
│  ├─ JS hook + livekit-client SDK │              ▲
│  ├─ audio/video controls         │              │
│  └─ presence indicators          │              │
│                                  │     ┌────────┴────────────┐
└──────────────────────────────────┘     │  Agent Voice Worker  │
                                         │  (LiveKit Agents SDK)│
                                         └─────────────────────┘
```

### Feature gating via environment variables

LiveKit integration is **opt-in** via environment variables. When not configured, the Meetings module is inert — no UI surfaces, no routes, no background processes.

```elixir
LIVEKIT_URL=wss://voice.example.com
LIVEKIT_API_KEY=<key>
LIVEKIT_API_SECRET=<secret>
LIVEKIT_WEBHOOK_SECRET=<secret>  # optional, for room/participant event webhooks
```

`Platform.Meetings.enabled?/0` checks for the presence of these vars. All UI components, routes, and background processes guard on this.

### Domain model: `Platform.Meetings`

#### Schemas

**`meeting_rooms`** — persistent room records, one per space that has voice enabled.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUIDv7 | PK |
| `space_id` | uuid FK → chat_spaces | unique |
| `livekit_room_name` | varchar | unique |
| `status` | varchar | idle, active, recording |
| `config` | jsonb | default {} |

**`meeting_participants`** — who is currently in a room (ephemeral).

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUIDv7 | PK |
| `room_id` | uuid FK → meeting_rooms | |
| `user_id` | uuid FK → users | nullable |
| `agent_id` | uuid FK → agents | nullable |
| `display_name` | varchar | |
| `joined_at` | timestamptz | |
| `left_at` | timestamptz | nullable |

**`meeting_recordings`** — recording artifacts.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUIDv7 | PK |
| `room_id` | uuid FK → meeting_rooms | |
| `space_id` | uuid FK → chat_spaces | |
| `egress_id` | varchar | LiveKit Egress ID |
| `status` | varchar | recording, processing, ready, failed |
| `duration_seconds` | integer | |
| `file_url` | varchar | |

### Token generation

Burrow generates short-lived LiveKit JWTs signed with the API secret. Tokens are scoped to a specific room name, participant identity (user/agent UUID), permissions (publish audio/video, subscribe, screen share), and a 6-hour TTL.

The `livekit` Elixir hex package provides `Livekit.AccessToken` for this.

### LiveView integration

A `MeetingRoom` JS hook wraps the `livekit-client` SDK:
- Receives token via `push_event` on join
- Manages Room connection, track subscription, media elements
- Sends participant events back to LiveView via `pushEvent`

Persistent audio across navigation via a root-level `MeetingBarLive` component in the app layout. The LiveKit Room instance lives outside per-page LiveViews so calls survive navigation.

### Webhook receiver

`POST /api/webhooks/livekit` receives room events:

| Event | Action |
|-------|--------|
| `participant_joined` | Insert participant record, broadcast presence |
| `participant_left` | Set `left_at`, broadcast presence |
| `room_started` | Room status → active |
| `room_finished` | Room status → idle, clean up |
| `egress_ended` | Update recording status, store file URL |

### Agent integration

Agents join via the existing LiveKit Agents SDK (Python). Burrow generates an agent token and dispatches a `meeting_join` signal to the agent runtime. The agent connects, listens via STT, responds via TTS.

How a seated agent hears the room is specified in [docs/contracts/meeting-transcript-frame.md](../contracts/meeting-transcript-frame.md): every final transcript segment is pushed to the agent's brain runtime as a `meeting_transcript` frame, never to the voice worker. The same document covers the reply budget that `Platform.Meetings.say/4` enforces before any `meeting_say` reaches a voice worker.

## Implementation phases

### Phase 1 — Voice & Video MVP
1. `Platform.Meetings` context + schemas + migrations
2. LiveKit webhook receiver
3. Join Meeting UI + LiveKit JS client hook
4. Participant presence indicators
5. Persistent audio bar

### Phase 2 — Rich features
6. Screen sharing
7. Speaker detection + highlight
8. Meeting recordings (Egress → artifacts)
9. Mobile PWA support

### Phase 3 — Agent voice
10. Agent join/leave via dispatch signal
11. Voice interaction (STT → LLM → TTS)
12. Meeting transcription + summary

## Consequences

### Positive
- Reuses existing LiveKit infrastructure
- Feature-gated — zero impact without LiveKit configured
- Clean domain boundary via `Platform.Meetings`
- Agent voice is a natural extension of existing voice agent work

### Tradeoffs
- Meetings depend on LiveKit availability
- Persistent audio adds LiveView lifecycle complexity
- JS bundle size increases with `livekit-client` (~150KB gzipped)

### Risks
- Mobile PWA WebRTC support is inconsistent
- Agent voice workers are Python (separate from Elixir app)
- Recording storage needs a backend decision (local, S3, Nextcloud)

## Guardrails

- Do not embed LiveKit configuration in the public repo — env vars only
- All rooms must be created through `Platform.Meetings` — no direct LiveKit API calls from clients
- Do not store API secrets in the database
- Participant identity must map to Burrow user/agent UUIDs — no anonymous participants
- Recording files must be access-controlled through Burrow
