# Meeting cohost CRT display

The first implementation adds **CRT face** to an existing voice participant's
meeting tile. Join the meeting normally, enable its call audio, then open that
participant's CRT face and choose Full screen. Escape leaves full screen;
Back to call closes the display. Existing meeting controls own microphone,
speaker, agent invitation, mute and stop. No second meeting connection or audio
output is created. An external display can mirror this browser window; physical
monitor/adapter testing remains necessary.

The face is a centered square with overscan padding. Its mouth measures only the
selected participant's currently playing, unmuted audio track. Host speech does
not drive it. Muted, ended or detached audio closes the mouth. Room disconnect
clears the analyser; closing the display releases its WebAudio context and timer
without stopping the shared remote track. Blink is decorative; mouth motion is
audio-driven. "Ready" means the voice participant exists, not proof that STT or
the model is listening. This increment does not claim a thinking-state signal.

The editable profile is `apps/platform/priv/cohosts/how_to_computer.json`.
In the meeting People rail, enable **How To Computer cohost**, then invite
an existing voice-capable agent using the normal invitation control. The meeting
invitation plumbing carries `mode: "show_cohost"` and `cohost_profile` to the
existing voice worker, whose instruction builder keeps the profile through
context updates. The toggle applies to subsequent invitations on that page;
it does not restart an agent already in the room. Ordinary invitations keep
their existing instructions. This uses the deployment's existing LiveKit voice
dispatch target and speech/model configuration, not a separate local backend.

## Verification so far

- Existing voice-worker unit suite: 260 passed, 6 live-infrastructure cases
  deselected. That does not establish live backend readiness.
- Face and waveform JavaScript: 24 passed.
- Meeting voice session, agent tile and face component: 57 passed on an isolated
  test database. LiveKit was stubbed, not a live provider session.
- A browser fixture exercised a real generated WebAudio track, mouth movement,
  host isolation, mute, disconnect, close/reopen and resource cleanup. It is
  audio-visual mechanism evidence, not a live human conversation.
- Application compiled with warnings-as-errors after rebuilding damaged cached
  dependency artifacts.

No hosted demo URL or real conversation latency is established by these checks.
The development shell has no configured LIVEKIT_URL/key/secret or MVA speech,
model and authenticated MCP endpoints. Use the existing configured voice-worker
deployment for live qualification; do not invent defaults, copy credentials into
source or treat fixture audio as a successful conversation. Remaining delivery:
authenticated show operator flow, deployed compatible worker, actual addressed
conversation and interruption/mute testing, and a studio audio/CRT check.
