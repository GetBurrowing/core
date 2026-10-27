"""Voice brain routing (task 01a17b10 stage 4).

The local model is the mouth. It classifies every committed turn into one of
`config.ROUTING_CLASSES` and keeps acks, turn-taking and barge-in. A class that
`MVA_ROUTING` sends to `burrow` is answered by the install's Burrow agent: the
mouth speaks a short ack at once, the question goes to Core's `voice_ask_agent`
tool (posted in the meeting chat, dispatched to Burrow the ordinary way), and
Burrow's streamed cumulative text is spoken clause by clause as it arrives.

Everything here is transport-free so tests drive it with fakes:

- `classify_heuristic` / `LocalClassifier`: the turn class. The classifier asks
  the mouth model (any OpenAI-compatible endpoint, `MVA_LLM_*`) for one label
  and falls back to the heuristic when that endpoint fails or is slow, so an
  unreachable mouth host never blocks a routed answer.
- `ClauseChunker`: cumulative text in, newly complete clauses out.
- `BurrowAnswerSource`: `voice_ask_agent` then `voice_ask_poll` until done.
- `routed_clauses`: the timeout and no-invention rule, plus provenance.

Cancelling the consumer of `routed_clauses` (barge-in cancels the SDK's
`llm_node` task) closes the source generator, which stops polling.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

from meeting_voice_agent.config import ROUTING_CLASSES

logger = logging.getLogger("meeting_voice_agent.routing")

ASK_TOOL_NAME = "voice_ask_agent"
POLL_TOOL_NAME = "voice_ask_poll"

# ── classification ──────────────────────────────────────────────────────

_TURN_TAKING_PATTERNS = [
    r"\bcan you hear me\b",
    r"\bare you (still )?there\b",
    r"\bhold on\b",
    r"\bhang on\b",
    r"\bone (sec|second|moment)\b",
    r"\bgo ahead\b",
    r"\byour turn\b",
    r"\b(wait|stop)\b",
    r"\b(say|repeat) that again\b",
    r"\bsorry,? what\b",
    r"\bnever ?mind\b",
    r"\bkeep going\b",
    r"\bcarry on\b",
]
_ACK_WORDS = {
    "ok",
    "okay",
    "thanks",
    "thank",
    "you",
    "cheers",
    "great",
    "cool",
    "nice",
    "perfect",
    "got",
    "it",
    "sure",
    "yes",
    "yeah",
    "yep",
    "no",
    "nope",
    "alright",
    "right",
    "hi",
    "hello",
    "hey",
    "morning",
    "good",
    "awesome",
    "sounds",
    "makes",
    "sense",
    "understood",
    "mhm",
    "uh",
    "huh",
    "so",
    "much",
    "that's",
    "thats",
    "fine",
    "bye",
    "a",
    "lot",
    "lots",
}


def classify_heuristic(text: str) -> str:
    """A fast rule fallback: turn-taking phrases, short ack-only utterances,
    and everything else substantive. Used when the mouth model can't answer."""
    lowered = (text or "").strip().lower()
    if not lowered:
        return "turn_taking"
    words = re.findall(r"[a-z']+", lowered)
    if len(words) <= 7 and any(re.search(p, lowered) for p in _TURN_TAKING_PATTERNS):
        return "turn_taking"
    if words and len(words) <= 6 and all(w in _ACK_WORDS for w in words) and "?" not in lowered:
        return "ack"
    return "substantive"


CLASSIFIER_PROMPT = (
    "You sort one utterance spoken to a voice assistant in a meeting. Reply with "
    "exactly one word: ack, turn_taking, or substantive.\n"
    "ack: thanks, greetings, okay, got it, sounds good, any acknowledgement that "
    "needs no information.\n"
    "turn_taking: about the conversation itself: can you hear me, hold on, wait, "
    "go ahead, stop, say that again, are you there.\n"
    "substantive: any question or request that needs real information, a fact, "
    "a calculation, an explanation or an action."
)


