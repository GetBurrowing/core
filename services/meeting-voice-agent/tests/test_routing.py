"""Voice brain routing (task 01a17b10 stage 4): classification, MVA_ROUTING,
streaming to TTS, barge-in, timeout and provenance."""

from __future__ import annotations

import asyncio
import time

import pytest
from livekit.agents import Agent, FlushSentinel, llm

from meeting_voice_agent import routing, routing_harness
from meeting_voice_agent.config import (
    DEFAULT_ROUTING,
    AgentConfig,
    ConfigError,
    LlmConfig,
    RoutingConfig,
    parse_routing,
)
from meeting_voice_agent.persona import MeetingVoiceAgent

BURROW_ID = "0b0b0b0b-0000-7000-8000-00000000b0b0"
VOICE_PERSONA_ID = "0a0a0a0a-0000-7000-8000-00000000a0a0"


def run(coro):
    return asyncio.run(coro)


# ── MVA_ROUTING as data ─────────────────────────────────────────────────


def test_default_routing_keeps_acks_and_turn_taking_local_and_sends_substantive_to_burrow():
    assert parse_routing(None) == {
        "ack": "local",
        "turn_taking": "local",
        "substantive": "burrow",
    }
    assert RoutingConfig.from_env().routes == DEFAULT_ROUTING


def test_every_class_can_be_switched(monkeypatch):
    monkeypatch.setenv("MVA_ROUTING", "substantive=local, ack=burrow,turn_taking=burrow")
    assert RoutingConfig.from_env().routes == {
        "ack": "burrow",
        "turn_taking": "burrow",
        "substantive": "local",
    }
    assert parse_routing('{"substantive": "local"}')["substantive"] == "local"


@pytest.mark.parametrize(
    "raw", ["substantive=wave", "chitchat=local", "substantive", '["local"]', "{bad json"]
)
def test_bad_routing_is_refused_not_silently_routed(raw):
    with pytest.raises(ConfigError):
        parse_routing(raw)


def test_agent_config_carries_routing(monkeypatch):
    monkeypatch.setenv("MVA_ROUTING", "substantive=local")
    assert AgentConfig.from_env().routing.variant_for("substantive") == "local"


# ── classification fixture ─────────────────────────────────────────────


def scripted_fixture():
    return routing_harness.scripted_set()


def test_scripted_set_is_big_enough():
    substantive = [u for u in scripted_fixture() if u.expected_class == "substantive"]
    acks = [u for u in scripted_fixture() if u.expected_class != "substantive"]
    assert len(substantive) >= 10
    assert all(u.answer_keys for u in substantive)
    assert len(acks) >= 3


def test_classifier_fixture_routes_substantive_to_burrow_and_acks_to_local():
    """The heuristic is what the classifier falls back to, so it must route
    the scripted set correctly on its own."""
    config = RoutingConfig()
    for utterance in scripted_fixture():
        turn_class = routing.classify_heuristic(utterance.text)
        assert turn_class == utterance.expected_class, utterance.text
        expected = "burrow" if utterance.expected_class == "substantive" else "local"
        assert config.variant_for(turn_class) == expected, utterance.text


def test_model_label_is_used_when_the_mouth_answers():
    async def complete(system, user):
        assert "ack, turn_taking, or substantive" in system
        return " Substantive."

    result = run(routing.LocalClassifier(complete).classify("thanks"))
    assert (result.turn_class, result.source) == ("substantive", "model")


def test_unreachable_mouth_falls_back_to_the_heuristic():
    async def complete(system, user):
        raise ConnectionError("connection refused")

    result = run(routing.LocalClassifier(complete).classify("What year did the Berlin Wall fall?"))
    assert (result.turn_class, result.source) == ("substantive", "heuristic")


def test_slow_mouth_falls_back_within_the_timeout():
    async def complete(system, user):
        await asyncio.sleep(5)
        return "ack"

    started = time.monotonic()
    result = run(routing.LocalClassifier(complete, timeout_s=0.05).classify("thanks a lot"))
    assert result.source == "heuristic"
    assert result.turn_class == "ack"
    assert time.monotonic() - started < 1


@pytest.mark.parametrize(
    ("raw", "label"),
    [("ack", "ack"), ("turn-taking", "turn_taking"), ("Turn taking", "turn_taking"), ("?", None)],
)
def test_parse_label(raw, label):
    assert routing.parse_label(raw) == label


# ── clause chunking ────────────────────────────────────────────────────


def test_chunker_emits_clauses_as_cumulative_text_grows():
    chunker = routing.ClauseChunker(min_clause_chars=10)
    assert chunker.feed("The wall fell") == []
    assert chunker.feed("The wall fell in 1989. It") == ["The wall fell in 1989."]
    assert chunker.feed("The wall fell in 1989. It opened, after weeks of protest, ") == [
        "It opened,",
        "after weeks of protest,",
    ]
    assert chunker.flush() is None
    assert chunker.feed("The wall fell in 1989. It opened, after weeks of protest, then") == []
    assert chunker.flush() == "then"


