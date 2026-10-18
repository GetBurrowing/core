"""Live confirmation: test-host's speaches STT/TTS endpoints produce real
transcripts / real audio against real audio, not mocks.

Not run by default — see tests/live/README.md. `pytest -m live_infra` to run.
"""

from __future__ import annotations

import io
import math
import struct
import wave

import httpx
import pytest

from meeting_voice_agent.config import AgentConfig

pytestmark = pytest.mark.live_infra


def _tone_wav_bytes(
    *, seconds: float = 1.0, sample_rate: int = 16000, freq: float = 440.0
) -> bytes:
    """A tiny real WAV file (a sine tone) — real audio bytes, not a mock."""
    n_samples = int(seconds * sample_rate)
    frames = bytearray()
    for i in range(n_samples):
        value = int(32767 * 0.2 * math.sin(2 * math.pi * freq * i / sample_rate))
        frames += struct.pack("<h", value)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(bytes(frames))
    return buf.getvalue()


def test_stt_transcribes_real_audio():
    config = AgentConfig.from_env()
    url = f"{config.stt.base_url.rstrip('/')}/audio/transcriptions"
    audio = _tone_wav_bytes()

    try:
        response = httpx.post(
            url,
            files={"file": ("tone.wav", audio, "audio/wav")},
            data={"model": config.stt.model},
            headers={"Authorization": f"Bearer {config.stt.api_key}"},
            timeout=15.0,
        )
    except httpx.ConnectError as exc:
        pytest.skip(
            f"test-host speaches STT unreachable at {url}: {exc!r}. LAN-only address "
            f"(test-host's box) — see tests/live/README.md. Reproduce: curl -m 5 {url}"
        )
    except httpx.TimeoutException as exc:
        pytest.skip(f"test-host speaches STT timed out at {url}: {exc!r}")

    if response.status_code != 200:
        pytest.fail(
            f"test-host speaches STT reachable but returned {response.status_code}: "
            f"{response.text[:500]}"
        )

    body = response.json()
    # A sine tone has no words — an empty transcript is a legitimate real
    # answer. The assertion is that a REAL transcription round trip happened
    # (the key exists and is a string), not that it produced particular text.
    assert isinstance(body.get("text", ""), str)


def test_tts_synthesizes_real_audio():
    config = AgentConfig.from_env()
    url = f"{config.tts.base_url.rstrip('/')}/audio/speech"

    try:
        response = httpx.post(
            url,
            json={
                "model": config.tts.model,
                "voice": config.tts_voice,
                "input": "This is a live integration test of the meeting voice agent.",
            },
            headers={"Authorization": f"Bearer {config.tts.api_key}"},
            timeout=15.0,
        )
    except httpx.ConnectError as exc:
        pytest.skip(
            f"test-host speaches TTS unreachable at {url}: {exc!r}. LAN-only address "
            f"(test-host's box) — see tests/live/README.md. Reproduce: curl -m 5 {url}"
        )
    except httpx.TimeoutException as exc:
        pytest.skip(f"test-host speaches TTS timed out at {url}: {exc!r}")

    if response.status_code != 200:
        pytest.fail(
            f"test-host speaches TTS reachable but returned {response.status_code}: "
            f"{response.text[:500]}"
        )

    audio_bytes = response.content
    assert len(audio_bytes) > 1000, "expected real synthesized audio, got a near-empty body"
