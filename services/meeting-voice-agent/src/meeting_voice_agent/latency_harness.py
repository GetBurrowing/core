"""Repeatable first-audio-latency measurement harness (task 01a0d4a0 stage 4).

This module is deliberately split from `latency_harness_live.py`:

- Everything HERE is pure: timestamp -> latency arithmetic, aggregation across
  repeated runs, JSONL persistence, and report formatting. None of it touches
  a network or the `livekit` SDK, so it is exactly what stage 4's `test_pass`
  validation asks for — "deterministic unit tests on its timing/aggregation
  logic against fixture data, not the live run" (see
  `tests/test_latency_harness.py`).
- `latency_harness_live.py` is the part that actually joins a real LiveKit
  room, publishes a short spoken question, and times the agent's first
  returned audio frame. It imports everything it needs from here so a live
  run and a fixture-driven test exercise the same aggregation/report code.

Reference, not a bar this module enforces: Brosnan owns the 31 December
voice-latency deadline. `format_report` states the measured number against
that date as context only — it never emits a pass/fail verdict, and no
threshold is hard-coded here. See README.md's "Latency harness" section.
"""

from __future__ import annotations

import json
import math
import statistics
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path

#: Reference point only — Brosnan's, not an independently invented target.
#: Never compared against a measured value to produce a pass/fail verdict.
REFERENCE_TARGET_DATE = "2026-12-31"
REFERENCE_TARGET_LABEL = "Brosnan's 31 December voice-latency deadline"

#: dBFS reported for an empty or fully-silent (all-zero) buffer, in place of
#: the `-inf` `log10(0)` would produce. A genuinely silent frame is the
#: common case `samples_dbfs`/`is_audio_frame_loud` exist to detect, not an
#: error, so it gets a (very quiet, but finite) floor value rather than
#: raising or returning NaN/-inf that would poison a comparison.
SILENCE_DBFS_FLOOR = -120.0

#: Dalton's working value from the live moon run this fixes (rollup space
#: 01a0b5bf): loud enough to be real speech, quiet enough not to miss a
#: quiet response. The agent's LiveKit audio track publishes a frame every
#: ~20ms whether or not it is actually speaking (see
#: `latency_harness_live.py`'s module docstring), so gating "first audio
#: frame" on this threshold — not mere frame arrival — is what makes the
#: measurement mean "first frame of actual speech".
DEFAULT_ENERGY_GATE_DBFS = -45.0


def samples_dbfs(samples) -> float:
    """RMS dBFS of a sequence of signed 16-bit samples, relative to full scale (32768).

    `samples` is anything iterable of ints in [-32768, 32767] — in
    particular, `rtc.AudioFrame.data`, which is exactly a memoryview cast to
    `"h"` (see `livekit.rtc.audio_frame.AudioFrame.data`), but a plain
    `list`/`array.array` works identically, which is what keeps this
    function unit-testable without importing `livekit.rtc` at all.

    Returns `SILENCE_DBFS_FLOOR` for an empty buffer or one whose samples are
    all zero, rather than raising or returning `-inf` from `log10(0)`.
    """
    count = 0
    sum_of_squares = 0
    for sample in samples:
        sum_of_squares += sample * sample
        count += 1
    if count == 0 or sum_of_squares == 0:
        return SILENCE_DBFS_FLOOR
    rms = math.sqrt(sum_of_squares / count)
    return 20.0 * math.log10(rms / 32768.0)


def is_audio_frame_loud(samples, threshold_dbfs: float = DEFAULT_ENERGY_GATE_DBFS) -> bool:
    """The energy gate itself: does this buffer carry real signal, not silence?

    This is the fix for the harness bug where "first audio frame" fired on
    the agent's very first (silent) keepalive frame, reporting a nonsense
    ~7ms median instead of a real latency (Dalton's moon run, rollup space
    01a0b5bf) — gate on measured energy, not mere frame arrival.
    """
    return samples_dbfs(samples) >= threshold_dbfs


def sample_with_tool_call(
    sample: LatencySample,
    *,
    tool_names: list[str],
    first_call_latency_ms: float | None = None,
) -> LatencySample:
    """Return a copy of `sample` recording that a tool call was actually observed.

    Fixes the harness bug where `LatencySample.tool_call` was always `False`
    because nothing ever set it (Dalton's moon run: "the harness never
    records tool-call latency ... its `tool_call` field is always false").
    Callers pass real, externally-observed tool names (see
    `tool_telemetry.parse_tool_call_names` in `latency_harness_live.py`) —
    this function never invents a tool call, it only records one it is told
    actually happened. A `tool_names` of `[]` returns `sample` unchanged.
    """
    if not tool_names:
        return sample
    names = ", ".join(dict.fromkeys(tool_names))  # de-dup, preserve first-seen order
    notes = f"tool_call: {names}"
    if first_call_latency_ms is not None:
        notes += f" ({first_call_latency_ms:.1f} ms after speech end)"
    return replace(sample, tool_call=True, notes=notes)


