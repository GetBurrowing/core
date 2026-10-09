import pytest

from meeting_voice_agent.config import AgentConfig, ConfigError, TurnDetectorConfig


def test_defaults_are_config_not_hardcoded_elsewhere():
    config = AgentConfig.from_env()

    assert config.llm.model == "qwen3.5-9b"
    assert config.llm.fallback_model == "granite4.1-8b"
    assert config.llm.base_url == "http://192.0.2.107:8090/v1"
    assert config.stt.model == "faster-distil-whisper-small.en"
    assert config.tts.model == "kokoro"
    assert config.preemptive_generation is True
    assert config.interruption.allow_interruptions is True


@pytest.mark.parametrize("value", [None, "", "   "])
def test_mcp_base_url_is_required_and_names_the_var(monkeypatch, value):
    """Task 01a116de: MVA_MCP_BASE_URL has no default, because any default
    would name one particular Suite install. Unset, empty and blank all raise
    a config error that names the variable."""
    if value is None:
        monkeypatch.delenv("MVA_MCP_BASE_URL", raising=False)
    else:
        monkeypatch.setenv("MVA_MCP_BASE_URL", value)

    with pytest.raises(ConfigError, match="MVA_MCP_BASE_URL is required"):
        AgentConfig.from_env()


def test_mcp_base_url_env_override_wins(monkeypatch):
    monkeypatch.setenv("MVA_MCP_BASE_URL", "http://core.example/mcp")

    config = AgentConfig.from_env()

    assert config.mcp.base_url == "http://core.example/mcp"


def test_default_instructions_commit_to_one_handoff_tool_deterministically():
    """Task 01a0d4a0 stage 4 round 2: Dalton's moon run found the agent
    trying post_to_meeting_chat, then a prod mail_draft_create write, then
    space_list, across three long spoken turns for one out-of-scope
    question. The default prompt must name the one hand-off tool, require
    calling it once, and explicitly forbid substituting another tool
    (mail especially) when it errors."""
    config = AgentConfig.from_env()

    assert "post_to_meeting_chat" in config.instructions
    assert "exactly once" in config.instructions
    assert "mail" in config.instructions.lower()


def test_default_instructions_do_not_hand_off_simple_questions():
    """Task 01a0d4a0 stage 5 item 4: Dalton's live moon run found '2 plus 2'
    handed off to chat in 3 of 7 asks. The default prompt must give the
    model a concrete anchor for what NOT to hand off."""
    config = AgentConfig.from_env()

    assert "arithmetic" in config.instructions
    assert "just because" in config.instructions


def test_default_instructions_name_the_complete_granted_toolset():
    """Task 01a0d4a0 stage 5 item 4: Dalton's live moon run found the model
    hallucinating calls to meeting_say and space_search_messages. The
    default prompt must name the actual granted tools and say plainly that
    no other tool exists, so the model has no reason to invent one."""
    config = AgentConfig.from_env()

    for name in (
        "post_to_meeting_chat",
        "space_get_context",
        "space_get_messages",
        "space_search_messages",
        "react",
    ):
        assert name in config.instructions

    assert "meeting_say" in config.instructions
    assert "no other tool" in config.instructions.lower()


def test_default_instructions_forbid_any_retry_unambiguously():
    """Task 01a0d4a0 stage 5 item 4: the round-2 wording ('never retry the
    hand-off with a different tool') still let the model retry the SAME
    tool -- Dalton's run saw a retry despite that wording. The prompt must
    say the one call is the complete action, full stop."""
    config = AgentConfig.from_env()

    assert "nothing left to retry" in config.instructions
    assert "exactly once" in config.instructions


def test_default_instructions_call_space_get_context_for_space_context_questions():
    """Task 01a0e8c1-c1c1 stage 3: Dalton's live moon run found the tool-call
    e2e case's own example prompt ("what's the context of this space?")
    triggered no tool call at all. The default prompt names space_get_context
    as an available tool but, before this fix, never told the model WHEN to
    reach for it -- so a "what's the context of / going on in this space"
    style question had no instruction pointing it at the tool that answers
    it. The default prompt must call out that phrasing explicitly."""
    config = AgentConfig.from_env()

    assert "context of this space" in config.instructions.lower()
    assert "going on in this space" in config.instructions.lower()
    assert "space_get_context" in config.instructions


def test_default_instructions_delegate_canvas_and_task_requests():
    """Task 01a0f842 stage 4 (round 2 of Harper's Burrow ticket, item 4),
    and independently task 01a0f8f5 stage 2 (neither had the other's commit
    merged to main yet when its stage ran -- see config.py's reconciliation
    note for the 01a0f8f5 deploy merge that combined these two tests, since
    both landed the identical default-instructions text). Burrow ships with
    every instance as a default capability but her role is PM/helper --
    `allowed_bundles` already refuses her any canvas-write or task/plan tool
    call server-side (see Core's
    apps/platform/test/platform/federation/seed_meeting_voice_agent_test.exs,
    "still excludes canvas, task, and plan"), so this is a prompt gap, not a
    tool-grant gap. Without guidance, she either hallucinated a tool call
    outside her granted list or verbally committed to implementation work
    she structurally cannot do. The default prompt must tell her to name a
    specialized agent and route the request via the existing
    post_to_meeting_chat hand-off instead."""
    config = AgentConfig.from_env()
    instructions = config.instructions.lower()

    assert "PM/helper" in config.instructions
    assert "canvas" in instructions
    assert "specialized agent" in instructions
    assert "task-management agent" in config.instructions
    assert "post_to_meeting_chat" in config.instructions
    assert "do not attempt it" in instructions
    assert "cannot do this" in instructions or "cannot do that" in instructions