def parse_label(raw: str | None) -> str | None:
    """The first routing class named in a model reply, or `None`."""
    if not raw:
        return None
    lowered = raw.strip().lower().replace("-", "_").replace(" ", "_")
    for label in ("turn_taking", "substantive", "ack"):
        if label in lowered:
            return label
    if "turn" in lowered:
        return "turn_taking"
    return None


@dataclass
class Classification:
    turn_class: str
    source: str  # "model" or "heuristic"
    latency_ms: float


class LocalClassifier:
    """Classify with the mouth model; fall back to `classify_heuristic`.

    `complete` is an async callable `(system, user) -> str` so the transport
    is injectable. `from_llm_config` builds it over the `openai` client the
    livekit openai plugin already depends on.
    """

    def __init__(
        self,
        complete: Callable[[str, str], Awaitable[str]] | None,
        *,
        timeout_s: float = 1.5,
    ) -> None:
        self._complete = complete
        self._timeout_s = timeout_s

    @classmethod
    def from_llm_config(cls, llm_config, *, timeout_s: float = 1.5) -> LocalClassifier:
        return cls(make_openai_complete(llm_config, max_tokens=4), timeout_s=timeout_s)

    async def classify(self, text: str) -> Classification:
        started = time.monotonic()
        if self._complete is not None:
            try:
                raw = await asyncio.wait_for(
                    self._complete(CLASSIFIER_PROMPT, text), timeout=self._timeout_s
                )
                label = parse_label(raw)
                if label in ROUTING_CLASSES:
                    return Classification(label, "model", (time.monotonic() - started) * 1000)
                logger.info("classifier reply %r named no class; using heuristic", raw)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # unreachable/slow mouth host: never block
                logger.warning("classifier unavailable (%s); using heuristic", exc)
        return Classification(
            classify_heuristic(text), "heuristic", (time.monotonic() - started) * 1000
        )


def make_openai_complete(llm_config, *, max_tokens: int):
    """`(system, user) -> str` over an OpenAI-compatible chat endpoint."""
    import openai

    client = openai.AsyncOpenAI(
        base_url=llm_config.base_url, api_key=llm_config.api_key, max_retries=0
    )

    async def complete(system: str, user: str) -> str:
        response = await client.chat.completions.create(
            model=llm_config.model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            max_tokens=max_tokens,
            temperature=0,
            extra_body=llm_config.extra_body or None,
        )
        return response.choices[0].message.content or ""

    return complete


# ── clause chunking ─────────────────────────────────────────────────────

_SENTENCE_END = re.compile(r"[.!?](?:[\"')\]]*)(?=\s)")
_CLAUSE_END = re.compile(r"[,;:—](?=\s)")


class ClauseChunker:
    """Cumulative text in, newly complete clauses out.

    A clause ends at sentence punctuation followed by whitespace, or at a
    comma/semicolon/colon/dash once at least `min_clause_chars` are pending,
    so the first TTS call starts on the first short clause instead of
    waiting for a whole paragraph. `flush` returns whatever remains.
    """

    def __init__(self, *, min_clause_chars: int = 24) -> None:
        self._consumed = 0
        self._text = ""
        self._min = min_clause_chars

    def feed(self, cumulative: str) -> list[str]:
        if not cumulative.startswith(self._text[: self._consumed]):
            # The source rewrote text we already spoke; keep going from the
            # same offset rather than repeating it.
            logger.info("answer text was rewritten mid-stream; continuing at offset")
        self._text = cumulative
        clauses = []
        while True:
            pending = self._text[self._consumed :]
            cut = self._next_cut(pending)
            if cut is None:
                break
            clause = pending[:cut].strip()
            self._consumed += cut
            if clause:
                clauses.append(clause)
        return clauses

    def _next_cut(self, pending: str) -> int | None:
        sentence = _SENTENCE_END.search(pending)
        best = sentence.end() if sentence else None
        for match in _CLAUSE_END.finditer(pending):
            if match.end() >= self._min and (best is None or match.end() < best):
                best = match.end()
                break
        return best

    def flush(self) -> str | None:
        rest = self._text[self._consumed :].strip()
        self._consumed = len(self._text)
        return rest or None


