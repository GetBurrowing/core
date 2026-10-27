"""The meeting voice agent's persona.

Stage 1 kept this deliberately minimal (no Core-side registration, no MCP
tool surface). Stage 3 wires the MCP tool surface built in
`meeting_voice_agent.mcp_tools` in as `tools=` — this is the one place the
persona's live Burrow tool surface (real `space_get_context`, `send_media`,
etc., plus the local `post_to_meeting_chat` hand-off wrapper) attaches to the
`AgentSession`'s LLM. `tools` defaults to `None`/empty so existing callers
(and stage-1's tests) that construct `MeetingVoiceAgent(config)` with no
tools keep working unchanged.

Stage 5 (task 01a0d4a0 item 3) adds `space_id`: a live test run found
the model taking three attempts and 9.1s to call `space_get_context`
successfully because nothing ever told it its own space_id — every
space-scoped tool requires that parameter and the model had to discover it
some other way first. `agent.py`'s `entrypoint` now parses it out of the
LiveKit job's own metadata and passes it here so it can be stated directly
in the system instructions.

Task 01a0f8f5 stage 2 adds `agent_roster`: `Platform.Meetings.agent_roster_for_room/2`
(stage 1, Elixir) fetches the OTHER agents actually present in the room once
at dispatch time and stamps the result into the same job-metadata blob
`space_id`/`human_identity` already ride in — see `agent.py`'s `entrypoint`.
Each entry is `{"name": ..., "slug": ..., "capability": ...}` (`capability`
may be `None`). This lets Burrow's `post_to_meeting_chat` hand-off name a
real, present agent by name instead of only the generic-category phrasing
above, when one is an obvious match.

Task 01a1557a-eab7 (Voice tab) adds `voice_context`: in a 1:1 voice session
(`"mode": "voice_1to1"`) the person may pick ONE Burrow space the
conversation is about, or none. It arrives in the job metadata as
`{"kind": "space", "id", "name"}` (or null), and later changes arrive on the
`mva.context` data topic; both go through `build_instructions` so the two
paths cannot drift.
"""

from __future__ import annotations

import asyncio
import json
import logging

from livekit.agents import Agent, FlushSentinel, StopResponse, llm

from meeting_voice_agent.config import AgentConfig
from meeting_voice_agent.routing import RoutedAnswer, VoiceRouter, routed_clauses


def _instructions_with_space_context(base_instructions: str, space_id: str | None) -> str:
    if not space_id:
        return base_instructions

    return (
        f"{base_instructions} This meeting's Burrow space_id is {space_id} -- "
        "pass this exact value whenever a tool parameter asks for a space_id "
        "(for example space_get_context or post_to_meeting_chat's underlying "
        "hand-off). Never guess it, search for it, or ask the room for it."
    )


def _join_with_and(items: list[str]) -> str:
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return f"{items[0]} and {items[1]}"
    return ", ".join(items[:-1]) + f", and {items[-1]}"


def _instructions_with_roster_context(
    base_instructions: str, agent_roster: list[dict] | None
) -> str:
    """Append ONE bounded sentence naming the other agents present in this
    room, when there are any -- never per-turn, only once at construction
    (see `MeetingVoiceAgent.__init__`).

    `agent_roster` is the JSON-decoded `"agent_roster"` job-metadata key
    (see module docstring): a list of `{"name", "slug", "capability"}`
    maps, `capability` possibly `None`. Already capped to a small N
    (8, as of `Platform.Meetings.agent_roster_for_room/2`) on the Elixir
    side, so no further truncation happens here -- a second, independent
    cap here would just be a second copy of that number that can drift
    from the source of truth.

    Defensive like `agent.py`'s `parse_job_metadata`: never raises on a
    malformed payload. A non-list, a non-dict entry, or an entry missing
    `name` is skipped rather than crashing instruction-building. Never
    invents a capability beyond what the payload states -- an entry with
    no `capability` is named with no parenthetical, not a guessed one.

    Empty/missing roster returns `base_instructions` byte-for-byte
    unchanged -- the common small-meeting case gets no "nobody else is
    here" sentence; that would be pure prompt bloat.
    """
    if not agent_roster:
        return base_instructions

    named = []
    for entry in agent_roster:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if not name:
            continue
        capability = entry.get("capability")
        named.append(f"{name} ({capability})" if capability else name)

    if not named:
        return base_instructions

    return (
        f"{base_instructions} Agents currently present in this meeting include "
        f"{_join_with_and(named)} -- when a delegation request is an obvious "
        "match for one of them, name that specific agent directly in your "
        "post_to_meeting_chat hand-off instead of a generic category; only "
        "fall back to a generic category when none of these present agents "
        "is a good fit."
    )


