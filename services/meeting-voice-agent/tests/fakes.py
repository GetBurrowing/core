"""In-process fakes for driving a REAL `livekit.agents.AgentSession`.

Task 01a174e2: the Voice-tab release has to commit the user turn, and that
can only be proven against the SDK's own turn machinery (AudioRecognition,
the STT StreamAdapter, AgentActivity's reply pipeline), not against a
MagicMock session. These fakes replace only the network edges: VAD, STT,
LLM, TTS and the audio track. They follow the shape of livekit/agents' own
`tests/fake_vad.py`, `fake_stt.py`, `fake_llm.py`, `fake_tts.py` and
`fake_io.py`, simplified to what these tests need. No network, no models.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass

from livekit import rtc
from livekit.agents import APIConnectOptions, llm, stt, tts, vad
from livekit.agents.types import DEFAULT_API_CONNECT_OPTIONS, NOT_GIVEN, NotGivenOr
from livekit.agents.utils import AudioBuffer, shortuuid
from livekit.agents.voice.io import AudioInput, AudioOutput, AudioOutputCapabilities

SAMPLE_RATE = 16000
FRAME_MS = 20
SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_MS // 1000


def audio_frame(*, speech: bool) -> rtc.AudioFrame:
    """One 20 ms mono 16 kHz frame: a constant non-zero level, or silence."""
    level = 1000 if speech else 0
    data = level.to_bytes(2, "little", signed=True) * SAMPLES_PER_FRAME
    return rtc.AudioFrame(
        data=data,
        sample_rate=SAMPLE_RATE,
        num_channels=1,
        samples_per_channel=SAMPLES_PER_FRAME,
    )


def speech_frames(seconds: float) -> list[rtc.AudioFrame]:
    return [audio_frame(speech=True) for _ in range(round(seconds * 1000 / FRAME_MS))]


def _is_speech(frame: rtc.AudioFrame) -> bool:
    return any(frame.data)


# ── VAD ─────────────────────────────────────────────────────────────────


class FakeVAD(vad.VAD):
    """Energy VAD: START on the first non-silent frame, END after
    `min_silence_duration` of silent frames (counted in audio time, not wall
    time, so frames may be pushed faster than real time)."""

    def __init__(self, *, min_silence_duration: float = 0.55) -> None:
        super().__init__(capabilities=vad.VADCapabilities(update_interval=FRAME_MS / 1000))
        self._min_silence_duration = min_silence_duration

    def stream(self) -> FakeVADStream:
        return FakeVADStream(self, self._min_silence_duration)


class FakeVADStream(vad.VADStream):
    def __init__(self, vad_: FakeVAD, min_silence_duration: float) -> None:
        self._min_silence_duration = min_silence_duration
        super().__init__(vad_)

    async def _main_task(self) -> None:
        speaking = False
        speech_dur = 0.0
        silence_dur = 0.0
        samples_index = 0
        speech_buf: list[rtc.AudioFrame] = []

        async for item in self._input_ch:
            if isinstance(item, vad.VADStream._FlushSentinel):
                speaking, speech_dur, silence_dur, speech_buf = False, 0.0, 0.0, []
                continue

            frame = item
            samples_index += frame.samples_per_channel
            dur = frame.samples_per_channel / frame.sample_rate
            is_speech = _is_speech(frame)

            if is_speech:
                silence_dur = 0.0
                if not speaking:
                    speaking = True
                    speech_dur = 0.0
                    speech_buf = []
                    self._event_ch.send_nowait(
                        vad.VADEvent(
                            type=vad.VADEventType.START_OF_SPEECH,
                            samples_index=samples_index,
                            timestamp=time.time(),
                            speech_duration=0.0,
                            silence_duration=0.0,
                            frames=[frame],
                            speaking=True,
                        )
                    )
                speech_dur += dur
            elif speaking:
                silence_dur += dur

            if speaking:
                speech_buf.append(frame)

            self._event_ch.send_nowait(
                vad.VADEvent(
                    type=vad.VADEventType.INFERENCE_DONE,
                    samples_index=samples_index,
                    timestamp=time.time(),
                    speech_duration=speech_dur if speaking else 0.0,
                    silence_duration=silence_dur,
                    frames=[frame],
                    probability=1.0 if is_speech else 0.0,
                    speaking=speaking,
                    raw_accumulated_speech=speech_dur if is_speech else 0.0,
                    raw_accumulated_silence=silence_dur,
                )
            )

            if speaking and silence_dur >= self._min_silence_duration:
                self._event_ch.send_nowait(
                    vad.VADEvent(
                        type=vad.VADEventType.END_OF_SPEECH,
                        samples_index=samples_index,
                        timestamp=time.time(),
                        speech_duration=speech_dur,
                        silence_duration=silence_dur,
                        frames=speech_buf,
                        speaking=False,
                    )
                )
                speaking, speech_dur, silence_dur, speech_buf = False, 0.0, 0.0, []


# ── STT ─────────────────────────────────────────────────────────────────


class FakeSTT(stt.STT):
    """Non-streaming STT: `recognize` waits `delay` seconds of wall time,
    then returns `transcript` (or, given a list, the Nth entry for the Nth
    call, repeating the last). The session wraps it in the SDK's
    `stt.StreamAdapter`, exactly like the worker's OpenAI-compatible STT."""

    def __init__(self, *, transcript: str | list[str], delay: float) -> None:
        super().__init__(capabilities=stt.STTCapabilities(streaming=False, interim_results=False))
        self.transcript = transcript
        self.delay = delay
        self.recognize_started: list[float] = []
        self.recognize_returned: list[float] = []

    @property
    def model(self) -> str:
        return "fake-stt"

    @property
    def provider(self) -> str:
        return "fake"

    async def _recognize_impl(
        self,
        buffer: AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions,
    ) -> stt.SpeechEvent:
        n = len(self.recognize_started)
        self.recognize_started.append(time.monotonic())
        if isinstance(self.transcript, list):
            text = self.transcript[min(n, len(self.transcript) - 1)]
        else:
            text = self.transcript
        await asyncio.sleep(self.delay)
        self.recognize_returned.append(time.monotonic())
        return stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT,
            alternatives=[stt.SpeechData(language="en", text=text)],
        )


