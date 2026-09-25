"""Wires the agent to Core's real MCP tool surface (task 01a0d4a0 stage 3).

Two things live here:

1. `build_mcp_toolset` — a `livekit.plugins`-style factory (same shape as
   `backends.py`'s `build_*` functions) that returns an `MCPToolset` pointed
   at Core's `/mcp` endpoint (`PlatformWeb.MCPController`), authenticated as
   the "meeting-assistant" voice runtime stage 2 registered. Handed to
   `Agent(tools=[...])`, `livekit-agents` connects it, lists Core's real
   tools (scoped server-side by `Platform.Federation.ToolAuthorization`
   against that runtime's `allowed_bundles` — as of stage 5, `messaging` and
   `context_read` only), and lets the LLM call them mid-conversation. No
   client-side bundle/allowlist duplication: Core's `allowed_bundles` grant
   is the one enforcement point, exactly as
   `Platform.Federation.ToolAuthorization`'s moduledoc describes for every
   other caller of this surface.

2. `build_meeting_chat_handoff_tool` — the hand-off-to-text behavior. It does
   NOT add a new Core tool or a new HTTP path: it is a thin local wrapper
   that calls Core's existing `send_media` MCP tool (already in the
   `messaging` bundle stage 2 granted) with the `space_id` pinned to the
   *current* meeting's chat space. `space_id` is taken from the LiveKit
   job's own metadata when available (task 01a0d4a0 stage 5 -- see
   `agent.py`'s `entrypoint`, which parses `ctx.job.metadata` and passes the
   parsed `space_id` through here), falling back to deriving it from the
   room name via the same `"space-<uuid>"` convention
   `Platform.Meetings.room_name_for_space/1` already produces (see
   `apps/platform/lib/platform/meetings.ex`, `@app_room_name_regex`) only
   when the job carries no metadata (e.g. a manually-started worker in a
   dev/test room). That keeps the LLM from having to know or guess a
   space_id — it only ever supplies the text to post.
"""

from __future__ import annotations

import base64
import re
from typing import Any

from livekit.agents import llm as llm_types
from livekit.agents.llm import function_tool
from livekit.agents.llm.mcp import MCPServerHTTP, MCPToolset
from livekit.agents.llm.tool_context import ToolError, get_raw_function_info, is_raw_function_tool

from meeting_voice_agent.config import McpConfig

# Mirrors `Platform.Meetings.@app_room_name_regex` exactly: a LiveKit room
# backing a Suite chat space is always named "space-<uuid>". Do not diverge
# from that pattern — it is the one existing mechanism this stage reuses to
# find "which chat space is this meeting" without any new Core plumbing.
_SPACE_ROOM_NAME_RE = re.compile(
    r"^space-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"
)

SEND_MEDIA_TOOL_NAME = "send_media"


def space_id_from_room_name(room_name: str) -> str | None:
    """Extract the chat `space_id` a LiveKit room backs, or `None`.

    Returns `None` for any room name that doesn't match Core's
    `"space-<uuid>"` convention (e.g. a room created some other way) rather
    than raising — callers decide whether that's fatal.
    """
    match = _SPACE_ROOM_NAME_RE.match(room_name)
    return match.group(1) if match else None


def build_mcp_server(config: McpConfig) -> MCPServerHTTP:
    """Core's `/mcp` endpoint, authenticated as the meeting-assistant runtime.

    `MCPServerHTTP` auto-detects streamable-HTTP transport from the `/mcp`
    URL suffix (see `livekit.agents.llm.mcp.MCPServerHTTP._should_use_streamable_http`),
    which matches `PlatformWeb.MCPController`'s `POST/GET /mcp` routes exactly
    — no explicit `transport_type` needed.
    """
    return MCPServerHTTP(
        url=config.base_url,
        headers={"Authorization": f"Bearer {config.auth_token}"},
        client_session_timeout_seconds=config.client_session_timeout_seconds,
    )


def build_mcp_toolset(config: McpConfig, *, mcp_server: MCPServerHTTP | None = None) -> MCPToolset:
    """The full Suite tool surface this runtime is allowed to see, as a livekit Toolset.

    `mcp_server` can be injected (tests do this with a fake) instead of built
    from `config`.
    """
    server = mcp_server if mcp_server is not None else build_mcp_server(config)
    return MCPToolset(id="suite", mcp_server=server)