def _instructions_with_voice_context(base_instructions: str, voice_context: dict | None) -> str:
    """Append one sentence naming the space the person is asking about.

    Only a `{"kind": "space", "id": <non-empty str>}` context adds anything;
    `None`, `{"kind": "none"}`, or a malformed payload returns
    `base_instructions` byte-for-byte unchanged. A missing `name` falls back
    to the id rather than inventing one.
    """
    if not isinstance(voice_context, dict) or voice_context.get("kind") != "space":
        return base_instructions

    space_id = voice_context.get("id")
    if not isinstance(space_id, str) or not space_id:
        return base_instructions

    name = voice_context.get("name")
    if not isinstance(name, str) or not name:
        name = space_id

    return (
        f"{base_instructions} The person is asking about {name} (space_id {space_id}) -- "
        "use that space_id with space-scoped tools when the question is about it."
    )


def build_instructions(
    config: AgentConfig,
    *,
    space_id: str | None = None,
    agent_roster: list[dict] | None = None,
    voice_context: dict | None = None,
) -> str:
    """The ONE instruction builder: construction and every `mva.context`
    update call this, so a rebuilt prompt matches a fresh one exactly."""
    instructions = _instructions_with_space_context(config.instructions, space_id)
    instructions = _instructions_with_roster_context(instructions, agent_roster)
    return _instructions_with_voice_context(instructions, voice_context)


logger = logging.getLogger("meeting_voice_agent")

#: Data-channel topic Core's `Platform.Meetings.VoiceSession.set_context/2`
#: sends on. Mirrors `ask_floor_gate.ASK_FLOOR_TOPIC`'s naming.
VOICE_CONTEXT_TOPIC = "mva.context"

_NOT_A_CONTEXT_PACKET = object()


def parse_voice_context_packet(topic: str | None, data: bytes):
    """Pure: the voice context one data packet carries.

    Returns the context dict for `kind == "space"`, `None` for
    `kind == "none"` (context cleared), and `_NOT_A_CONTEXT_PACKET` for
    anything else (another topic, bad JSON, unknown kind). Never raises.
    """
    if topic != VOICE_CONTEXT_TOPIC:
        return _NOT_A_CONTEXT_PACKET
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return _NOT_A_CONTEXT_PACKET
    if not isinstance(payload, dict):
        return _NOT_A_CONTEXT_PACKET
    kind = payload.get("kind")
    if kind == "none":
        return None
    if kind == "space":
        return payload
    return _NOT_A_CONTEXT_PACKET