# ── LLM ─────────────────────────────────────────────────────────────────


@dataclass
class LLMCall:
    at: float
    chat_ctx: llm.ChatContext

    def last_user_text(self) -> str | None:
        for item in reversed(self.chat_ctx.items):
            if getattr(item, "role", None) == "user":
                return item.text_content
        return None


class FakeLLM(llm.LLM):
    """Records every `chat()` call and streams `reply` back word by word."""

    def __init__(self, *, reply: str = "Here is your answer.") -> None:
        super().__init__()
        self.reply = reply
        self.calls: list[LLMCall] = []

    @property
    def model(self) -> str:
        return "fake-llm"

    @property
    def provider(self) -> str:
        return "fake"

    def chat(
        self,
        *,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool] | None = None,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
        parallel_tool_calls: NotGivenOr[bool] = NOT_GIVEN,
        tool_choice: NotGivenOr[llm.ToolChoice] = NOT_GIVEN,
        extra_kwargs: NotGivenOr[dict] = NOT_GIVEN,
    ) -> FakeLLMStream:
        self.calls.append(LLMCall(at=time.monotonic(), chat_ctx=chat_ctx.copy()))
        return FakeLLMStream(self, chat_ctx=chat_ctx, tools=tools or [], conn_options=conn_options)


class FakeLLMStream(llm.LLMStream):
    async def _run(self) -> None:
        assert isinstance(self._llm, FakeLLM)
        request_id = shortuuid()
        words = self._llm.reply.split(" ")
        for i, word in enumerate(words):
            text = word if i == 0 else " " + word
            self._event_ch.send_nowait(
                llm.ChatChunk(id=request_id, delta=llm.ChoiceDelta(role="assistant", content=text))
            )
            await asyncio.sleep(0)


# ── TTS ─────────────────────────────────────────────────────────────────