# ── fakes ──────────────────────────────────────────────────────────────


class FakeCore:
    """Core's voice_ask_agent / voice_ask_poll, replaying scripted chunks."""

    def __init__(self, chunks, *, delay=0.02, answered_by=BURROW_ID, never_answer=False):
        self.chunks = chunks
        self.delay = delay
        self.answered_by = answered_by
        self.never_answer = never_answer
        self.calls = []
        self.finished = False

    async def __call__(self, name, args):
        self.calls.append((name, dict(args)))
        if name == routing.ASK_TOOL_NAME:
            return {"ask_id": "ask-1", "agent_id": self.answered_by, "status": "pending"}
        assert name == routing.POLL_TOOL_NAME
        await asyncio.sleep(self.delay)
        if self.never_answer:
            return {"ask_id": "ask-1", "text": "", "done": False, "status": "pending"}
        index = sum(1 for n, _ in self.calls if n == routing.POLL_TOOL_NAME) - 1
        text = " ".join(self.chunks[: index + 1])
        done = index + 1 >= len(self.chunks)
        self.finished = done
        return {
            "ask_id": "ask-1",
            "text": text,
            "done": done,
            "status": "done" if done else "streaming",
            "answered_by": self.answered_by,
            "variant": "burrow",
        }

    @property
    def polls(self):
        return sum(1 for n, _ in self.calls if n == routing.POLL_TOOL_NAME)


def burrow_source(core):
    return routing.BurrowAnswerSource(core, space_id="space-1", poll_wait_ms=10)


CHUNKS = ["The Berlin Wall fell", "in 1989. Crowds crossed", "that night. It was", "a Thursday."]


def clauses(source, *, timeout_s=5.0, record=None):
    return routing.routed_clauses(
        source,
        "When did the Berlin Wall fall?",
        turn_class="substantive",
        timeout_s=timeout_s,
        no_answer_text="Sorry, I couldn't get an answer to that just now.",
        record=record,
    )


# ── streaming to TTS ───────────────────────────────────────────────────


def test_fake_stream_yields_tts_calls_before_it_completes():
    core = FakeCore(CHUNKS)
    tts_calls = []

    async def tts_say(text):
        tts_calls.append((text, core.finished))

    spoken = run(routing.speak_clauses(clauses(burrow_source(core)), tts_say))
    assert spoken[0] == "The Berlin Wall fell in 1989."
    assert tts_calls[0][1] is False, "first TTS call must happen while the stream is still open"
    assert core.finished
    assert " ".join(spoken) == " ".join(CHUNKS)


@pytest.mark.parametrize("during", ["poll", "tts"])
def test_barge_in_cancels_the_stream_and_tts(during):
    core = FakeCore(CHUNKS + ["more"] * 50, delay=0.02)
    tts_calls = []
    first_spoken = asyncio.Event()
    record = routing.RoutedAnswer("q", "substantive", "burrow")

    async def scenario():
        async def tts_say(text):
            tts_calls.append(text)
            first_spoken.set()
            if during == "tts":
                await asyncio.sleep(10)  # playback in progress

        source = clauses(burrow_source(core), record=record)
        task = asyncio.create_task(routing.speak_clauses(source, tts_say))
        await asyncio.wait_for(first_spoken.wait(), 2)
        if during == "poll":
            await asyncio.sleep(0.005)  # the next poll is in flight
        task.cancel()  # barge-in
        with pytest.raises(asyncio.CancelledError):
            await task
        polls_at_cancel = core.polls
        await asyncio.sleep(0.15)
        return polls_at_cancel

    polls_at_cancel = run(scenario())
    assert tts_calls == ["The Berlin Wall fell in 1989."]
    assert core.polls == polls_at_cancel, "no poll may follow a barge-in"
    assert not core.finished
    assert record.ask_id == "ask-1", "the stream's finally ran: it was closed, not abandoned"


def test_timeout_says_it_could_not_answer_and_invents_nothing():
    core = FakeCore([], never_answer=True)
    record = routing.RoutedAnswer("q", "substantive", "burrow")
    out = run(_collect(clauses(burrow_source(core), timeout_s=0.1, record=record)))
    assert out == [("Sorry, I couldn't get an answer to that just now.", False)]
    assert record.timed_out
    assert record.clauses == []


def test_core_error_says_it_could_not_answer():
    async def failing(name, args):
        raise RuntimeError("agent_not_in_space")

    source = routing.BurrowAnswerSource(failing, space_id="space-1")
    out = run(_collect(clauses(source)))
    assert out == [("Sorry, I couldn't get an answer to that just now.", False)]


async def _collect(gen):
    return [item async for item in gen]


# ── provenance ─────────────────────────────────────────────────────────


