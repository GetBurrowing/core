"""Worker entrypoint: connects a job to its room and starts the AgentSession.

Run as a worker with:

    python -m meeting_voice_agent.agent start

livekit-agents' CLI handles connecting to the LiveKit server (LIVEKIT_URL /
LIVEKIT_API_KEY / LIVEKIT_API_SECRET, standard env vars the SDK reads itself)
and dispatching jobs to `entrypoint` below.
"""

from __future__ import annotations

import json
import logging

from livekit.agents import AgentSession, JobContext, JobRequest, WorkerOptions, cli
from livekit.agents.types import NOT_GIVEN, NotGivenOr
from livekit.agents.voice.room_io import RoomOptions

from meeting_voice_agent import ask_floor_gate, mcp_tools, tool_telemetry
from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.persona import MeetingVoiceAgent
from meeting_voice_agent.session import build_agent_session

logger = logging.getLogger("meeting_voice_agent")


def parse_job_metadata(raw: str | None) -> dict:
    """Best-effort parse of the LiveKit job's own `metadata` string.

    Task 01a0d4a0 stage 5 item 3: `Platform.Meetings.create_livekit_agent_dispatch/3`
    (via `dispatch_meeting_join_via_livekit/4` in `apps/platform/lib/platform/meetings.ex`)
    JSON-encodes `space_id`, `meeting_id`, and `human_identity` into this
    exact field when it dispatches the job. Task 01a0f8f5 stage 1 adds
    `agent_roster` to that same blob. Never raises: a job started some
    other way (a manually-launched dev worker, a test), one dispatched
    before `agent_roster` existed, or one with malformed metadata should
    degrade to the old room-name-derived behavior, not crash worker
    startup.
    """
    if not raw:
        return {}

    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        logger.warning("job metadata is not valid JSON, ignoring: %r", raw)
        return {}

    if not isinstance(parsed, dict):
        logger.warning("job metadata JSON is not an object, ignoring: %r", raw)
        return {}

    return parsed


#: The identity prefix Core's dispatch metadata uses for an agent participant.
#: `Platform.Meetings.parse_identity/1` casts `agent:<uuid>` to the agent FK,
#: and MeetingLive keys agent tiles by the same string.
AGENT_IDENTITY_PREFIX = "agent:"


def accept_arguments(metadata: dict) -> dict:
    """Keyword arguments for `JobRequest.accept` from the parsed job metadata.

    Task 01a1117f stage 2: Core's `dispatch_meeting_join_via_livekit/4` puts
    `agent_id`, `agent_identity` (`"agent:" <> agent.id`) and `agent_name` in
    the job metadata. Joining under that identity makes the worker the SAME
    participant as the agent's invite row in Core. Under the SDK default
    (`"agent-" + job.id`) it showed up as an extra "Unknown participant".

    When `agent_identity` is missing, not a string, or not `agent:`-prefixed
    (an older Core, a manually started job, malformed metadata), this returns
    `{}`. `req.accept()` then keeps the SDK default identity, which is exactly
    what the worker did before. A job is never rejected over its metadata.

    The agent is never derived from `config.worker_agent_name`: several Suite
    agents can share one worker name, so only the dispatch metadata says which
    agent this job is for.
    """
    identity = metadata.get("agent_identity")
    if not isinstance(identity, str) or not identity.startswith(AGENT_IDENTITY_PREFIX):
        return {}
    if identity == AGENT_IDENTITY_PREFIX:
        return {}

    args: dict = {"identity": identity}

    name = metadata.get("agent_name")
    if isinstance(name, str) and name:
        args["name"] = name

    agent_id = metadata.get("agent_id")
    if isinstance(agent_id, str) and agent_id:
        args["attributes"] = {"suite.agent_id": agent_id}

    return args


async def request_fnc(req: JobRequest) -> None:
    """Accept every job, under the agent identity Core asked for when it sent one."""
    args = accept_arguments(parse_job_metadata(req.job.metadata))
    logger.info(
        "accepting job %s as %s",
        req.id,
        args.get("identity", "the SDK default identity"),
    )
    await req.accept(**args)


