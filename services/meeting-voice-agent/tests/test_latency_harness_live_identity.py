"""Deterministic unit test for the latency harness's agent-identity matching
default (task 01a0d4a0 stage 5 item 6).

`latency_harness_live.py`'s module docstring explains why the module as a
WHOLE has no unit tests (it needs a real LiveKit room/connection to do
anything else useful) -- but `DEFAULT_AGENT_IDENTITY_PREFIX` and the
`str.startswith` matching built on it are pure, network-free string logic,
and are exactly what Dalton's third live test-host run found broken: the old
default (`"meeting-voice-agent"`, the configured `agent_name`) matched NO
real dispatched worker identity (`"agent-AJ_..."`), so the harness's first
`_wait_for_first_agent_audio_frame` call always timed out and aborted the
whole batch. These tests pin the fixed default without needing a live room.
"""

import json

from meeting_voice_agent import latency_harness_live, tool_telemetry
from meeting_voice_agent.config import AgentConfig


def test_default_prefix_matches_a_real_dispatched_worker_identity():
    # LiveKit's own job-worker identity convention for a dispatched agent
    # job -- see the module's updated docstring on the constant.
    assert "agent-AJ_j93ka0sdlfk".startswith(latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX)


def test_default_prefix_no_longer_the_configured_agent_name():
    # Round 3 regression: the OLD default was the configured worker agent
    # name string itself, which never appears as a participant identity
    # prefix on a real dispatch.
    config = AgentConfig.from_env()
    assert latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX != config.worker_agent_name
    assert latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX != config.agent_name


def test_default_prefix_does_not_match_the_harness_own_synthetic_human_identity():
    # build_access_token/measure_once/_main_async all mint
    # "latency-harness-<timestamp>" for the synthetic human participant --
    # the prefix match must never accidentally treat the harness itself as
    # the target agent.
    assert not "latency-harness-1758758400".startswith(
        latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX
    )


# Task 01a1117f stage 2: a Core-dispatched worker joins as `agent:<uuid>`
# (`agent.accept_arguments`), so the default must match that shape as well as
# the SDK's `agent-<job id>`, while still refusing the harness's own identity.


def test_default_prefix_matches_a_core_dispatched_agent_identity():
    assert "agent:01a0db75-037c-7001-96ff-d2a14fdb707f".startswith(
        latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX
    )


def test_default_prefix_still_matches_the_sdk_default_identity():
    assert "agent-AJ_dtGKmMrmvBKx".startswith(latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX)


def test_default_prefix_refuses_identities_that_only_look_agent_like():
    for identity in ("latency-harness-1758758400", "agentx", "user:agent-1", "Agent:x"):
        assert not identity.startswith(latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX)


def test_tool_call_telemetry_from_a_core_dispatched_worker_is_collected():
    payload = json.dumps([{"name": "space_list", "call_id": "c", "is_error": False}]).encode()

    names = tool_telemetry.parse_tool_call_names(
        tool_telemetry.TOOL_CALL_TOPIC,
        "agent:01a0db75-037c-7001-96ff-d2a14fdb707f",
        payload,
        latency_harness_live.DEFAULT_AGENT_IDENTITY_PREFIX,
    )

    assert names == ["space_list"]
