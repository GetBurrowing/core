"""Hold-to-ask listening-window gate (task 01a0e47c stage 2).

## The gap this closes

`Platform.Meetings.AskFloor.claim/5` (Core, Elixir) is a per-agent
press-and-hold lock: while a human holds the Ask button for THIS agent,
nobody else can claim it, and every connected client sees the button as
held. But `AskFloor` only ever broadcast over Phoenix PubSub -- that never
reached this LiveKit room or this Python worker, so the worker's own
`AgentSession` kept listening and replying to EVERYTHING it heard,
continuously, regardless of whether anyone was holding the button at all.
The nice hold-to-ask UI existed; the voice backend simply ignored it.

Core now signals into this exact room over the LiveKit data channel:

    topic:   "mva.ask_floor"  (ASK_FLOOR_TOPIC)
    payload: {"event": "open"} or {"event": "closed"}   (JSON, UTF-8)

sent as a `RoomService/SendData` Twirp call the instant `AskFloor.claim/5`
succeeds for this specific agent (event "open") and on `AskFloor.release/3`
or the existing stuck-claim timeout (event "closed") --
`apps/platform/lib/platform/meetings.ex`'s `ask_floor_window_signal/3`, only
for a target agent that declared a LiveKit `agent_name`
(`livekit_dispatch_target/1`); every other roster agent is untouched.

## Discard, never buffer

`AskFloorGate.should_forward_audio(now)` answers ONE question: should
audio arriving right now reach VAD/STT at all. `attach_ask_floor_gate`
acts on that answer by flipping `AgentSession.input.set_audio_enabled(...)`
-- which the SDK's own `_ParticipantAudioInputStream._forward_task`
(`livekit.agents.voice.room_io._input`) turns into an outright DISCARD:
while detached, frames are read off the track and dropped on the floor,
never queued, buffered, or handed to `_data_ch` (the channel VAD/STT
actually consume). So speech before the first "open" or after a "closed"
(past its grace window) never reaches the pipeline at all -- there is
nothing here that could prepend or append it to a later hold's audio,
because it is never stored anywhere in the first place.

## The grace window (the declared experiment surface)

See `AskFloorConfig.grace_ms` in `config.py` for the full rationale. In
short: `close()` does not detach the input immediately -- `is_listening`
stays true for `grace_ms` more milliseconds, then the caller
(`attach_ask_floor_gate`'s scheduled task) detaches. A fresh "open" arriving
during that grace window cancels the pending detach outright, so the input
is never disabled during a genuinely continued hold -- it is not detached
then immediately re-enabled, it is simply never detached.

## Default state: closed

Before the very first "open" this session ever receives, the gate starts
closed (`AskFloorGate(...)` with no `.open()` call yet, `is_listening`
False) -- see `attach_ask_floor_gate`, which detaches
`session.input` synchronously before returning, so nothing is ever
listened to before the first real hold.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from livekit import rtc
    from livekit.agents import AgentSession

logger = logging.getLogger("meeting_voice_agent.ask_floor_gate")

#: Data-channel topic Core's `Platform.Meetings.ask_floor_window_signal/3`
#: publishes to. Mirrors `tool_telemetry.TOOL_CALL_TOPIC`'s naming.
ASK_FLOOR_TOPIC = "mva.ask_floor"


def parse_ask_floor_event(topic: str | None, data: bytes) -> str | None:
    """Pure: the ask-floor event named by one room data packet, or `None`.

    Returns `None` (never raises) for a packet that isn't `ASK_FLOOR_TOPIC`,
    whose payload doesn't parse as JSON, or whose `"event"` field is not
    exactly `"open"` or `"closed"` -- a malformed or foreign data packet is
    not a crash, it is just not an ask-floor signal. Mirrors
    `tool_telemetry.parse_tool_call_names`'s defensiveness on purpose.

    Unlike `parse_tool_call_names`, this does NOT check the sender's
    participant identity: Core sends this over `RoomService/SendData`, a
    server-side Twirp call with no LiveKit participant of its own (there
    is no "Core" participant in the room to check an identity against),
    and this worker is the only agent-shaped listener in a given meeting's
    room to begin with.
    """
    if topic != ASK_FLOOR_TOPIC:
        return None
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    event = payload.get("event")
    if event not in ("open", "closed"):
        return None
    return event


@dataclass
class AskFloorGate:
    """Pure state: whether this session should currently be listening.

    Time is always passed in explicitly (`now`, seconds from any monotonic
    clock) rather than read internally, so `should_forward_audio` is unit
    testable without real sleeps -- mirrors `preemptive.py`'s style.
    """

    grace_ms: int
    is_open: bool = False
    closed_at: float | None = None

    def open(self) -> None:
        """An "open" event landed: listen now, and cancel any grace period
        a previous "closed" may have started."""
        self.is_open = True
        self.closed_at = None

    def close(self, now: float) -> None:
        """A "closed" event landed: stop listening after `grace_ms` more
        milliseconds of `now`, unless a fresh `open()` arrives first."""
        self.is_open = False
        self.closed_at = now

    def should_forward_audio(self, now: float) -> bool:
        """Whether audio arriving at `now` should reach VAD/STT.

        True while open. Also true for `grace_ms` milliseconds after the
        most recent `close(now)` -- a REQUEST to keep listening a little
        longer, not a buffer: nothing here stores or replays a frame, this
        only answers whether the pipe should currently be attached.
        False before the very first `open()` (`closed_at` is still `None`)
        and false forever after the grace window elapses.
        """
        if self.is_open:
            return True
        if self.closed_at is None:
            return False
        return (now - self.closed_at) * 1000.0 < self.grace_ms


def attach_ask_floor_gate(session: AgentSession, room: rtc.Room, grace_ms: int) -> AskFloorGate:
    """Wire `AskFloorGate` to `room`'s data channel and `session.input`.

    Call AFTER `AgentSession(...)` is constructed (so `session.input`
    exists) but it does not matter whether this runs before or after
    `session.start(...)` -- `AgentSession.input.set_audio_enabled(False)`
    is safe to call either way (see `io.AgentInput.set_audio_enabled`: with
    no audio stream attached yet it just records the flag, and the stream
    setter reads it back the moment `session.start()` attaches one).

    Detaches input SYNCHRONOUSLY before returning, so the window between
    "session built" and "first `data_received` arrives" is closed, not an
    unguarded gap defaulting to listening.

    ## The attach-time banner (task 01a0fa7e stage 3)

    Harper reported Burrow answering ordinary room conversation with nobody
    holding Ask -- the EXACT symptom this module's own moduledoc describes
    as the bug it fixes ("the worker's own `AgentSession` kept listening
    and replying to EVERYTHING it heard, continuously, regardless of
    whether anyone was holding the button at all"). A full trace of this
    file, `agent.py`, and the Elixir `AskFloor`/`MeetingLive` wiring on
    this branch found the gate correctly wired for a normal press/release
    cycle, and confirmed (via `README.md`'s "Known gap" section) this
    worker never opens a `RuntimeChannel` connection, so Core's
    transcript-fanout/intent-dispatch paths cannot reach it either --
    ruling out every in-repo bypass this stage could find.

    What no in-repo check can rule out: `services/meeting-voice-agent` has
    no Dockerfile and no CI workflow (confirmed: nothing under
    `.github/workflows/` names it), unlike the Elixir platform image that
    `moon` re-pulls hourly. Whatever process is actually answering voice in
    a live meeting is started and restarted by hand, and nothing before
    this line made it observable from the worker's OWN logs whether that
    process is running code that includes this gate at all -- a worker
    process started before this file existed would reproduce Harper's
    symptom exactly, by construction, and no code review of THIS branch
    could ever detect that from here.

    So: log a banner the INSTANT the gate attaches, before any data event,
    naming this exact behavior in a form `grep`-able from the worker's
    stdout. Its ABSENCE from a live worker's logs is diagnostic on its own
    -- a running process with no such line predates this gate and will
    reproduce the reported symptom regardless of what this branch's source
    says.
    """
    gate = AskFloorGate(grace_ms=grace_ms)
    session.input.set_audio_enabled(False)
    logger.info(
        "ask-floor gate: attached and enforcing -- input starts DETACHED, "
        "grace_ms=%d (task 01a0e47c gate; absence of this line in a live "
        "worker's logs means it predates the gate)",
        grace_ms,
    )

    pending_close: asyncio.Task[None] | None = None

    def _cancel_pending_close() -> None:
        nonlocal pending_close
        if pending_close is not None and not pending_close.done():
            pending_close.cancel()
        pending_close = None

    async def _close_after_grace() -> None:
        try:
            await asyncio.sleep(grace_ms / 1000.0)
        except asyncio.CancelledError:
            return
        session.input.set_audio_enabled(False)
        logger.info("ask-floor gate: grace window elapsed, input detached")

    def _on_data_received(packet: rtc.DataPacket) -> None:
        event = parse_ask_floor_event(packet.topic, packet.data)
        if event is None:
            return

        now = time.monotonic()

        if event == "open":
            _cancel_pending_close()
            gate.open()
            session.input.set_audio_enabled(True)
            logger.info("ask-floor gate: open, input attached")
        else:
            _cancel_pending_close()
            gate.close(now)
            if grace_ms <= 0:
                session.input.set_audio_enabled(False)
                logger.info("ask-floor gate: closed, input detached immediately")
            else:
                nonlocal pending_close
                pending_close = asyncio.ensure_future(_close_after_grace())
                logger.info("ask-floor gate: closed, %dms grace before detach", grace_ms)

    room.on("data_received", _on_data_received)
    return gate