def test_instructions_env_override_wins(monkeypatch):
    monkeypatch.setenv("MVA_INSTRUCTIONS", "custom persona instructions")
    config = AgentConfig.from_env()
    assert config.instructions == "custom persona instructions"


def test_env_overrides_llm_model_switch(monkeypatch):
    monkeypatch.setenv("MVA_LLM_MODEL", "custom-primary")
    monkeypatch.setenv("MVA_LLM_FALLBACK_MODEL", "custom-fallback")
    monkeypatch.setenv("MVA_LLM_BASE_URL", "http://example.invalid/v1")

    config = AgentConfig.from_env()

    assert config.llm.model == "custom-primary"
    assert config.llm.fallback_model == "custom-fallback"
    assert config.llm.base_url == "http://example.invalid/v1"


def test_env_overrides_vad_and_endpointing_thresholds(monkeypatch):
    monkeypatch.setenv("MVA_VAD_MIN_SILENCE_DURATION", "0.9")
    monkeypatch.setenv("MVA_VAD_ACTIVATION_THRESHOLD", "0.7")
    monkeypatch.setenv("MVA_MIN_ENDPOINTING_DELAY", "0.25")
    monkeypatch.setenv("MVA_MAX_ENDPOINTING_DELAY", "3.5")

    config = AgentConfig.from_env()

    assert config.vad.min_silence_duration == 0.9
    assert config.vad.activation_threshold == 0.7
    assert config.endpointing.min_endpointing_delay == 0.25
    assert config.endpointing.max_endpointing_delay == 3.5


def test_env_overrides_interruption_barge_in_window(monkeypatch):
    monkeypatch.setenv("MVA_MIN_INTERRUPTION_DURATION", "0.15")
    monkeypatch.setenv("MVA_ALLOW_INTERRUPTIONS", "false")

    config = AgentConfig.from_env()

    assert config.interruption.min_interruption_duration == 0.15
    assert config.interruption.allow_interruptions is False


def test_llm_thinking_off_by_default_builds_extra_body(monkeypatch):
    config = AgentConfig.from_env()
    assert config.llm.extra_body == {"chat_template_kwargs": {"enable_thinking": False}}


def test_llm_thinking_on_flips_extra_body(monkeypatch):
    monkeypatch.setenv("MVA_LLM_THINKING", "true")
    config = AgentConfig.from_env()
    assert config.llm.thinking_enabled is True
    assert config.llm.extra_body == {"chat_template_kwargs": {"enable_thinking": True}}


def test_llm_extra_body_json_override_wins(monkeypatch):
    monkeypatch.setenv("MVA_LLM_EXTRA_BODY_JSON", '{"custom": true}')
    config = AgentConfig.from_env()
    assert config.llm.extra_body == {"custom": True}


def test_turn_detector_model_validated(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "not-a-real-model")
    with pytest.raises(ValueError, match="MVA_TURN_DETECTOR_MODEL"):
        AgentConfig.from_env()


def test_turn_detector_config_defaults_to_english():
    config = TurnDetectorConfig.from_env()
    assert config.model == "english"
    assert config.unlikely_threshold is None


def test_turn_detector_unlikely_threshold_override(monkeypatch):
    monkeypatch.setenv("MVA_TURN_DETECTOR_MODEL", "multilingual")
    monkeypatch.setenv("MVA_TURN_DETECTOR_UNLIKELY_THRESHOLD", "0.8")

    config = TurnDetectorConfig.from_env()

    assert config.model == "multilingual"
    assert config.unlikely_threshold == 0.8


def test_invalid_float_env_raises(monkeypatch):
    monkeypatch.setenv("MVA_VAD_MIN_SILENCE_DURATION", "not-a-float")
    with pytest.raises(ValueError, match="MVA_VAD_MIN_SILENCE_DURATION"):
        AgentConfig.from_env()


def test_ask_floor_grace_ms_defaults_to_300_and_is_not_hardcoded_elsewhere():
    config = AgentConfig.from_env()
    assert config.ask_floor.grace_ms == 300


def test_ask_floor_grace_ms_env_override_wins(monkeypatch):
    monkeypatch.setenv("MVA_ASK_FLOOR_GRACE_MS", "750")
    config = AgentConfig.from_env()
    assert config.ask_floor.grace_ms == 750


def test_ask_floor_grace_ms_can_be_zero(monkeypatch):
    monkeypatch.setenv("MVA_ASK_FLOOR_GRACE_MS", "0")
    config = AgentConfig.from_env()
    assert config.ask_floor.grace_ms == 0