@dataclass(frozen=True)
class LatencySample:
    """One measured (or fixture) exchange.

    `case` is a free-form label for which e2e scenario produced this sample
    (e.g. "simple_latency", "tool_call") — the harness is reused across the
    stage's live cases, not just the dedicated latency case, so aggregation
    can be filtered by case later without changing this shape.
    """

    case: str
    question: str
    speech_end_ts: float
    first_audio_ts: float
    tool_call: bool = False
    notes: str = ""

    @property
    def latency_ms(self) -> float:
        return compute_latency_ms(self.speech_end_ts, self.first_audio_ts)

    def to_dict(self) -> dict:
        data = asdict(self)
        data["latency_ms"] = self.latency_ms
        return data

    @classmethod
    def from_dict(cls, data: dict) -> LatencySample:
        return cls(
            case=data["case"],
            question=data["question"],
            speech_end_ts=data["speech_end_ts"],
            first_audio_ts=data["first_audio_ts"],
            tool_call=data.get("tool_call", False),
            notes=data.get("notes", ""),
        )


@dataclass(frozen=True)
class LatencyReport:
    """Aggregate stats (milliseconds) over one or more `LatencySample`s."""

    count: int
    min_ms: float
    max_ms: float
    mean_ms: float
    median_ms: float
    p95_ms: float
    samples: tuple[LatencySample, ...] = field(default_factory=tuple)


def compute_latency_ms(speech_end_ts: float, first_audio_ts: float) -> float:
    """Elapsed time in milliseconds from end-of-human-speech to first agent audio frame.

    Both timestamps are the same monotonic clock (e.g. `time.monotonic()`)
    from a single measurement run — never wall-clock times from different
    processes. Raises `ValueError` if the audio frame is not after speech
    ended; that would mean the two timestamps did not come from the same
    ordered measurement and the sample should be discarded, not silently
    reported as a (nonsensical) negative or zero latency.
    """
    if first_audio_ts < speech_end_ts:
        raise ValueError(
            f"first_audio_ts ({first_audio_ts}) is before speech_end_ts "
            f"({speech_end_ts}) -- not a valid measurement"
        )
    return (first_audio_ts - speech_end_ts) * 1000.0


def aggregate_samples(samples: list[LatencySample]) -> LatencyReport:
    """Aggregate a batch of samples into min/max/mean/median/p95 (milliseconds).

    Raises `ValueError` on an empty list -- an empty aggregate is not a
    zero-latency result, it is the absence of a measurement, and callers
    (including the live runner) must not confuse the two.
    """
    if not samples:
        raise ValueError("cannot aggregate an empty sample list")

    latencies = sorted(sample.latency_ms for sample in samples)
    return LatencyReport(
        count=len(latencies),
        min_ms=latencies[0],
        max_ms=latencies[-1],
        mean_ms=statistics.mean(latencies),
        median_ms=statistics.median(latencies),
        p95_ms=_percentile(latencies, 0.95),
        samples=tuple(samples),
    )


def _percentile(sorted_values: list[float], fraction: float) -> float:
    """Nearest-rank percentile over an already-sorted list. No numpy dependency."""
    if len(sorted_values) == 1:
        return sorted_values[0]
    index = round(fraction * (len(sorted_values) - 1))
    index = max(0, min(index, len(sorted_values) - 1))
    return sorted_values[index]


def dump_samples_jsonl(samples: list[LatencySample], path: Path) -> None:
    """Append-write samples as JSON Lines -- one measurement run per line.

    JSONL (not a single JSON array) so a long-running harness can append
    results from repeated runs (as thresholds/model change, per the stage's
    "re-runnable" requirement) without re-reading and rewriting the whole
    file each time.
    """
    with path.open("a", encoding="utf-8") as handle:
        for sample in samples:
            handle.write(json.dumps(sample.to_dict()))
            handle.write("\n")


def load_samples_jsonl(path: Path) -> list[LatencySample]:
    """Read back every sample previously written by `dump_samples_jsonl`."""
    if not path.exists():
        return []
    samples = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            samples.append(LatencySample.from_dict(json.loads(line)))
    return samples


def format_report(report: LatencyReport) -> str:
    """Human-readable report of a measured latency -- reference only, no verdict.

    Deliberately does not compare `report` against any threshold and does
    not emit pass/fail language: this stage's job is to report the real
    number, not to judge it against a bar that belongs to Brosnan. Keep it
    that way if you touch this function -- see `tests/test_latency_harness.py`
    for a guard test on exactly this property.
    """
    lines = [
        f"first-audio latency ({report.count} sample{'s' if report.count != 1 else ''}):",
        f"  min:    {report.min_ms:.1f} ms",
        f"  median: {report.median_ms:.1f} ms",
        f"  mean:   {report.mean_ms:.1f} ms",
        f"  p95:    {report.p95_ms:.1f} ms",
        f"  max:    {report.max_ms:.1f} ms",
        "",
        f"reference (not a bar this harness enforces): {REFERENCE_TARGET_LABEL} "
        f"({REFERENCE_TARGET_DATE}). Report the measured number to Brosnan; "
        "he sets the bar, this harness only measures.",
    ]
    return "\n".join(lines)
