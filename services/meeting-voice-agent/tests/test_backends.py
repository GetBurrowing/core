"""Backend seam tests. Every livekit plugin constructor is mocked — no real
model load, no network call. These tests verify config values reach the SDK
call, not that the SDK itself works.
"""

from unittest.mock import MagicMock, patch

from meeting_voice_agent import backends
from meeting_voice_agent.config import AgentConfig, TurnDetectorConfig


def test_build_vad_passes_config_thresholds(monkeypatch):
    monkeypatch.setenv("MVA_VAD_MIN_SPEECH_DURATION", "0.1")
    monkeypatch.setenv("MVA_VAD_MIN_SILENCE_DURATION", "0.4")
    monkeypatch.setenv("MVA_VAD_ACTIVATION_THRESHOLD", "0.6")
    config = AgentConfig.from_env()

    with patch.object(backends.lk_silero.VAD, "load") as mock_load:
        mock_load.return_value = MagicMock()
        result = backends.build_vad(config)

    mock_load.assert_called_once_with(
        min_speech_duration=0.1,
        min_silence_duration=0.4,
        activation_threshold=0.6,
        prefix_padding_duration=0.5,
        sample_rate=16000,
    )
    assert result is mock_load.return_value


def test_build_stt_uses_the_configured_endpoint_and_default_model():
    config = AgentConfig.from_env()

    with patch.object(backends.lk_openai, "STT") as mock_stt:
        mock_stt.return_value = MagicMock()
        result = backends.build_stt(config)

    mock_stt.assert_called_once_with(
        base_url="http://stt.example.test:8081/v1",
        model="faster-distil-whisper-small.en",
        api_key="not-needed",
    )
    assert result is mock_stt.return_value


def test_build_stt_honors_env_override(monkeypatch):
    monkeypatch.setenv("MVA_STT_BASE_URL", "http://test-host-box:9001/v1")
    monkeypatch.setenv("MVA_STT_MODEL", "some-other-stt")
    config = AgentConfig.from_env()

    with patch.object(backends.lk_openai, "STT") as mock_stt:
        backends.build_stt(config)

    mock_stt.assert_called_once_with(
        base_url="http://test-host-box:9001/v1",
        model="some-other-stt",
        api_key="not-needed",
    )


def test_build_tts_uses_kokoro_default_voice():
    config = AgentConfig.from_env()

    with patch.object(backends.lk_openai, "TTS") as mock_tts:
        backends.build_tts(config)

    mock_tts.assert_called_once_with(
        base_url="http://tts.example.test:8081/v1",
        model="kokoro",
        voice="af_heart",
        api_key="not-needed",
    )


def test_build_llm_uses_primary_model_by_default():
    config = AgentConfig.from_env()

    with patch.object(backends.lk_openai, "LLM") as mock_llm:
        backends.build_llm(config)

    mock_llm.assert_called_once_with(
        base_url="http://llm.example.test:8090/v1",
        model="qwen3.5-9b",
        api_key="not-needed",
        extra_body={"chat_template_kwargs": {"enable_thinking": False}},
    )


def test_build_llm_use_fallback_switches_model():
    config = AgentConfig.from_env()

    with patch.object(backends.lk_openai, "LLM") as mock_llm:
        backends.build_llm(config, use_fallback=True)

    _, kwargs = mock_llm.call_args
    assert kwargs["model"] == "granite4.1-8b"


def test_select_llm_model_pure_switch():
    config = AgentConfig.from_env()

    assert backends.select_llm_model(config, primary_failed=False) == "qwen3.5-9b"
    assert backends.select_llm_model(config, primary_failed=True) == "granite4.1-8b"


def test_build_turn_detector_english_default():
    config = TurnDetectorConfig.from_env()

    with patch.object(backends, "EnglishModel") as mock_model:
        mock_model.return_value = MagicMock()
        result = backends.build_turn_detector(config)

    mock_model.assert_called_once_with()
    assert result is mock_model.return_value


def test_build_turn_detector_multilingual_with_threshold(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "multilingual")
    monkeypatch.setenv("MVA_TURN_DETECTOR_UNLIKELY_THRESHOLD", "0.85")
    config = TurnDetectorConfig.from_env()

    with patch.object(backends, "MultilingualModel") as mock_model:
        backends.build_turn_detector(config)

    mock_model.assert_called_once_with(unlikely_threshold=0.85)


def test_build_turn_detector_none_disables_model(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "none")
    config = TurnDetectorConfig.from_env()

    result = backends.build_turn_detector(config)

    assert result is None
