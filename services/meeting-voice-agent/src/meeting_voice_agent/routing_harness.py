"""Routing harness (task 01a17b10 stage 4): mouth candidates and
time-to-first-substantive-word (TTFSW).

Two measurements, both runnable against any OpenAI-compatible mouth endpoint
named only through env (`MVA_LLM_BASE_URL`, `MVA_LLM_MODEL`):

`mouth`  For each utterance in the scripted set, ask the mouth to classify it
         (`routing.LocalClassifier`, the same prompt the worker uses) and, for
         ack and turn-taking utterances, time its first reply token. Reports
         classify and ack latency p50/p90 and turn-class correctness.

`ttfsw`  For each substantive question: classify, then answer it either with
         the mouth (`--substantive local`, BEFORE) or a routed brain
         (`--substantive burrow`, AFTER), chunk the stream into clauses, and
         synthesize the FIRST answer clause. TTFSW is end of question to first
         TTS audio of that clause: the ack is not counted. Correctness is
         matched against each question's answer keys.

Brains for AFTER: `burrow` asks Core's `voice_ask_agent` over MCP
(`MVA_MCP_BASE_URL`, `MVA_MCP_AUTH_TOKEN`, `MVA_HARNESS_SPACE_ID`), the real
path. `claude-cli` streams the same prompt through the local `claude` CLI, a
stand-in for Burrow's model that leaves out Core's dispatch hop; reports name
the brain used.

TTS: `openai` posts to `MVA_TTS_BASE_URL/audio/speech` and times the first
audio bytes; `say` (macOS) times a local synthesis of the clause. Reports name
the TTS used. Pure helpers (scripted set, scoring, percentiles, tables) are
unit-tested in `tests/test_routing_harness.py`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections.abc import AsyncIterator
from dataclasses import asdict, dataclass, field

from meeting_voice_agent import routing
from meeting_voice_agent.config import DEFAULT_ROUTING, LlmConfig, RoutingConfig

ANSWER_STYLE = (
    "Answer in one to three short spoken sentences, plain text, no markdown. "
    "If you do not know, say so."
)
MOUTH_SYSTEM = "You are a concise meeting assistant. " + ANSWER_STYLE


@dataclass(frozen=True)
class Utterance:
    text: str
    expected_class: str
    answer_keys: tuple[str, ...] = ()


def scripted_set() -> list[Utterance]:
    """N=12 substantive questions with answer keys (regexes, any one matches,
    case-insensitive), plus four acks and four turn-taking utterances."""
    s = "substantive"
    return [
        Utterance("What year did the Berlin Wall fall?", s, (r"\b1989\b",)),
        Utterance(
            "What is seventeen times twenty three?",
            s,
            (r"\b391\b", r"three hundred (and )?ninety[- ]one"),
        ),
        Utterance("Who wrote Pride and Prejudice?", s, (r"austen",)),
        Utterance("What is the chemical symbol for gold?", s, (r"\bau\b",)),
        Utterance("What is fifteen percent of eighty?", s, (r"\b12\b", r"\btwelve\b")),
        Utterance(
            "If a meeting starts at ten forty five and runs fifty minutes, when does it end?",
            s,
            (r"11:35", r"eleven thirty[- ]five"),
        ),
        Utterance("How many letter r's are in the word strawberry?", s, (r"\bthree\b", r"\b3\b")),
        Utterance("What is the largest ocean on Earth?", s, (r"pacific",)),
        Utterance("Which programming language is Phoenix LiveView written in?", s, (r"elixir",)),
        Utterance(
            "What does an HTTP 404 status code mean?",
            s,
            (r"not found", r"can.?t be found", r"could not be found"),
        ),
        Utterance("What is the time complexity of binary search?", s, (r"\blog",)),
        Utterance(
            "Which is heavier, a kilogram of feathers or a kilogram of steel?",
            s,
            (r"same", r"equal", r"neither"),
        ),
        Utterance("thanks", "ack"),
        Utterance("okay got it", "ack"),
        Utterance("sounds good", "ack"),
        Utterance("great thank you", "ack"),
        Utterance("can you hear me?", "turn_taking"),
        Utterance("hold on a second", "turn_taking"),
        Utterance("sorry, say that again?", "turn_taking"),
        Utterance("go ahead", "turn_taking"),
    ]


def is_correct(answer: str, keys: tuple[str, ...]) -> bool:
    """Any key regex matches the answer, case-insensitively."""
    return any(re.search(key, answer or "", re.IGNORECASE) for key in keys)


def percentile(values: list[float], fraction: float) -> float:
    """Nearest-rank percentile: the ceil(fraction * n)-th smallest. No numpy."""
    if not values:
        raise ValueError("no values")
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


@dataclass
class MouthRow:
    text: str
    expected_class: str
    got_class: str
    source: str
    classify_ms: float
    reply_first_token_ms: float | None = None


@dataclass
class TtfswRow:
    question: str
    turn_class: str
    variant: str
    answered_by: str | None
    ack_audio_ms: float | None
    ttfsw_ms: float | None
    total_ms: float
    answer: str
    correct: bool
    timed_out: bool = False


@dataclass
class Summary:
    label: str
    n: int
    p50_ms: float | None
    p90_ms: float | None
    correct: int
    extra: dict = field(default_factory=dict)


def summarize_mouth(label: str, rows: list[MouthRow]) -> Summary:
    classify = [r.classify_ms for r in rows]
    ack = [
        r.classify_ms + r.reply_first_token_ms
        for r in rows
        if r.expected_class != "substantive" and r.reply_first_token_ms is not None
    ]
    turn_rows = [r for r in rows if r.expected_class != "substantive"]
    return Summary(
        label=label,
        n=len(rows),
        p50_ms=percentile(ack, 0.5) if ack else None,
        p90_ms=percentile(ack, 0.9) if ack else None,
        correct=sum(1 for r in rows if r.got_class == r.expected_class),
        extra={
            "classify_p50_ms": percentile(classify, 0.5),
            "classify_p90_ms": percentile(classify, 0.9),
            "turn_taking_correct": sum(1 for r in turn_rows if r.got_class == r.expected_class),
            "turn_taking_n": len(turn_rows),
            "routed_correctly": sum(
                1
                for r in rows
                if RoutingConfig().variant_for(r.got_class)
                == RoutingConfig().variant_for(r.expected_class)
            ),
            "heuristic_fallbacks": sum(1 for r in rows if r.source != "model"),
        },
    )


def summarize_ttfsw(label: str, rows: list[TtfswRow]) -> Summary:
    values = [r.ttfsw_ms for r in rows if r.ttfsw_ms is not None]
    return Summary(
        label=label,
        n=len(rows),
        p50_ms=percentile(values, 0.5) if values else None,
        p90_ms=percentile(values, 0.9) if values else None,
        correct=sum(1 for r in rows if r.correct),
        extra={
            "answered": len(values),
            "timed_out": sum(1 for r in rows if r.timed_out),
            "answered_by": sorted({r.answered_by or "local" for r in rows}),
            "mean_ms": statistics.mean(values) if values else None,
        },
    )


def _ms(value: float | None) -> str:
    return "-" if value is None else f"{value:.0f}"


def format_table(summaries: list[Summary], *, metric: str) -> str:
    lines = [f"| run | N | {metric} p50 ms | {metric} p90 ms | correct |", "|---|---|---|---|---|"]
    for s in summaries:
        lines.append(
            f"| {s.label} | {s.n} | {_ms(s.p50_ms)} | {_ms(s.p90_ms)} | {s.correct}/{s.n} |"
        )
    return "\n".join(lines)


# ── transports ─────────────────────────────────────────────────────────


def _openai_client(llm_config: LlmConfig):
    import openai

    return openai.AsyncOpenAI(
        base_url=llm_config.base_url, api_key=llm_config.api_key, max_retries=0
    )


class MouthStream:
    """Cumulative text of a streamed mouth reply; `first_token_at` set on the first delta."""

    variant = "local"

    def __init__(self, llm_config: LlmConfig, *, system: str = MOUTH_SYSTEM, max_tokens=160):
        self._config = llm_config
        self._client = _openai_client(llm_config)
        self._system = system
        self._max_tokens = max_tokens
        self.answered_by = None
        self.first_token_at: float | None = None

    async def stream(self, question: str) -> AsyncIterator[str]:
        response = await self._client.chat.completions.create(
            model=self._config.model,
            messages=[
                {"role": "system", "content": self._system},
                {"role": "user", "content": question},
            ],
            max_tokens=self._max_tokens,
            temperature=0,
            stream=True,
            extra_body=self._config.extra_body or None,
        )
        text = ""
        async for chunk in response:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta.content or ""
            if not delta:
                continue
            if self.first_token_at is None:
                self.first_token_at = time.monotonic()
            text += delta
            yield text


class ClaudeCliStream:
    """Burrow's model through the local `claude` CLI, streamed. A stand-in:
    it leaves out Core's attention/dispatch hop."""

    variant = "burrow"

    def __init__(self, *, model: str | None = None) -> None:
        self._model = model
        self.answered_by = "claude-cli"

    async def stream(self, question: str) -> AsyncIterator[str]:
        args = [
            shutil.which("claude") or "claude",
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools",
            "",
        ]
        if self._model:
            args += ["--model", self._model]
        args.append(f"{ANSWER_STYLE}\n\nQuestion (spoken in a meeting): {question}")
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL
        )
        text = ""
        try:
            assert proc.stdout is not None
            async for line in proc.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                delta = _claude_text_delta(event)
                if delta:
                    text += delta
                    yield text
                elif event.get("type") == "result" and not text:
                    text = event.get("result") or ""
                    if text:
                        yield text
        finally:
            if proc.returncode is None:
                proc.kill()
            await proc.wait()


