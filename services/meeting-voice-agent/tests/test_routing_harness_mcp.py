"""The harness's MCP client against a real in-process mcp 2.x server, plus
the provenance, TTS-overlap and spacing seams of `run_ttfsw`."""

from __future__ import annotations

import asyncio
import json
import socket
import threading
import time

import pytest

from meeting_voice_agent import routing
from meeting_voice_agent import routing_harness as h
from meeting_voice_agent.config import DEFAULT_ROUTING, LlmConfig, RoutingConfig


def _serve(seen_auth: list[str]):
    import uvicorn
    from mcp.server.mcpserver import MCPServer

    server = MCPServer("fake-core")

    @server.tool()
    def voice_ask_agent(space_id: str, question: str) -> str:
        return json.dumps({"ask_id": "a1", "agent_id": "target", "message_id": "m-q"})

    app = server.streamable_http_app()

    async def with_auth_capture(scope, receive, send):
        if scope["type"] == "http":
            for k, v in scope["headers"]:
                if k == b"authorization":
                    seen_auth.append(v.decode())
        await app(scope, receive, send)

    # Lifespan must reach the wrapped app, so forward it unchanged.
    async def asgi(scope, receive, send):
        if scope["type"] == "lifespan":
            await app(scope, receive, send)
        else:
            await with_auth_capture(scope, receive, send)

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    config = uvicorn.Config(asgi, host="127.0.0.1", port=port, log_level="warning")
    uv = uvicorn.Server(config)
    thread = threading.Thread(target=uv.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not uv.started and time.monotonic() < deadline:
        time.sleep(0.02)
    assert uv.started
    return uv, thread, port


def test_mcp_call_tool_factory_drives_an_mcp2_server():
    seen: list[str] = []
    uv, thread, port = _serve(seen)
    try:

        async def go():
            connect = await h.mcp_call_tool_factory(f"http://127.0.0.1:{port}/mcp", "tok")
            async with connect as call_tool:
                return await call_tool("voice_ask_agent", {"space_id": "s", "question": "q"})

        result = asyncio.run(go())
    finally:
        uv.should_exit = True
        thread.join(timeout=10)
    assert result == {"ask_id": "a1", "agent_id": "target", "message_id": "m-q"}
    assert "Bearer tok" in seen


def test_streamable_http_client_contract_is_the_mcp2_one():
    import inspect

    from mcp.client import streamable_http

    assert not hasattr(streamable_http, "streamablehttp_client")
    assert "http_client" in inspect.signature(streamable_http.streamable_http_client).parameters
    assert "headers" not in inspect.signature(streamable_http.streamable_http_client).parameters


# ── run_ttfsw seams ────────────────────────────────────────────────────


class _Source:
    variant = "burrow"
    question_message_id = "m-q"
    _space_id = "sp"

    def __init__(self, stream_s=0.1):
        self.answered_by = "target"
        self._stream_s = stream_s

    async def stream(self, question):
        yield "Paris is the capital of France. "
        await asyncio.sleep(self._stream_s)
        yield "Paris is the capital of France. It is large."


class _Tts:
    name = "fake"

    async def first_audio_ms(self, text):
        await asyncio.sleep(0.01)
        return 10.0


def _call_tool_factory(calls):
    async def call_tool(name, args):
        calls.append(name)
        if name == "space_list_agents":
            return {
                "agents": [
                    {"agent_id": "target", "participant_id": "p-target"},
                    {"agent_id": "real-author", "participant_id": "p-real"},
                ]
            }
        return {
            "messages": [
                {"id": "m-reply", "participant_id": "p-real"},
                {"id": "m-q", "participant_id": "p-caller"},
                {"id": "m-old", "participant_id": "p-target"},
            ]
        }

    return call_tool


class _Cls:
    turn_class = "substantive"
    latency_ms = 1.0


class _FakeClassifier:
    async def classify(self, text):
        return _Cls()


@pytest.fixture
def patched(monkeypatch):
    monkeypatch.setattr(
        routing.LocalClassifier,
        "from_llm_config",
        classmethod(lambda cls, *a, **k: _FakeClassifier()),
    )


def _cfg():
    routes = dict(DEFAULT_ROUTING)
    routes["substantive"] = "burrow"
    llm = LlmConfig(base_url="http://x", model="m", fallback_model="m")
    return llm, RoutingConfig(routes=routes, answer_timeout_s=5, classifier_timeout_s=1)


def _only(n):
    return [u for u in h.scripted_set() if u.expected_class == "substantive"][:n]


def test_run_ttfsw_records_reply_author_and_tts_overlap(patched):
    llm, rc = _cfg()
    calls: list[str] = []
    rows = asyncio.run(
        h.run_ttfsw(
            llm,
            rc,
            _only(1),
            _Tts(),
            lambda: _Source(),
            call_tool=_call_tool_factory(calls),
            min_ask_spacing_s=0,
        )
    )
    row = rows[0]
    assert row.ask_target_agent_id == "target"
    assert row.reply_author_agent_id == "real-author"
    assert row.answered_by == "real-author"
    assert row.tts_started_before_stream_end is True
    assert row.tts_start_ms < row.stream_end_ms
    assert h.summarize_ttfsw("x", rows).extra["tts_before_stream_end"] == 1


def test_run_ttfsw_spaces_burrow_asks(patched):
    llm, rc = _cfg()
    slept: list[float] = []

    async def fake_sleep(s):
        slept.append(s)

    asyncio.run(
        h.run_ttfsw(
            llm, rc, _only(2), _Tts(), lambda: _Source(0.0), min_ask_spacing_s=30, sleep=fake_sleep
        )
    )
    assert len(slept) == 1 and 29 < slept[0] <= 30
