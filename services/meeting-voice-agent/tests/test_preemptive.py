from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.preemptive import TurnSignal, should_start_preemptive_generation


def test_disabled_never_fires(monkeypatch):
    monkeypatch.setenv("MVA_PREEMPTIVE_GENERATION", "false")
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=0.99, silence_duration=5.0, interim_transcript_chars=40
    )

    assert should_start_preemptive_generation(signal, config) is False


def test_no_transcript_never_fires():
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=0.99, silence_duration=5.0, interim_transcript_chars=0
    )

    assert should_start_preemptive_generation(signal, config) is False


def test_before_min_endpointing_delay_does_not_fire(monkeypatch):
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.5")
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=0.99, silence_duration=0.2, interim_transcript_chars=40
    )

    assert should_start_preemptive_generation(signal, config) is False


def test_vad_only_mode_fires_once_silence_passes_delay(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "none")
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.4")
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=None, silence_duration=0.41, interim_transcript_chars=10
    )

    assert should_start_preemptive_generation(signal, config) is True


def test_turn_detector_mode_waits_for_probability_above_threshold(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "english")
    monkeypatch.setenv("MVA_TURN_DETECTOR_UNLIKELY_THRESHOLD", "0.7")
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.1")
    config = AgentConfig.from_env()

    below = TurnSignal(
        end_of_turn_probability=0.5, silence_duration=0.2, interim_transcript_chars=10
    )
    above = TurnSignal(
        end_of_turn_probability=0.75, silence_duration=0.2, interim_transcript_chars=10
    )

    assert should_start_preemptive_generation(below, config) is False
    assert should_start_preemptive_generation(above, config) is True


def test_turn_detector_mode_without_probability_does_not_fire(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "english")
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.1")
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=None, silence_duration=0.2, interim_transcript_chars=10
    )

    # No turn-detector reading yet even though a model is configured: wait.
    assert should_start_preemptive_generation(signal, config) is False


def test_default_threshold_fires_on_any_nonzero_probability_past_delay(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "english")
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.1")
    config = AgentConfig.from_env()
    signal = TurnSignal(
        end_of_turn_probability=0.01, silence_duration=0.2, interim_transcript_chars=10
    )

    assert should_start_preemptive_generation(signal, config) is True
