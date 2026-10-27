"""Pure parts of the routing harness (task 01a17b10 stage 4)."""

from __future__ import annotations

import pytest

from meeting_voice_agent import routing_harness as h


def test_scripted_set_has_ten_or_more_keyed_questions_and_three_or_more_acks():
    utterances = h.scripted_set()
    substantive = [u for u in utterances if u.expected_class == "substantive"]
    assert len(substantive) >= 10
    assert all(u.answer_keys for u in substantive)
    assert len([u for u in utterances if u.expected_class == "ack"]) >= 3


@pytest.mark.parametrize(
    ("question", "answer", "ok"),
    [
        ("What year did the Berlin Wall fall?", "It fell in 1989.", True),
        ("What year did the Berlin Wall fall?", "It fell in 1991.", False),
        ("What is the chemical symbol for gold?", "Gold's symbol is Au.", True),
        ("What is the chemical symbol for gold?", "It's from Australia.", False),
        ("What is the time complexity of binary search?", "O(log n).", True),
        ("How many letter r's are in the word strawberry?", "There are 2.", False),
    ],
)
def test_answer_keys(question, answer, ok):
    keys = next(u.answer_keys for u in h.scripted_set() if u.text == question)
    assert h.is_correct(answer, keys) is ok


def test_percentile_is_nearest_rank():
    values = [float(v) for v in range(1, 11)]
    assert h.percentile(values, 0.5) == 5
    assert h.percentile(values, 0.9) == 9
    assert h.percentile([7.0], 0.9) == 7
    with pytest.raises(ValueError):
        h.percentile([], 0.5)


def test_ttfsw_summary_counts_only_answered_rows_and_names_who_answered():
    rows = [
        h.TtfswRow("q1", "substantive", "burrow", "burrow-id", 300, 900, 2000, "1989", True),
        h.TtfswRow("q2", "substantive", "burrow", "burrow-id", 300, 1100, 2000, "x", False),
        h.TtfswRow("q3", "substantive", "burrow", "burrow-id", 300, None, 2000, "", False, True),
    ]
    s = h.summarize_ttfsw("after", rows)
    assert (s.n, s.p50_ms, s.p90_ms, s.correct) == (3, 900, 1100, 1)
    assert s.extra["timed_out"] == 1
    assert s.extra["answered_by"] == ["burrow-id"]
    table = h.format_table([s], metric="TTFSW")
    assert "| after | 3 | 900 | 1100 | 1/3 |" in table


def test_mouth_summary_scores_turn_classes():
    rows = [
        h.MouthRow("thanks", "ack", "ack", "model", 100, 50),
        h.MouthRow("go ahead", "turn_taking", "ack", "model", 120, 60),
        h.MouthRow("What year?", "substantive", "substantive", "model", 130),
    ]
    s = h.summarize_mouth("m", rows)
    assert s.correct == 2
    assert s.extra["turn_taking_correct"] == 1
    assert s.extra["routed_correctly"] == 3  # ack and turn_taking both route local
    assert s.p50_ms == 150


def test_claude_stream_json_text_delta():
    event = {
        "type": "stream_event",
        "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hi"}},
    }
    assert h._claude_text_delta(event) == "Hi"
    assert h._claude_text_delta({"type": "assistant"}) is None
