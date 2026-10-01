"""Unit tests for MeetingVoiceAgent's space_id instruction wiring
(task 01a0d4a0 stage 5 item 3).

Dalton's live moon run found the model taking three tool-call attempts and
9.1s to successfully call `space_get_context`, because nothing told it its
own space_id and every space-scoped tool requires that parameter. These
tests pin that `space_id`, when given, is stated directly in the agent's
instructions, and that omitting it (the pre-stage-5 shape) leaves the base
instructions untouched.
"""

from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.persona import MeetingVoiceAgent


def test_instructions_include_space_id_when_given():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, space_id="0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")

    assert "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b" in agent.instructions
    assert config.instructions in agent.instructions


def test_instructions_unchanged_when_space_id_omitted():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config)

    assert agent.instructions == config.instructions


def test_instructions_unchanged_when_space_id_is_none_or_empty():
    config = AgentConfig.from_env()

    assert MeetingVoiceAgent(config, space_id=None).instructions == config.instructions
    assert MeetingVoiceAgent(config, space_id="").instructions == config.instructions


def test_tools_default_still_works_alongside_space_id():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, space_id="some-space-id")

    assert "some-space-id" in agent.instructions


# ── Agent roster context (task 01a0f8f5 stage 2) ────────────────────────────


def test_instructions_unchanged_when_roster_empty_or_missing():
    config = AgentConfig.from_env()

    assert MeetingVoiceAgent(config).instructions == config.instructions
    assert MeetingVoiceAgent(config, agent_roster=None).instructions == config.instructions
    assert MeetingVoiceAgent(config, agent_roster=[]).instructions == config.instructions


def test_instructions_name_one_present_agent_with_capability():
    config = AgentConfig.from_env()
    roster = [{"name": "Dana", "slug": "dana", "capability": "Visual design, UI/UX, branding"}]

    agent = MeetingVoiceAgent(config, agent_roster=roster)

    assert config.instructions in agent.instructions
    assert "Dana (Visual design, UI/UX, branding)" in agent.instructions
    # Exactly one sentence appended -- base instructions end mid-sentence
    # with no new paragraph/period-plus-newline structure introduced.
    assert agent.instructions.count("Agents currently present in this meeting include") == 1


def test_instructions_name_two_present_agents_joined_with_and():
    config = AgentConfig.from_env()
    roster = [
        {"name": "Dana", "slug": "dana", "capability": "Visual design, UI/UX, branding"},
        {"name": "Scout", "slug": "scout", "capability": None},
    ]

    agent = MeetingVoiceAgent(config, agent_roster=roster)

    assert "Dana (Visual design, UI/UX, branding) and Scout" in agent.instructions


def test_instructions_never_invent_a_capability():
    config = AgentConfig.from_env()
    roster = [{"name": "Scout", "slug": "scout", "capability": None}]

    agent = MeetingVoiceAgent(config, agent_roster=roster)

    assert "Scout" in agent.instructions
    assert "Scout (" not in agent.instructions


def test_instructions_skip_malformed_roster_entries_without_crashing():
    config = AgentConfig.from_env()
    roster = [
        {"slug": "no-name", "capability": "Mystery"},  # missing name -- skipped
        "not-even-a-dict",  # malformed entirely -- skipped
        {"name": "Scout", "slug": "scout", "capability": None},
    ]

    agent = MeetingVoiceAgent(config, agent_roster=roster)

    assert "Scout" in agent.instructions
    assert "Mystery" not in agent.instructions
    assert "no-name" not in agent.instructions


def test_instructions_unchanged_when_every_roster_entry_is_malformed():
    config = AgentConfig.from_env()
    roster = [{"slug": "no-name"}, "not-a-dict", {}]

    agent = MeetingVoiceAgent(config, agent_roster=roster)

    assert agent.instructions == config.instructions