def _claude_text_delta(event: dict) -> str | None:
    if event.get("type") != "stream_event":
        return None
    inner = event.get("event") or {}
    if inner.get("type") != "content_block_delta":
        return None
    delta = inner.get("delta") or {}
    return delta.get("text") if delta.get("type") == "text_delta" else None


async def mcp_call_tool_factory(base_url: str, token: str):
    """An async context manager yielding `call_tool(name, args) -> dict` over Core's MCP."""
    from contextlib import asynccontextmanager

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    @asynccontextmanager
    async def connect():
        async with streamablehttp_client(
            base_url, headers={"Authorization": f"Bearer {token}"}
        ) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()

                async def call_tool(name: str, args: dict) -> dict:
                    result = await session.call_tool(name, args)
                    if result.isError:
                        raise RuntimeError(" ".join(getattr(c, "text", "") for c in result.content))
                    return routing.decode_tool_result(result.content[0].model_dump_json())

                yield call_tool

    return connect()


class SayTts:
    """macOS `say`: time to synthesize the clause to a file."""

    name = "say"

    async def first_audio_ms(self, text: str) -> float:
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "clause.aiff")
            started = time.monotonic()
            proc = await asyncio.create_subprocess_exec("say", "-o", out, text)
            await proc.wait()
            return (time.monotonic() - started) * 1000


