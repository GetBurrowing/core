"""Live LiveKit-room driver for the first-audio-latency harness (stage 4).

This is the half of the harness that touches real infra: it mints a LiveKit
access token, joins a real room as a synthetic "human" participant, plays a
short WAV fixture into a published audio track (the "human speaks one short
simple question" action in the stage's e2e cases), and times the first audio
frame the target agent participant publishes back.

Everything with actual timing/aggregation logic lives in `latency_harness.py`
and is unit-tested there against fixture data (no network). This module is
intentionally thin glue on top of that: connect, play, listen, hand the two
timestamps to `compute_latency_ms`. It has no unit tests of its own for the
same reason `tests/live/test_wave_llm_live.py` and
`tests/live/test_moon_speech_live.py` don't -- it cannot be exercised without
a real LiveKit server, real STT/LLM/TTS backends, and real audio, and faking
those would defeat the point of a *live* validation. Run it directly (see
README.md's "Latency harness" section) once LiveKit/wave/moon are reachable.

## Round 2 (task 01a0d4a0 stage 4): two bugs Dalton's moon run found

1. **Energy gate.** "First audio frame" used to fire on the agent's very
   first published frame, silent or not -- the agent's LiveKit audio track
   sends a frame every ~20ms whether or not it's actually speaking. Fixed by
   gating on measured signal energy (`latency_harness.is_audio_frame_loud`,
   Dalton's -45 dBFS working value) instead of mere frame arrival.
2. **Session lifecycle.** The old code called `measure_once` (connect,
   measure, disconnect) once per run inside the `--runs N` loop. Disconnecting
   the synthetic human participant after every run drops that participant
   from the room, and `AgentSession` tracks its linked participant -- once
   they leave, the session pauses ("speech scheduling is paused"), so only
   run 1 of N was ever answered for real. Fixed by keeping ONE room
   connection open across all N runs (`_main_async` now connects once and
   loops `_run_measurement` over the same `room`), publishing and
   unpublishing a fresh mic track per run rather than reconnecting the whole
   participant. `measure_once` still exists as a single-run convenience
   wrapper (connect, run once, disconnect) for callers that genuinely want
   one isolated measurement.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import time
import wave
from pathlib import Path

from livekit import api, rtc

from meeting_voice_agent import tool_telemetry
from meeting_voice_agent.latency_harness import (
    DEFAULT_ENERGY_GATE_DBFS,
    LatencySample,
    aggregate_samples,
    compute_latency_ms,
    dump_samples_jsonl,
    format_report,
    is_audio_frame_loud,
    sample_with_tool_call,
)

logger = logging.getLogger("meeting_voice_agent.latency_harness")

#: Default identity PREFIX used to find the target agent's published audio
#: track among all participants in the room.
#:
#: Round 3 (task 01a0d4a0 stage 5 item 6): this used to be
#: `"meeting-voice-agent"` -- the configured `agent_name`/`worker_agent_name`
#: string (see `config.py`'s `MVA_AGENT_NAME`/`MVA_WORKER_AGENT_NAME`) -- on
#: the assumption that a dispatched worker's LiveKit participant identity
#: would start with its own agent name. It never does: livekit-agents mints
#: its OWN identity for a dispatched job's participant, shaped
#: `"agent-<job-id-derived-string>"` (e.g. `agent-AJ_...`), completely
#: independent of `agent_name`/`worker_agent_name`. Against Dalton's real
#: moon deployment this prefix therefore matched NOTHING, so
#: `_wait_for_first_agent_audio_frame` never subscribed to the worker's
#: track and the harness's first run always timed out, aborting the whole
#: batch. `"agent-"` is the correct, deployment-independent prefix: it is
#: LiveKit's own job-worker identity convention, not anything this service
#: configures, so it doesn't need to track `agent_name` and can't drift from
#: it again. It cannot collide with the harness's own synthetic human
#: identity (`"latency-harness-<timestamp>"`, built by
#: `build_access_token`/`measure_once`/`_main_async` above), so no
#: additional exclusion is needed. Still overridable via
#: --agent-identity-prefix for a deployment that dispatches under a
#: different convention.
#:
#: Task 01a1117f stage 2: a Core-dispatched worker now joins as
#: `agent:<agent uuid>` (`agent.accept_arguments`), and only a job started
#: without Core's metadata keeps the SDK's `agent-<job id>`. So the default is
#: BOTH prefixes; `str.startswith` takes the tuple as-is, here and in
#: `tool_telemetry.parse_tool_call_names`. Neither matches the harness's own
#: `latency-harness-<timestamp>` identity.
DEFAULT_AGENT_IDENTITY_PREFIX: tuple[str, ...] = ("agent-", "agent:")


def build_access_token(api_key: str, api_secret: str, room_name: str, identity: str) -> str:
    """A short-lived LiveKit join token for the synthetic human participant."""
    grants = api.VideoGrants(room_join=True, room=room_name)
    return (
        api.AccessToken(api_key, api_secret)
        .with_identity(identity)
        .with_name(identity)
        .with_grants(grants)
        .to_jwt()
    )


def _read_wav_as_frames(path: Path, samples_per_channel: int) -> tuple[list[rtc.AudioFrame], int]:
    """Read a mono 16-bit PCM WAV fixture into a list of `AudioFrame` chunks."""
    with wave.open(str(path), "rb") as wav_file:
        sample_rate = wav_file.getframerate()
        num_channels = wav_file.getnchannels()
        if num_channels != 1:
            raise ValueError(f"{path} must be mono, got {num_channels} channels")
        raw = wav_file.readframes(wav_file.getnframes())

    frames = []
    bytes_per_sample = 2
    chunk_bytes = samples_per_channel * bytes_per_sample
    for offset in range(0, len(raw), chunk_bytes):
        chunk = raw[offset : offset + chunk_bytes]
        if len(chunk) < chunk_bytes:
            chunk = chunk + b"\x00" * (chunk_bytes - len(chunk))
        frame = rtc.AudioFrame(
            data=chunk,
            sample_rate=sample_rate,
            num_channels=1,
            samples_per_channel=samples_per_channel,
        )
        frames.append(frame)
    return frames, sample_rate


async def _publish_question(
    room: rtc.Room, audio_fixture: Path
) -> tuple[float, rtc.LocalTrackPublication]:
    """Publish `audio_fixture` as the human participant's mic track for ONE run.

    Returns `(end_of_speech_monotonic_ts, publication)`. The caller is
    responsible for unpublishing `publication` once the run's response has
    been observed (or has timed out) -- each run gets its own fresh track
    rather than the room's single mic track accumulating one publication per
    run, but the ROOM CONNECTION ITSELF is left alone: only unpublishing this
    track, never disconnecting the participant, is what keeps the worker's
    `AgentSession` alive across a multi-run harness (see module docstring,
    "Session lifecycle").
    """
    samples_per_channel = 480  # 10ms @ 48kHz, matches livekit-agents' own framing
    frames, sample_rate = _read_wav_as_frames(audio_fixture, samples_per_channel)
    source = rtc.AudioSource(sample_rate, 1)
    track = rtc.LocalAudioTrack.create_audio_track("harness-question", source)
    options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    publication = await room.local_participant.publish_track(track, options)

    frame_duration_s = samples_per_channel / sample_rate
    for frame in frames:
        await source.capture_frame(frame)
        await asyncio.sleep(frame_duration_s)

    return time.monotonic(), publication


async def _wait_for_first_agent_audio_frame(
    room: rtc.Room,
    agent_identity_prefix: str | tuple[str, ...],
    after_ts: float,
    timeout_s: float,
    energy_gate_dbfs: float = DEFAULT_ENERGY_GATE_DBFS,
) -> float:
    """Block until the target agent's audio track yields a LOUD frame after `after_ts`.

    Subscribes to every remote audio track whose participant identity starts
    with `agent_identity_prefix` (the meeting-voice-agent worker's identity),
    and returns the monotonic timestamp of the first frame read from any of
    them, once the human's question has finished playing, THAT ALSO PASSES
    THE ENERGY GATE (`is_audio_frame_loud`, `energy_gate_dbfs`) -- a silent
    keepalive frame (the agent's track publishes one every ~20ms regardless
    of whether it's speaking) does not count as "first audio frame". Raises
    `TimeoutError` if nothing loud enough arrives within `timeout_s` -- a
    timeout is a real (very bad) latency result, not something to paper
    over; the caller decides whether to record it as a failed sample or
    re-raise.

    A multi-run harness calls this once per run against the SAME `room` (see
    module docstring, "Session lifecycle"), so every listener and stream this
    function opens is torn down before returning -- otherwise a 25-run batch
    would leave 25x the subscriptions open on a room that's never
    disconnected between runs.
    """
    first_frame_ts: asyncio.Future[float] = asyncio.get_event_loop().create_future()
    streams: list[rtc.AudioStream] = []

    async def _drain(stream: rtc.AudioStream) -> None:
        async for event in stream:
            now = time.monotonic()
            if now < after_ts or first_frame_ts.done():
                continue
            if not is_audio_frame_loud(event.frame.data, threshold_dbfs=energy_gate_dbfs):
                continue
            first_frame_ts.set_result(now)
            return

    def _maybe_subscribe(track: rtc.RemoteAudioTrack, participant: rtc.RemoteParticipant) -> None:
        if not participant.identity.startswith(agent_identity_prefix):
            return
        stream = rtc.AudioStream(track)
        streams.append(stream)
        asyncio.ensure_future(_drain(stream))

    for participant in room.remote_participants.values():
        for publication in participant.track_publications.values():
            if publication.track is not None and isinstance(
                publication.track, rtc.RemoteAudioTrack
            ):
                _maybe_subscribe(publication.track, participant)

    @room.on("track_subscribed")
    def _on_track_subscribed(track, publication, participant):  # noqa: ANN001
        if isinstance(track, rtc.RemoteAudioTrack):
            _maybe_subscribe(track, participant)

    try:
        return await asyncio.wait_for(first_frame_ts, timeout=timeout_s)
    except TimeoutError as exc:
        raise TimeoutError(
            f"no audio frame louder than {energy_gate_dbfs} dBFS from a participant matching "
            f"{agent_identity_prefix!r} within {timeout_s}s of end-of-speech"
        ) from exc
    finally:
        room.off("track_subscribed", _on_track_subscribed)
        for stream in streams:
            await stream.aclose()


class ToolCallCollector:
    """Watches `tool_telemetry.TOOL_CALL_TOPIC` data messages from the target
    agent for the lifetime of one room connection.

    A multi-run harness keeps ONE room connection open across N trials (see
    module docstring), so this is attached once per connection via
    `attach`/`detach` and drained once per trial with `drain_since` rather
    than re-subscribed per run.

    Timestamps recorded are the HARNESS's own `time.monotonic()` at the
    moment each message is received here -- never the worker's `time.time()`
    embedded in the payload (`tool_telemetry.tool_call_payload`), which is a
    different process's wall clock and not safely comparable to this
    process's monotonic clock. This mirrors exactly how
    `_wait_for_first_agent_audio_frame` timestamps audio frames using the
    harness's own clock when it observes them.
    """

    def __init__(self, agent_identity_prefix: str | tuple[str, ...]) -> None:
        self._agent_identity_prefix = agent_identity_prefix
        self._observed: list[tuple[str, float]] = []
        self._room: rtc.Room | None = None

    def attach(self, room: rtc.Room) -> None:
        self._room = room
        room.on("data_received", self._on_data_received)

    def detach(self) -> None:
        if self._room is not None:
            self._room.off("data_received", self._on_data_received)
            self._room = None

    def _on_data_received(self, packet: rtc.DataPacket) -> None:
        received_at = time.monotonic()
        identity = packet.participant.identity if packet.participant is not None else None
        for name in tool_telemetry.parse_tool_call_names(
            packet.topic, identity, packet.data, self._agent_identity_prefix
        ):
            self._observed.append((name, received_at))

    def drain_since(self, after_ts: float) -> list[tuple[str, float]]:
        """Return and clear every `(name, received_ts)` observed at/after `after_ts`.

        Entries observed BEFORE `after_ts` (a stray/late message attributable
        to a previous run) are kept, not dropped, so a slow telemetry publish
        from an earlier run can still be drained correctly by that run
        finishing its own (later) `drain_since` call in the unlikely event
        ordering races.
        """
        keep: list[tuple[str, float]] = []
        result: list[tuple[str, float]] = []
        for name, ts in self._observed:
            (result if ts >= after_ts else keep).append((name, ts))
        self._observed = keep
        return result


async def _run_measurement(
    room: rtc.Room,
    collector: ToolCallCollector,
    *,
    audio_fixture: Path,
    question_text: str,
    agent_identity_prefix: str | tuple[str, ...],
    timeout_s: float,
    energy_gate_dbfs: float,
    case: str,
) -> LatencySample:
    """One measurement turn against an ALREADY-CONNECTED room.

    This is the reusable core `measure_once` and the multi-run loop in
    `_main_async` both call: it never connects or disconnects the room, so
    calling it N times in a row against the same `room` is a real multi-turn
    conversation with the agent's live `AgentSession`, not N independent
    connect/measure/disconnect cycles (see module docstring, "Session
    lifecycle" -- that reconnect-per-run pattern is exactly the bug this
    function's separation from connection management fixes).
    """
    wait_task = asyncio.ensure_future(
        _wait_for_first_agent_audio_frame(
            room, agent_identity_prefix, 0.0, timeout_s, energy_gate_dbfs
        )
    )
    speech_end_ts, publication = await _publish_question(room, audio_fixture)
    try:
        # The waiter needs the real speech_end_ts to filter out any frame the
        # agent happens to already be emitting before the question finishes
        # (e.g. a leftover response to a prior turn) -- re-check against it
        # explicitly rather than trusting the 0.0 placeholder used for early
        # subscription above.
        first_audio_ts = await wait_task
        if first_audio_ts < speech_end_ts:
            first_audio_ts = await _wait_for_first_agent_audio_frame(
                room, agent_identity_prefix, speech_end_ts, timeout_s, energy_gate_dbfs
            )
    finally:
        await room.local_participant.unpublish_track(publication.sid)

    sample = LatencySample(
        case=case,
        question=question_text,
        speech_end_ts=speech_end_ts,
        first_audio_ts=first_audio_ts,
    )

    tool_calls = collector.drain_since(speech_end_ts)
    if tool_calls:
        first_call_ts = tool_calls[0][1]
        sample = sample_with_tool_call(
            sample,
            tool_names=[name for name, _ in tool_calls],
            first_call_latency_ms=compute_latency_ms(speech_end_ts, first_call_ts),
        )

    return sample


async def measure_once(
    *,
    livekit_url: str,
    api_key: str,
    api_secret: str,
    room_name: str,
    audio_fixture: Path,
    question_text: str,
    agent_identity_prefix: str | tuple[str, ...] = DEFAULT_AGENT_IDENTITY_PREFIX,
    timeout_s: float = 15.0,
    energy_gate_dbfs: float = DEFAULT_ENERGY_GATE_DBFS,
    case: str = "simple_latency",
) -> LatencySample:
    """Join `room_name`, play one question, measure, and disconnect. ONE isolated run.

    This is validation 5's "harness instrumented to time from end-of-human-
    speech to first agent audio frame" -- see stage 4's plan entry
    (01a0d4d7-f7b8-7003-b871-122aca19fa84). Kept as a single-run convenience
    wrapper around `_run_measurement` for callers that genuinely want one
    isolated measurement (it connects fresh and disconnects after, exactly
    like before). For `--runs > 1`, `_main_async` does NOT call this in a
    loop -- see module docstring "Session lifecycle" for why that was the
    bug, and why the multi-run path instead keeps one connection open across
    every run via `_run_measurement` directly.
    """
    identity = f"latency-harness-{int(time.time())}"
    token = build_access_token(api_key, api_secret, room_name, identity)
    room = rtc.Room()
    collector = ToolCallCollector(agent_identity_prefix)
    try:
        await room.connect(livekit_url, token)
        collector.attach(room)
        return await _run_measurement(
            room,
            collector,
            audio_fixture=audio_fixture,
            question_text=question_text,
            agent_identity_prefix=agent_identity_prefix,
            timeout_s=timeout_s,
            energy_gate_dbfs=energy_gate_dbfs,
            case=case,
        )
    finally:
        collector.detach()
        await room.disconnect()


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure first-audio latency against a real LiveKit room."
    )
    parser.add_argument("--livekit-url", required=True, help="wss://... LiveKit server URL")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--api-secret", required=True)
    parser.add_argument("--room", required=True, help="Room name the agent is already in")
    parser.add_argument(
        "--audio-fixture",
        type=Path,
        required=True,
        help="Mono 16-bit PCM WAV file with one short spoken question",
    )
    parser.add_argument("--question-text", default="what time is our next meeting")
    parser.add_argument("--agent-identity-prefix", default=DEFAULT_AGENT_IDENTITY_PREFIX)
    parser.add_argument("--timeout-s", type=float, default=15.0)
    parser.add_argument(
        "--energy-gate-dbfs",
        type=float,
        default=DEFAULT_ENERGY_GATE_DBFS,
        help="dBFS threshold a frame must clear to count as real speech, not a silent keepalive",
    )
    parser.add_argument("--runs", type=int, default=1, help="Repeat the measurement N times")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("latency_results.jsonl"),
        help="JSONL file to append each run's sample to",
    )
    return parser.parse_args(argv)


async def _main_async(args: argparse.Namespace) -> None:
    identity = f"latency-harness-{int(time.time())}"
    token = build_access_token(args.api_key, args.api_secret, args.room, identity)
    room = rtc.Room()
    collector = ToolCallCollector(args.agent_identity_prefix)
    samples = []
    try:
        # Connect ONCE for the whole batch of runs. Reconnecting per run (the
        # old behavior) drops the synthetic human participant between runs,
        # which pauses the worker's `AgentSession` -- see module docstring,
        # "Session lifecycle".
        await room.connect(args.livekit_url, token)
        collector.attach(room)

        for run_index in range(args.runs):
            logger.info("run %d/%d", run_index + 1, args.runs)
            sample = await _run_measurement(
                room,
                collector,
                audio_fixture=args.audio_fixture,
                question_text=args.question_text,
                agent_identity_prefix=args.agent_identity_prefix,
                timeout_s=args.timeout_s,
                energy_gate_dbfs=args.energy_gate_dbfs,
                case="simple_latency",
            )
            samples.append(sample)
            dump_samples_jsonl([sample], args.out)
    finally:
        collector.detach()
        await room.disconnect()

    report = aggregate_samples(samples)
    print(format_report(report))


def main(argv: list[str] | None = None) -> None:
    logging.basicConfig(level=logging.INFO)
    args = _parse_args(argv)
    asyncio.run(_main_async(args))


if __name__ == "__main__":
    main()