class FakeTTS(tts.TTS):
    """Non-streaming TTS: `audio_per_char` seconds of silence per input
    character, so speech has a real duration on `FakeAudioOutput`."""

    def __init__(self, *, audio_per_char: float = 0.05) -> None:
        super().__init__(
            capabilities=tts.TTSCapabilities(streaming=False),
            sample_rate=SAMPLE_RATE,
            num_channels=1,
        )
        self.audio_per_char = audio_per_char
        self.synthesized: list[str] = []

    @property
    def model(self) -> str:
        return "fake-tts"

    @property
    def provider(self) -> str:
        return "fake"

    def synthesize(
        self, text: str, *, conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS
    ) -> FakeChunkedStream:
        self.synthesized.append(text)
        return FakeChunkedStream(tts=self, input_text=text, conn_options=conn_options)


class FakeChunkedStream(tts.ChunkedStream):
    async def _run(self, output_emitter: tts.AudioEmitter) -> None:
        assert isinstance(self._tts, FakeTTS)
        output_emitter.initialize(
            request_id=shortuuid(),
            sample_rate=SAMPLE_RATE,
            num_channels=1,
            mime_type="audio/pcm",
        )
        seconds = max(FRAME_MS / 1000, len(self._input_text) * self._tts.audio_per_char)
        output_emitter.push(b"\x00\x00" * int(seconds * SAMPLE_RATE))
        output_emitter.flush()


# ── Audio I/O ───────────────────────────────────────────────────────────


class FakeAudioInput(AudioInput):
    """The participant's mic track as `session.input.audio`.

    Mirrors `room_io._input._ParticipantInputStream`: a frame arriving while
    the input is detached is dropped, never buffered. Tests `push()` frames
    the way the track would deliver them.
    """

    def __init__(self) -> None:
        super().__init__(label="FakeAudioInput")
        self._queue: asyncio.Queue[rtc.AudioFrame] = asyncio.Queue()
        self.attached = True
        self.dropped = 0

    def push(self, frames: list[rtc.AudioFrame]) -> None:
        for frame in frames:
            if self.attached:
                self._queue.put_nowait(frame)
            else:
                self.dropped += 1

    async def __anext__(self) -> rtc.AudioFrame:
        return await self._queue.get()

    def on_attached(self) -> None:
        self.attached = True

    def on_detached(self) -> None:
        self.attached = False


@dataclass
class _Playback:
    duration: float = 0.0
    task: asyncio.Task | None = None
    started_at: float = 0.0


class FakeAudioOutput(AudioOutput):
    """Plays captured audio in real time, like livekit/agents' fake_io
    sink, so the agent is genuinely "speaking" for the audio's duration and
    `clear_buffer()` (an interrupt) cuts it short."""

    def __init__(self) -> None:
        super().__init__(
            label="FakeAudioOutput",
            capabilities=AudioOutputCapabilities(pause=False),
            sample_rate=SAMPLE_RATE,
        )
        self._current = _Playback()
        self.interrupted: list[float] = []
        self._pending: list[asyncio.Task] = []

    async def capture_frame(self, frame: rtc.AudioFrame) -> None:
        await super().capture_frame(frame)
        self._current.duration += frame.duration

    def flush(self) -> None:
        super().flush()
        playback = self._current
        self._current = _Playback()

        async def _play() -> None:
            playback.started_at = time.time()
            self.on_playback_started(created_at=playback.started_at)
            try:
                await asyncio.sleep(playback.duration)
            except asyncio.CancelledError:
                elapsed = time.time() - playback.started_at
                self.interrupted.append(elapsed)
                self.on_playback_finished(playback_position=elapsed, interrupted=True)
                return
            self.on_playback_finished(playback_position=playback.duration, interrupted=False)

        playback.task = asyncio.ensure_future(_play())
        self._pending.append(playback.task)

    def clear_buffer(self) -> None:
        if self._current.duration > 0:
            # captured but not yet flushed: end that segment as interrupted
            super().flush()
            self._current = _Playback()
            self.interrupted.append(0.0)
            self.on_playback_finished(playback_position=0.0, interrupted=True)
        for task in self._pending:
            if not task.done():
                task.cancel()
        self._pending = []