class MeetingVoiceAgent(Agent):
    def __init__(
        self,
        config: AgentConfig,
        *,
        tools: list[llm.Tool | llm.Toolset] | None = None,
        space_id: str | None = None,
        agent_roster: list[dict] | None = None,
        voice_context: dict | None = None,
        drop_empty_turns: bool = False,
        router: VoiceRouter | None = None,
    ) -> None:
        self._config = config
        self._router = router
        self.routed_answers: list[RoutedAnswer] = []
        self._drop_empty_turns = drop_empty_turns
        self._space_id = space_id
        self._agent_roster = agent_roster
        self.voice_context = voice_context
        instructions = build_instructions(
            config, space_id=space_id, agent_roster=agent_roster, voice_context=voice_context
        )
        super().__init__(instructions=instructions, tools=tools or [])

    async def on_user_turn_completed(
        self, turn_ctx: llm.ChatContext, new_message: llm.ChatMessage
    ) -> None:
        """Drop an empty committed turn when `drop_empty_turns` is set.

        Task 01a174e2: a Voice-tab 1:1 session runs with manual turn
        detection, and when the release's `commit_user_turn` hits its bound
        with no transcript, the SDK still commits the (empty) turn and, in
        manual mode, would generate a reply to nothing. `StopResponse` is the
        SDK's way to ignore a turn. Off by default: with automatic turn
        detection (meeting mode) an empty transcript never ends a turn.
        """
        if self._drop_empty_turns and not (new_message.text_content or "").strip():
            logger.info("voice turn: committed turn has no transcript, no reply")
            raise StopResponse()

    async def llm_node(self, chat_ctx, tools, model_settings):
        """Route the turn (task 01a17b10 stage 4).

        With no router, or a class routed `local`, this is the SDK default:
        the mouth model answers. A class routed `burrow` speaks the ack at
        once, then Burrow's streamed answer clause by clause; a
        `FlushSentinel` after each one makes TTS start on it without waiting
        for the rest. Barge-in cancels this generator, which closes the
        answer stream and stops polling Core.
        """
        question = _last_user_text(chat_ctx)
        variant = "local"
        turn_class = None
        if self._router is not None and question:
            classification = await self._router.classify(question)
            turn_class = classification.turn_class
            variant = self._router.variant_for(turn_class)

        if variant != "burrow":
            async for chunk in Agent.default.llm_node(self, chat_ctx, tools, model_settings):
                yield chunk
            return

        routing = self._router.config
        record = RoutedAnswer(question, turn_class, variant)
        self.routed_answers.append(record)
        yield routing.ack_text
        yield FlushSentinel()
        source = self._router.new_source()
        try:
            async for clause, _from_answer in routed_clauses(
                source,
                question,
                turn_class=turn_class,
                timeout_s=routing.answer_timeout_s,
                no_answer_text=routing.no_answer_text,
                record=record,
            ):
                yield clause + " "
                yield FlushSentinel()
        finally:
            self._router.report(record)

    def instructions_for_context(self, voice_context: dict | None) -> str:
        """The instructions this agent would have been built with under
        `voice_context`, via the same `build_instructions`."""
        return build_instructions(
            self._config,
            space_id=self._space_id,
            agent_roster=self._agent_roster,
            voice_context=voice_context,
        )

    async def apply_voice_context(self, voice_context: dict | None) -> None:
        self.voice_context = voice_context
        await self.update_instructions(self.instructions_for_context(voice_context))


def _last_user_text(chat_ctx) -> str:
    for item in reversed(getattr(chat_ctx, "items", [])):
        if getattr(item, "type", None) == "message" and getattr(item, "role", None) == "user":
            return (item.text_content or "").strip()
    return ""


def attach_voice_context_handler(agent: MeetingVoiceAgent, room) -> None:
    """Rebuild the agent's instructions on every `mva.context` packet."""

    async def _apply(voice_context: dict | None) -> None:
        try:
            await agent.apply_voice_context(voice_context)
            logger.info("voice context updated: %r", voice_context)
        except Exception:  # an inactive agent must not crash the room loop
            logger.exception("voice context update failed")

    def _on_data_received(packet) -> None:
        voice_context = parse_voice_context_packet(packet.topic, packet.data)
        if voice_context is _NOT_A_CONTEXT_PACKET:
            return
        asyncio.ensure_future(_apply(voice_context))

    room.on("data_received", _on_data_received)