class OpenAiTts:
    """OpenAI-compatible `/audio/speech`: time to the first audio bytes."""

    name = "openai"

    def __init__(self, base_url: str, model: str, voice: str, api_key: str = "not-needed"):
        self._url = base_url.rstrip("/") + "/audio/speech"
        self._body = {"model": model, "voice": voice, "response_format": "pcm"}
        self._headers = {"Authorization": f"Bearer {api_key}"}

    async def first_audio_ms(self, text: str) -> float:
        import httpx

        started = time.monotonic()
        async with httpx.AsyncClient(timeout=30) as client:
            async with client.stream(
                "POST", self._url, json={**self._body, "input": text}, headers=self._headers
            ) as response:
                response.raise_for_status()
                async for chunk in response.aiter_bytes():
                    if chunk:
                        return (time.monotonic() - started) * 1000
        return (time.monotonic() - started) * 1000


def build_tts():
    base_url = os.environ.get("MVA_TTS_BASE_URL")
    if base_url:
        return OpenAiTts(
            base_url,
            os.environ.get("MVA_TTS_MODEL", "kokoro"),
            os.environ.get("MVA_TTS_VOICE", "af_heart"),
            os.environ.get("MVA_TTS_API_KEY", "not-needed"),
        )
    if shutil.which("say"):
        return SayTts()
    raise SystemExit("no TTS: set MVA_TTS_BASE_URL or run where `say` exists")


# ── runs ───────────────────────────────────────────────────────────────


async def run_mouth(llm_config: LlmConfig, utterances: list[Utterance]) -> list[MouthRow]:
    classifier = routing.LocalClassifier.from_llm_config(llm_config, timeout_s=10)
    rows = []
    # One warm-up call so model load is not charged to the first utterance.
    await classifier.classify("hello")
    for u in utterances:
        result = await classifier.classify(u.text)
        row = MouthRow(
            u.text, u.expected_class, result.turn_class, result.source, result.latency_ms
        )
        if u.expected_class != "substantive":
            mouth = MouthStream(llm_config, max_tokens=24)
            started = time.monotonic()
            async for _ in mouth.stream(u.text):
                break
            if mouth.first_token_at is not None:
                row.reply_first_token_ms = (mouth.first_token_at - started) * 1000
        rows.append(row)
    return rows


