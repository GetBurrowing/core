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

from meeting_voice_agent import ask_floor_gate, mcp_tools, routing, tool_telemetry
from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.persona import MeetingVoiceAgent, attach_voice_context_handler
from meeting_voice_agent.session import VOICE_1TO1_MODE, build_agent_session

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


def parse_voice_context(metadata: dict) -> dict | None:
    """The job metadata's `voice_context`, or `None` when absent/malformed."""
    voice_context = metadata.get("voice_context")
    return voice_context if isinstance(voice_context, dict) else None


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

    The agent is never derived from `config.worker_agent_name`: several
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
    """The live Burrow MCP tool surface plus the local chat hand-off wrapper.

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


def build_voice_router(
    config: AgentConfig,
    toolset,
    *,
    space_id: str | None,
    meeting_id: str | None = None,
    on_answer=None,
) -> routing.VoiceRouter | None:
    """The turn router, or `None` when every class is routed `local`.

    Task 01a17b10 stage 4: the classifier is the mouth model on `MVA_LLM_*`
    (falling back to rules if that host is down); a `burrow` class is asked
    through Core's `voice_ask_agent` on the same MCP toolset.
    """
    if "burrow" not in config.routing.routes.values():
        return None
    call_tool = routing.mcp_tool_caller(toolset)
    classifier = routing.LocalClassifier.from_llm_config(
        config.llm, timeout_s=config.routing.classifier_timeout_s
    )

    def source_factory():
        return routing.BurrowAnswerSource(
            call_tool,
            space_id=space_id,
            agent_id=config.routing.burrow_agent_id,
            meeting_id=meeting_id,
            poll_wait_ms=config.routing.poll_wait_ms,
        )

    return routing.VoiceRouter(config.routing, classifier, source_factory, on_answer=on_answer)


def publish_routing_provenance(room):
    """`on_answer` callback: publish each routed answer's provenance in-room."""
    import asyncio

    def _on_answer(record: routing.RoutedAnswer) -> None:
        payload = json.dumps(routing.provenance_payload(record)).encode("utf-8")
        asyncio.ensure_future(
            room.local_participant.publish_data(payload, reliable=True, topic=routing.ROUTING_TOPIC)
        )

    return _on_answer


def build_room_options(human_identity: str | None, mode: str | None) -> NotGivenOr[RoomOptions]:
    """Pin the `AgentSession`'s linked participant to the human, when known.

    Task 01a0d4a0 stage 5 item 2: without `participant_identity` set,
    `RoomIO` links to the first room participant that clears its
    `participant_kinds` filter — a live test run hit exactly
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

    Task 01a174e2 stage 2: a Voice-tab 1:1 session (`mode == "voice_1to1"`)
    also sets `close_on_disconnect=False`. The SDK default (True) makes
    `RoomIO` close the whole `AgentSession` the moment the linked participant
    disconnects with CLIENT_INITIATED; the Voice tab drops and rejoins the
    room routinely (it reconnects, and Core hands back the cached session),
    so the default killed the session the client was about to rejoin and
    Burrow never replied. With it off, `RoomIO` unlinks and re-links the
    returning participant; the job still ends when the room goes away.
    These options are returned even without a human identity. Every other
    mode gets exactly the options it got before.
    """
    if mode == VOICE_1TO1_MODE:
        if human_identity:
            return RoomOptions(close_on_disconnect=False, participant_identity=human_identity)
        return RoomOptions(close_on_disconnect=False)

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
    # Task 01a1557a-eab7: a Voice-tab session names its mode and the space
    # (or none) the person is asking about; later changes arrive on the
    # `mva.context` data topic, listened to only in that mode.
    mode = job_metadata.get("mode")
    voice_context = parse_voice_context(job_metadata)

    session: AgentSession = build_agent_session(config, mode)
    tools = build_tool_surface(config, ctx.room.name, space_id=space_id)
    router = build_voice_router(
        config,
        tools[0],
        space_id=space_id or mcp_tools.space_id_from_room_name(ctx.room.name),
        meeting_id=job_metadata.get("meeting_id"),
        on_answer=publish_routing_provenance(ctx.room),
    )
    agent = MeetingVoiceAgent(
        config,
        tools=tools,
        space_id=space_id,
        agent_roster=agent_roster,
        voice_context=voice_context,
        drop_empty_turns=mode == VOICE_1TO1_MODE,
        router=router,
    )

    if mode == VOICE_1TO1_MODE:
        attach_voice_context_handler(agent, ctx.room)

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
    #
    # Task 01a174e2: a Voice-tab 1:1 session is push-to-talk with manual
    # turn detection, so its release commits the turn instead of waiting
    # out the grace window. Meeting mode is unchanged.
    if mode == VOICE_1TO1_MODE:
        ask_floor_gate.attach_ask_floor_gate(
            session,
            ctx.room,
            config.ask_floor.grace_ms,
            commit_on_close=True,
            commit_timeout_s=config.ask_floor.voice_commit_timeout_s,
        )
    else:
        ask_floor_gate.attach_ask_floor_gate(session, ctx.room, config.ask_floor.grace_ms)

    room_options = build_room_options(human_identity, mode)
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
