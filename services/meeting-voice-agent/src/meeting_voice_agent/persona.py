"""The meeting voice agent's persona.

Stage 1 kept this deliberately minimal (no Core-side registration, no MCP
tool surface). Stage 3 wires the MCP tool surface built in
`meeting_voice_agent.mcp_tools` in as `tools=` — this is the one place the
persona's live Suite tool surface (real `space_get_context`, `send_media`,
etc., plus the local `post_to_meeting_chat` hand-off wrapper) attaches to the
`AgentSession`'s LLM. `tools` defaults to `None`/empty so existing callers
(and stage-1's tests) that construct `MeetingVoiceAgent(config)` with no
tools keep working unchanged.

Stage 5 (task 01a0d4a0 item 3) adds `space_id`: Dalton's live moon run found
the model taking three attempts and 9.1s to call `space_get_context`
successfully because nothing ever told it its own space_id — every
space-scoped tool requires that parameter and the model had to discover it
some other way first. `agent.py`'s `entrypoint` now parses it out of the
LiveKit job's own metadata and passes it here so it can be stated directly
in the system instructions.
"""

from __future__ import annotations

from livekit.agents import Agent, llm

from meeting_voice_agent.config import AgentConfig


def _instructions_with_space_context(base_instructions: str, space_id: str | None) -> str:
    if not space_id:
        return base_instructions

    return (
        f"{base_instructions} This meeting's Suite space_id is {space_id} -- "
        "pass this exact value whenever a tool parameter asks for a space_id "
        "(for example space_get_context or post_to_meeting_chat's underlying "
        "hand-off). Never guess it, search for it, or ask the room for it."
    )


class MeetingVoiceAgent(Agent):
    def __init__(
        self,
        config: AgentConfig,
        *,
        tools: list[llm.Tool | llm.Toolset] | None = None,
        space_id: str | None = None,
    ) -> None:
        instructions = _instructions_with_space_context(config.instructions, space_id)
        super().__init__(instructions=instructions, tools=tools or [])