def find_raw_tool(toolset: MCPToolset, name: str):
    """Find an already-`setup()`-connected toolset's raw MCP tool by name, or `None`.

    Public (not just an internal helper for `build_meeting_chat_handoff_tool`)
    because live integration tests need the same lookup to call other real
    Suite tools directly — see `tests/live/test_mcp_live.py`.
    """
    for tool in toolset.tools:
        if is_raw_function_tool(tool) and get_raw_function_info(tool).name == name:
            return tool
    return None


def build_meeting_chat_handoff_tool(
    toolset: MCPToolset, room_name: str, *, space_id: str | None = None
) -> llm_types.FunctionTool:
    """A `post_to_meeting_chat` tool the LLM can call for a long/out-of-scope answer.

    Per VOICE.md (stage 2): "for anything long, multi-part, or better read
    than heard ... give a short spoken acknowledgement ... and post the real
    answer as a text message in the meeting's chat space instead of speaking
    it at length." This tool IS that chat-space text path — it forwards
    straight into Core's existing `send_media` MCP tool (from the
    `messaging` bundle) with `space_id` pinned to this meeting's own chat
    space, so the model only ever has to supply the content to post.

    `space_id`, when given, is the value already parsed out of the LiveKit
    job's own metadata by `agent.py`'s `entrypoint` (task 01a0d4a0 stage 5
    item 3) — the authoritative source, since it is exactly what
    `Platform.Meetings.dispatch_meeting_join/3` stamped when the invite was
    dispatched. When omitted (e.g. a worker started by hand against a room
    with no job metadata, as in tests and the dev harness), this falls back
    to deriving it from `room_name` via `space_id_from_room_name/1`.

    ## Cross-host transport — no local file path (task 01a0d4a0 stage 5)

    `send_media`'s own Core-side implementation
    (`Platform.Federation.ToolSurface.execute("send_media", ...)` ->
    `normalize_send_media_attachments/1`) hard-refuses with "no file path
    provided" when neither `file_paths`/`file_path` NOR `file_base64` is
    set, even though `content` is independently accepted as the posted
    message's text — this tool has no content-only mode. Round 3 of
    Dalton's live moon run confirmed writing a LOCAL temp file and passing
    its path (the previous approach here) fails with `:enoent` in real
    deployment: this worker and Core run in different containers on
    different hosts, so a path this process can read means nothing to
    Core's process. Core's `send_media` tool now also accepts
    `file_base64` — bytes travel over the wire in the tool call itself, so
    there is no path, local or otherwise, for either side to resolve. This
    wrapper base64-encodes `content` and sends it that way, while ALSO
    passing `content` through unchanged so the text still posts directly
    into the space's message body (readable without opening the
    attachment).

    Raises `ToolError` (surfaced back to the LLM/session, not a crash) if
    `send_media` isn't in the runtime's granted toolset, or if neither an
    explicit `space_id` nor `room_name` matching Core's `"space-<uuid>"`
    room-naming convention is available — both are configuration problems
    the agent should be able to report on, not silent failures.
    """
    resolved_space_id = space_id or space_id_from_room_name(room_name)

    @function_tool(
        name="post_to_meeting_chat",
        description=(
            "Post a text message into this meeting's own chat space, for a long, "
            "multi-part, or better-read-than-heard answer. Use this instead of "
            "speaking a long answer aloud — give a brief spoken acknowledgement "
            "and call this tool with the real answer."
        ),
    )
    async def post_to_meeting_chat(content: str) -> Any:
        if resolved_space_id is None:
            raise ToolError(
                "cannot hand off to chat: no space_id was provided in the job "
                f"metadata, and room name {room_name!r} does not match Core's "
                "'space-<uuid>' room-naming convention either, so this meeting's "
                "chat space id could not be determined."
            )

        send_media = find_raw_tool(toolset, SEND_MEDIA_TOOL_NAME)
        if send_media is None:
            raise ToolError(
                f"cannot hand off to chat: '{SEND_MEDIA_TOOL_NAME}' is not in this "
                "runtime's granted MCP tool surface (check the 'messaging' bundle "
                "in the seed's allowed_bundles grant)."
            )

        encoded = base64.b64encode(content.encode("utf-8")).decode("ascii")

        return await send_media(
            {
                "space_id": resolved_space_id,
                "content": content,
                "file_base64": encoded,
                "filename": "response.md",
            }
        )

    return post_to_meeting_chat