def test_provenance_records_burrows_agent_id_not_the_voice_personas():
    core = FakeCore(CHUNKS)
    record = routing.RoutedAnswer("q", "substantive", "burrow")
    run(_collect(clauses(burrow_source(core), record=record)))
    payload = routing.provenance_payload(record)
    assert payload["answered_by"] == BURROW_ID
    assert payload["answered_by"] != VOICE_PERSONA_ID
    assert payload["variant"] == "burrow"
    assert payload["ask_id"] == "ask-1"
    ask = core.calls[0]
    assert ask == (
        routing.ASK_TOOL_NAME,
        {"space_id": "space-1", "question": "When did the Berlin Wall fall?"},
    )


def test_decode_tool_result_unwraps_livekits_text_content():
    raw = '{"type": "text", "text": "{\\"ask_id\\": \\"a\\", \\"done\\": true}"}'
    assert routing.decode_tool_result(raw) == {"ask_id": "a", "done": True}


# ── the persona's llm_node ─────────────────────────────────────────────


def _agent(router):
    config = AgentConfig.from_env()
    return MeetingVoiceAgent(config, router=router)


def _ctx(text):
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="user", content=text)
    return ctx


def _router(core, *, routes=None, complete=None):
    config = RoutingConfig(routes=routes or dict(DEFAULT_ROUTING), answer_timeout_s=2)
    return routing.VoiceRouter(
        config, routing.LocalClassifier(complete), lambda: burrow_source(core)
    )


def test_llm_node_speaks_ack_then_burrows_answer_and_never_calls_the_mouth(monkeypatch):
    def mouth(*args, **kwargs):
        raise AssertionError("a routed answer must not call the local model")

    monkeypatch.setattr(Agent.default, "llm_node", mouth)
    core = FakeCore(CHUNKS)
    agent = _agent(_router(core))

    async def drive():
        return [c async for c in agent.llm_node(_ctx("When did the Berlin Wall fall?"), [], None)]

    out = run(drive())
    texts = [c for c in out if isinstance(c, str)]
    assert texts[0] == "One moment."
    assert isinstance(out[1], FlushSentinel)
    assert texts[1] == "The Berlin Wall fell in 1989. "
    assert agent.routed_answers[0].answered_by == BURROW_ID


def test_llm_node_keeps_acks_on_the_local_mouth(monkeypatch):
    calls = []

    async def mouth(agent, chat_ctx, tools, model_settings):
        calls.append(chat_ctx)
        yield "You're welcome."

    monkeypatch.setattr(Agent.default, "llm_node", mouth)
    core = FakeCore(CHUNKS)
    agent = _agent(_router(core))

    async def drive():
        return [c async for c in agent.llm_node(_ctx("thanks"), [], None)]

    assert run(drive()) == ["You're welcome."]
    assert len(calls) == 1
    assert core.calls == [], "an ack must not reach Burrow"


def test_with_the_old_llm_host_unreachable_voice_still_answers_through_burrow(monkeypatch):
    """Amendment 2026-10-27: the mouth no longer depends on wave. Point the
    LLM endpoint at a closed local port; the classifier falls back to rules
    and the answer still comes from Burrow."""
    monkeypatch.setenv("MVA_LLM_BASE_URL", "http://127.0.0.1:9/v1")

    def mouth(*args, **kwargs):
        raise AssertionError("the unreachable mouth must not be needed for a routed answer")

    monkeypatch.setattr(Agent.default, "llm_node", mouth)
    config = AgentConfig.from_env()
    core = FakeCore(CHUNKS)
    classifier = routing.LocalClassifier.from_llm_config(
        LlmConfig.from_env(), timeout_s=config.routing.classifier_timeout_s
    )
    router = routing.VoiceRouter(config.routing, classifier, lambda: burrow_source(core))
    agent = MeetingVoiceAgent(config, router=router)

    async def drive():
        return [c async for c in agent.llm_node(_ctx("When did the Berlin Wall fall?"), [], None)]

    texts = [c for c in run(drive()) if isinstance(c, str)]
    assert texts[1:] == [
        "The Berlin Wall fell in 1989. ",
        "Crowds crossed that night. ",
        "It was a Thursday. ",
    ]
    assert agent.routed_answers[0].answered_by == BURROW_ID


def test_no_router_is_the_sdk_default(monkeypatch):
    async def mouth(agent, chat_ctx, tools, model_settings):
        yield "local"

    monkeypatch.setattr(Agent.default, "llm_node", mouth)
    agent = _agent(None)

    async def drive():
        return [c async for c in agent.llm_node(_ctx("When did the Berlin Wall fall?"), [], None)]

    assert run(drive()) == ["local"]


def test_build_voice_router_is_off_when_everything_is_local(monkeypatch):
    from meeting_voice_agent.agent import build_voice_router

    monkeypatch.setenv("MVA_ROUTING", "substantive=local")
    assert build_voice_router(AgentConfig.from_env(), object(), space_id="s") is None
    monkeypatch.delenv("MVA_ROUTING")
    assert build_voice_router(AgentConfig.from_env(), object(), space_id="s") is not None