def build_tool_surface(config: AgentConfig, room_name: str, *, space_id: str | None = None) -> list:
    """The live Suite MCP tool surface plus the local chat hand-off wrapper.

    Split out from `entrypoint` so tests can build the same list without a
    real `JobContext`/room. `room_name` pins the hand-off tool to THIS
    meeting's own chat space (task 01a0d4a0 stage 3); `space_id`, when given
    (parsed from the job metadata — task 01a0d4a0 stage 5), takes priority
    over deriving it from `room_name` — see
    `mcp_tools.build_meeting_chat_handoff_tool`.
    """
    toolset = mcp_tools.build_mcp_toolset(config.mcp)
    handoff = mcp_tools.build_meeting_chat_handoff_tool(toolset, room_name, space_id=space_id)
    return [toolset, handoff]


def build_room_options(human_identity: str | None) -> NotGivenOr[RoomOptions]:
    """Pin the `AgentSession`'s linked participant to the human, when known.

    Task 01a0d4a0 stage 5 item 2: without `participant_identity` set,
    `RoomIO` links to the first room participant that clears its
    `participant_kinds` filter — Dalton's dual-agent moon run hit exactly
    this race, where two agents dispatched within milliseconds of each
    other, and the second worker's session linked to the FIRST agent's own
    room participant instead of the human (`RoomIO linked to participant:
    agent:harness-general`). `human_identity` (parsed from the job metadata
    by `entrypoint`, sourced from `Platform.Meetings.invite_agent/3`'s
    inviting user) removes that race entirely by naming the exact
    participant to wait for. Falls back to `NOT_GIVEN` (the old
    first-participant behavior) when no human identity was resolvable —
    e.g. one agent inviting another with no single human to pin to, or a
    dispatch that predates this metadata key.
    """
    if not human_identity:
        return NOT_GIVEN

    return RoomOptions(participant_identity=human_identity)


async def entrypoint(ctx: JobContext) -> None:
    config = AgentConfig.from_env()
    await ctx.connect()

    job_metadata = parse_job_metadata(ctx.job.metadata)
    space_id = job_metadata.get("space_id")
    human_identity = job_metadata.get("human_identity")
    # Task 01a0f8f5 stage 1/2: the other agents present in this room at
    # dispatch time, so Burrow can name a real present agent in her
    # post_to_meeting_chat hand-off. `[]` default covers a dispatch that
    # predates this key, or one with malformed metadata (parse_job_metadata
    # already degrades that to `{}` above) -- either way, today's
    # generic-category-only behavior, never a crash.
    agent_roster = job_metadata.get("agent_roster", [])

    session: AgentSession = build_agent_session(config)
    tools = build_tool_surface(config, ctx.room.name, space_id=space_id)
    agent = MeetingVoiceAgent(config, tools=tools, space_id=space_id, agent_roster=agent_roster)

    # Task 01a0d4a0 stage 4 round 2: publish tool-call telemetry so an
    # external observer (the live latency harness) can see a tool call
    # actually happened, instead of the harness's `tool_call` field always
    # reading `False`. See `tool_telemetry.py`.
    tool_telemetry.attach_tool_call_telemetry(session, ctx.room)

    # Task 01a0e47c stage 2: gate the whole VAD/STT/LLM pipeline to the
    # hold-to-ask window Core's `AskFloor.claim/5`/`release/3` open and
    # close on this exact room's data channel. Attached BEFORE
    # `session.start()` so input starts detached -- nothing is listened to
    # before the first real "open". See `ask_floor_gate.py`.
    ask_floor_gate.attach_ask_floor_gate(session, ctx.room, config.ask_floor.grace_ms)

    room_options = build_room_options(human_identity)
    await session.start(agent=agent, room=ctx.room, room_options=room_options)


def build_worker_options(config: AgentConfig | None = None) -> WorkerOptions:
    config = config or AgentConfig.from_env()
    return WorkerOptions(
        entrypoint_fnc=entrypoint,
        request_fnc=request_fnc,
        agent_name=config.worker_agent_name,
    )


def main() -> None:
    cli.run_app(build_worker_options())


if __name__ == "__main__":
    main()