# ── answer sources ──────────────────────────────────────────────────────


class AnswerSource(Protocol):
    """Streams cumulative answer text for one question."""

    answered_by: str | None
    variant: str

    def stream(self, question: str) -> AsyncIterator[str]: ...


ToolCaller = Callable[[str, dict], Awaitable[dict]]


class BurrowAnswerSource:
    """Ask Burrow through Core's `voice_ask_agent`, then long-poll
    `voice_ask_poll` for the cumulative text until `done`.

    `call_tool(name, args) -> dict` is the transport (an MCP raw tool call in
    the worker, a fake in tests). `answered_by` comes from Core's reply,
    which names the agent that answered: Burrow, never the voice persona.
    """

    variant = "burrow"

    def __init__(
        self,
        call_tool: ToolCaller,
        *,
        space_id: str | None,
        agent_id: str | None = None,
        meeting_id: str | None = None,
        poll_wait_ms: int = 1500,
    ) -> None:
        self._call_tool = call_tool
        self._space_id = space_id
        self._agent_id = agent_id
        self._meeting_id = meeting_id
        self._poll_wait_ms = poll_wait_ms
        self.answered_by: str | None = None
        self.ask_id: str | None = None
        self.polls = 0
        self.final_status: str | None = None

    async def stream(self, question: str) -> AsyncIterator[str]:
        args: dict[str, Any] = {"space_id": self._space_id, "question": question}
        if self._agent_id:
            args["agent_id"] = self._agent_id
        if self._meeting_id:
            args["meeting_id"] = self._meeting_id
        asked = await self._call_tool(ASK_TOOL_NAME, args)
        self.ask_id = asked.get("ask_id")
        self.answered_by = asked.get("agent_id") or self.answered_by
        if not self.ask_id:
            raise RuntimeError(f"{ASK_TOOL_NAME} returned no ask_id: {asked!r}")

        since = 0
        while True:
            self.polls += 1
            polled = await self._call_tool(
                POLL_TOOL_NAME,
                {"ask_id": self.ask_id, "since": since, "wait_ms": self._poll_wait_ms},
            )
            self.answered_by = polled.get("answered_by") or self.answered_by
            text = polled.get("text") or ""
            if len(text) > since:
                since = len(text)
                yield text
            status = polled.get("status")
            if polled.get("done") or status in ("done", "timeout", "unknown"):
                self.final_status = status or "done"
                return


@dataclass
class RoutedAnswer:
    """Provenance and timing for one routed turn."""

    question: str
    turn_class: str
    variant: str
    answered_by: str | None = None
    ask_id: str | None = None
    timed_out: bool = False
    text: str = ""
    clauses: list[str] = field(default_factory=list)
    first_clause_at: float | None = None


async def routed_clauses(
    source: AnswerSource,
    question: str,
    *,
    turn_class: str,
    timeout_s: float,
    no_answer_text: str,
    record: RoutedAnswer | None = None,
    chunker: ClauseChunker | None = None,
) -> AsyncIterator[tuple[str, bool]]:
    """Yield `(clause, from_answer)` as the answer streams.

    `from_answer` is False only for `no_answer_text`, spoken when no answer
    text arrived within `timeout_s` or the source failed. Nothing is ever
    invented in its place. Text that stalls after it started is cut off at
    the timeout and whatever was complete is spoken.
    """
    chunker = chunker or ClauseChunker()
    record = record if record is not None else RoutedAnswer(question, turn_class, source.variant)
    deadline = time.monotonic() + timeout_s
    stream = source.stream(question)
    got_text = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                record.timed_out = True
                break
            try:
                cumulative = await asyncio.wait_for(stream.__anext__(), timeout=remaining)
            except StopAsyncIteration:
                break
            except TimeoutError:
                record.timed_out = True
                break
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("routed answer source failed: %s", exc)
                break
            record.text = cumulative
            for clause in chunker.feed(cumulative):
                got_text = True
                if record.first_clause_at is None:
                    record.first_clause_at = time.monotonic()
                record.clauses.append(clause)
                yield clause, True
        rest = chunker.flush()
        if rest:
            got_text = True
            if record.first_clause_at is None:
                record.first_clause_at = time.monotonic()
            record.clauses.append(rest)
            yield rest, True
        if not got_text:
            yield no_answer_text, False
    finally:
        record.answered_by = getattr(source, "answered_by", None)
        record.ask_id = getattr(source, "ask_id", None)
        await stream.aclose()


