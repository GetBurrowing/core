"""Unit tests for MeetingVoiceAgent's space_id instruction wiring
(task 01a0d4a0 stage 5 item 3).

Dalton's live test-host run found the model taking three tool-call attempts and
9.1s to successfully call `space_get_context`, because nothing told it its
own space_id and every space-scoped tool requires that parameter. These
tests pin that `space_id`, when given, is stated directly in the agent's
instructions, and that omitting it (the pre-stage-5 shape) leaves the base
instructions untouched.
"""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

from meeting_voice_agent import persona as persona_module
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


# ── Task 01a1557a-eab7: Voice-tab voice_context ─────────────────────────────


_CTX = {"kind": "space", "id": "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000", "name": "Roadmap"}


def test_voice_context_appends_one_sentence_naming_the_space():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, voice_context=_CTX)

    assert agent.instructions.startswith(config.instructions)
    assert (
        "The person is asking about Roadmap (space_id 0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000)"
        in agent.instructions
    )


def test_voice_context_none_or_kind_none_leaves_instructions_unchanged():
    config = AgentConfig.from_env()

    for voice_context in (None, {"kind": "none", "id": None, "name": None}, {"kind": "space"}):
        agent = MeetingVoiceAgent(config, voice_context=voice_context)
        assert agent.instructions == config.instructions


def test_voice_context_without_name_falls_back_to_the_id():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, voice_context={"kind": "space", "id": "abc"})

    assert "The person is asking about abc (space_id abc)" in agent.instructions


def test_build_instructions_matches_construction():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, space_id="dm-space", voice_context=_CTX)

    assert agent.instructions == persona_module.build_instructions(
        config, space_id="dm-space", voice_context=_CTX
    )


def test_parse_voice_context_packet():
    parse = persona_module.parse_voice_context_packet
    not_ctx = persona_module._NOT_A_CONTEXT_PACKET

    assert parse("mva.context", json.dumps(_CTX).encode()) == _CTX
    assert parse("mva.context", b'{"kind":"none","id":null,"name":null}') is None
    assert parse("mva.ask_floor", json.dumps(_CTX).encode()) is not_ctx
    assert parse("mva.context", b"not json") is not_ctx
    assert parse("mva.context", b'{"kind":"project","id":"x"}') is not_ctx
    assert parse("mva.context", b"[1]") is not_ctx


def test_mva_context_packet_rebuilds_instructions_with_the_same_builder():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, space_id="dm-space")
    agent.update_instructions = AsyncMock()
    room = MagicMock()

    persona_module.attach_voice_context_handler(agent, room)
    room.on.assert_called_once()
    event, handler = room.on.call_args.args
    assert event == "data_received"

    async def run():
        handler(MagicMock(topic="mva.context", data=json.dumps(_CTX).encode()))
        handler(MagicMock(topic="mva.ask_floor", data=b'{"event":"open"}'))
        await asyncio.sleep(0)
        await asyncio.sleep(0)

    asyncio.run(run())

    agent.update_instructions.assert_awaited_once_with(
        persona_module.build_instructions(config, space_id="dm-space", voice_context=_CTX)
    )
    assert agent.voice_context == _CTX


def test_mva_context_none_restores_the_base_instructions():
    config = AgentConfig.from_env()
    agent = MeetingVoiceAgent(config, voice_context=_CTX)
    agent.update_instructions = AsyncMock()
    room = MagicMock()
    persona_module.attach_voice_context_handler(agent, room)
    handler = room.on.call_args.args[1]

    async def run():
        handler(MagicMock(topic="mva.context", data=b'{"kind":"none","id":null,"name":null}'))
        await asyncio.sleep(0)
        await asyncio.sleep(0)

    asyncio.run(run())

    agent.update_instructions.assert_awaited_once_with(config.instructions)