async def run_ttfsw(
    llm_config: LlmConfig,
    routing_config: RoutingConfig,
    utterances: list[Utterance],
    tts,
    brain_factory,
) -> list[TtfswRow]:
    classifier = routing.LocalClassifier.from_llm_config(
        llm_config, timeout_s=routing_config.classifier_timeout_s
    )
    await classifier.classify("hello")
    rows = []
    for u in [u for u in utterances if u.expected_class == "substantive"]:
        started = time.monotonic()
        classification = await classifier.classify(u.text)
        variant = routing_config.variant_for(classification.turn_class)
        ack_ms = None
        if variant == "burrow":
            source = brain_factory()
            ack_task = asyncio.create_task(tts.first_audio_ms(routing_config.ack_text))
        else:
            source = MouthStream(llm_config)
            ack_task = None
        record = routing.RoutedAnswer(u.text, classification.turn_class, variant)
        ttfsw = None
        async for clause, from_answer in routing.routed_clauses(
            source,
            u.text,
            turn_class=classification.turn_class,
            timeout_s=routing_config.answer_timeout_s,
            no_answer_text=routing_config.no_answer_text,
            record=record,
        ):
            if ttfsw is None and from_answer:
                ttfsw = (time.monotonic() - started) * 1000 + await tts.first_audio_ms(clause)
        if ack_task is not None:
            ack_ms = (classification.latency_ms) + await ack_task
        answer = record.text
        rows.append(
            TtfswRow(
                question=u.text,
                turn_class=classification.turn_class,
                variant=variant,
                answered_by=record.answered_by,
                ack_audio_ms=ack_ms,
                ttfsw_ms=ttfsw,
                total_ms=(time.monotonic() - started) * 1000,
                answer=answer,
                correct=is_correct(answer, u.answer_keys),
                timed_out=record.timed_out,
            )
        )
    return rows


def _llm_config_from_env() -> LlmConfig:
    return LlmConfig.from_env()


async def _amain(args) -> int:
    llm_config = _llm_config_from_env()
    utterances = scripted_set()
    if args.command == "mouth":
        rows = await run_mouth(llm_config, utterances)
        summary = summarize_mouth(args.label or llm_config.model, rows)
        _emit(args, rows, summary, metric="ack")
        return 0

    routes = dict(DEFAULT_ROUTING)
    routes["substantive"] = args.substantive
    routing_config = RoutingConfig(
        routes=routes, answer_timeout_s=args.answer_timeout, classifier_timeout_s=2.0
    )
    tts = build_tts()
    if args.substantive == "burrow" and args.brain == "burrow":
        connect = await mcp_call_tool_factory(
            os.environ["MVA_MCP_BASE_URL"], os.environ.get("MVA_MCP_AUTH_TOKEN", "")
        )
        async with connect as call_tool:
            rows = await run_ttfsw(
                llm_config,
                routing_config,
                utterances,
                tts,
                lambda: routing.BurrowAnswerSource(
                    call_tool,
                    space_id=os.environ["MVA_HARNESS_SPACE_ID"],
                    agent_id=os.environ.get("MVA_BURROW_AGENT_ID"),
                ),
            )
    else:
        rows = await run_ttfsw(
            llm_config,
            routing_config,
            utterances,
            tts,
            lambda: ClaudeCliStream(model=args.claude_model),
        )
    label = args.label or (
        "before (all local)" if args.substantive == "local" else f"after (brain={args.brain})"
    )
    summary = summarize_ttfsw(label, rows)
    summary.extra["tts"] = tts.name
    summary.extra["mouth"] = llm_config.model
    _emit(args, rows, summary, metric="TTFSW")
    return 0


def _emit(args, rows, summary: Summary, *, metric: str) -> None:
    payload = {"summary": asdict(summary), "rows": [asdict(r) for r in rows]}
    if args.out:
        with open(args.out, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload) + "\n")
    for row in rows:
        print(json.dumps(asdict(row)), file=sys.stderr)
    print(format_table([summary], metric=metric))
    print(json.dumps(summary.extra))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="meeting-voice-routing-harness")
    sub = parser.add_subparsers(dest="command", required=True)
    mouth = sub.add_parser("mouth", help="ack latency and turn-class correctness for MVA_LLM_*")
    ttfsw = sub.add_parser("ttfsw", help="time to first substantive word, before/after routing")
    ttfsw.add_argument("--substantive", choices=["local", "burrow"], required=True)
    ttfsw.add_argument("--brain", choices=["burrow", "claude-cli"], default="burrow")
    ttfsw.add_argument("--claude-model", default=None)
    ttfsw.add_argument("--answer-timeout", type=float, default=30.0)
    for p in (mouth, ttfsw):
        p.add_argument("--label", default=None)
        p.add_argument("--out", default=None, help="append JSON results to this file")
    return asyncio.run(_amain(parser.parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