async def speak_clauses(
    clauses: AsyncIterator[tuple[str, bool]],
    tts_say: Callable[[str], Awaitable[Any]],
) -> list[str]:
    """Drive `tts_say` once per clause, in order, as each one arrives."""
    spoken = []
    # `aclosing`: a barge-in that cancels us mid-TTS closes the answer stream
    # at once (its `finally` stops polling), not whenever it is collected.
    async with contextlib.aclosing(clauses) as stream:
        async for clause, _from_answer in stream:
            await tts_say(clause)
            spoken.append(clause)
    return spoken


def mcp_tool_caller(toolset) -> ToolCaller:
    """`call_tool(name, args) -> dict` over the worker's live `MCPToolset`."""
    from meeting_voice_agent.mcp_tools import find_raw_tool

    async def call_tool(name: str, args: dict) -> dict:
        tool = find_raw_tool(toolset, name)
        if tool is None:
            raise RuntimeError(f"{name} is not in this runtime's granted tool surface")
        result = await tool(args)
        return decode_tool_result(result)

    return call_tool


def decode_tool_result(result) -> dict:
    """An MCP tool result as a dict.

    livekit's default resolver returns the single content item as JSON, i.e.
    `{"type": "text", "text": "<Core's JSON reply>"}`; unwrap that layer.
    """
    import json

    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            return {"text": result}
    if isinstance(result, dict) and result.get("type") == "text" and "text" in result:
        try:
            inner = json.loads(result["text"])
        except (TypeError, ValueError):
            return {"text": result["text"]}
        return inner if isinstance(inner, dict) else {"result": inner}
    if isinstance(result, dict):
        return result
    return {"result": result}


class VoiceRouter:
    """What `MeetingVoiceAgent.llm_node` needs to route a turn.

    `source_factory()` returns a fresh `AnswerSource` per routed turn.
    `on_answer(record)` receives the provenance of every routed answer (the
    worker logs it and publishes it on the room's `mva.routing` topic).
    """

    def __init__(
        self,
        config,
        classifier: LocalClassifier,
        source_factory: Callable[[], AnswerSource],
        *,
        on_answer: Callable[[RoutedAnswer], Any] | None = None,
    ) -> None:
        self.config = config
        self._classifier = classifier
        self._source_factory = source_factory
        self._on_answer = on_answer

    async def classify(self, text: str) -> Classification:
        return await self._classifier.classify(text)

    def variant_for(self, turn_class: str) -> str:
        return self.config.variant_for(turn_class)

    def new_source(self) -> AnswerSource:
        return self._source_factory()

    def report(self, record: RoutedAnswer) -> None:
        logger.info(
            "routed answer: class=%s variant=%s answered_by=%s ask_id=%s timed_out=%s",
            record.turn_class,
            record.variant,
            record.answered_by,
            record.ask_id,
            record.timed_out,
        )
        if self._on_answer is not None:
            try:
                self._on_answer(record)
            except Exception:
                logger.exception("routed answer callback failed")


#: Data-channel topic the worker publishes routed-answer provenance on.
ROUTING_TOPIC = "mva.routing"


def provenance_payload(record: RoutedAnswer) -> dict:
    """The provenance a routed answer carries: who answered, and which variant."""
    return {
        "answered_by": record.answered_by,
        "variant": record.variant,
        "turn_class": record.turn_class,
        "ask_id": record.ask_id,
        "timed_out": record.timed_out,
    }
