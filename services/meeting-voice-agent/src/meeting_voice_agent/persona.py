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
"""

from __future__ import annotations

from livekit.agents import Agent, llm

from meeting_voice_agent.config import AgentConfig


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


class MeetingVoiceAgent(Agent):
    def __init__(
        self,
        config: AgentConfig,
        *,
        tools: list[llm.Tool | llm.Toolset] | None = None,
        space_id: str | None = None,
        agent_roster: list[dict] | None = None,
    ) -> None:
        instructions = _instructions_with_space_context(config.instructions, space_id)
        instructions = _instructions_with_roster_context(instructions, agent_roster)
        super().__init__(instructions=instructions, tools=tools or [])
