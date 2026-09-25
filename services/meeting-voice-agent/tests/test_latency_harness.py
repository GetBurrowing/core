"""Deterministic unit tests for the latency harness's timing/aggregation logic.

All fixture data -- no LiveKit connection, no network, no real audio. This is
the `test_pass` validation for task 01a0d4a0 stage 4: "deterministic unit
tests on its timing/aggregation logic against fixture data, not the live
run." `latency_harness_live.py` (the part that actually joins a room) is
intentionally not exercised here -- see its module docstring.
"""

from __future__ import annotations

import pytest

from meeting_voice_agent.latency_harness import (
    DEFAULT_ENERGY_GATE_DBFS,
    REFERENCE_TARGET_DATE,
    SILENCE_DBFS_FLOOR,
    LatencySample,
    aggregate_samples,
    compute_latency_ms,
    dump_samples_jsonl,
    format_report,
    is_audio_frame_loud,
    load_samples_jsonl,
    sample_with_tool_call,
    samples_dbfs,
)


def _sample(case: str, speech_end: float, first_audio: float, **kwargs) -> LatencySample:
    return LatencySample(
        case=case,
        question="what time is our next meeting",
        speech_end_ts=speech_end,
        first_audio_ts=first_audio,
        **kwargs,
    )


class TestComputeLatencyMs:
    def test_basic_elapsed_time(self):
        assert compute_latency_ms(speech_end_ts=10.0, first_audio_ts=10.25) == pytest.approx(250.0)

    def test_zero_latency_is_valid(self):
        assert compute_latency_ms(speech_end_ts=5.0, first_audio_ts=5.0) == 0.0

    def test_raises_when_audio_precedes_speech_end(self):
        with pytest.raises(ValueError, match="before speech_end_ts"):
            compute_latency_ms(speech_end_ts=10.0, first_audio_ts=9.5)


class TestLatencySample:
    def test_latency_ms_property_matches_compute_latency_ms(self):
        sample = _sample("simple_latency", speech_end=100.0, first_audio=100.42)
        assert sample.latency_ms == pytest.approx(420.0)

    def test_to_dict_round_trips_through_from_dict(self):
        sample = _sample(
            "tool_call", speech_end=1.0, first_audio=1.6, tool_call=True, notes="space_get_context"
        )
        restored = LatencySample.from_dict(sample.to_dict())
        assert restored == sample

    def test_to_dict_includes_derived_latency_ms(self):
        sample = _sample("simple_latency", speech_end=0.0, first_audio=0.09)
        assert sample.to_dict()["latency_ms"] == pytest.approx(90.0)


class TestAggregateSamples:
    def test_empty_list_raises(self):
        with pytest.raises(ValueError, match="empty sample list"):
            aggregate_samples([])

    def test_single_sample_all_stats_equal_that_sample(self):
        sample = _sample("simple_latency", speech_end=0.0, first_audio=0.2)
        report = aggregate_samples([sample])

        assert report.count == 1
        assert report.min_ms == report.max_ms == report.mean_ms == report.median_ms
        assert report.min_ms == pytest.approx(200.0)

    def test_known_fixture_distribution(self):
        # Latencies (ms): 100, 200, 300, 400, 500 -- exact stats are known by hand.
        samples = [
            _sample("simple_latency", speech_end=0.0, first_audio=0.1),
            _sample("simple_latency", speech_end=0.0, first_audio=0.2),
            _sample("simple_latency", speech_end=0.0, first_audio=0.3),
            _sample("simple_latency", speech_end=0.0, first_audio=0.4),
            _sample("simple_latency", speech_end=0.0, first_audio=0.5),
        ]

        report = aggregate_samples(samples)

        assert report.count == 5
        assert report.min_ms == pytest.approx(100.0)
        assert report.max_ms == pytest.approx(500.0)
        assert report.mean_ms == pytest.approx(300.0)
        assert report.median_ms == pytest.approx(300.0)
        # Nearest-rank nth_percentile over 5 sorted values at 95%: index
        # round(0.95 * 4) = 4 -> the max.
        assert report.p95_ms == pytest.approx(500.0)

    def test_aggregation_stats_independent_of_input_order(self):
        ordered = [
            _sample("simple_latency", speech_end=0.0, first_audio=0.1),
            _sample("simple_latency", speech_end=0.0, first_audio=0.3),
            _sample("simple_latency", speech_end=0.0, first_audio=0.2),
        ]
        shuffled = [ordered[2], ordered[0], ordered[1]]

        by_order = aggregate_samples(ordered)
        by_shuffled = aggregate_samples(shuffled)

        # The stats must agree regardless of input order; `samples` itself is
        # allowed to preserve whatever order the caller passed in, so compare
        # everything except that field.
        assert (by_order.count, by_order.min_ms, by_order.max_ms, by_order.mean_ms) == (
            by_shuffled.count,
            by_shuffled.min_ms,
            by_shuffled.max_ms,
            by_shuffled.mean_ms,
        )
        assert by_order.median_ms == pytest.approx(by_shuffled.median_ms)
        assert by_order.p95_ms == pytest.approx(by_shuffled.p95_ms)


class TestJsonlRoundTrip:
    def test_dump_then_load_preserves_samples(self, tmp_path):
        path = tmp_path / "results.jsonl"
        samples = [
            _sample("simple_latency", speech_end=0.0, first_audio=0.12),
            _sample("tool_call", speech_end=1.0, first_audio=1.8, tool_call=True),
        ]

        dump_samples_jsonl(samples, path)
        loaded = load_samples_jsonl(path)

        assert loaded == samples

    def test_dump_appends_across_multiple_calls(self, tmp_path):
        path = tmp_path / "results.jsonl"
        first = _sample("simple_latency", speech_end=0.0, first_audio=0.1)
        second = _sample("simple_latency", speech_end=10.0, first_audio=10.3)

        dump_samples_jsonl([first], path)
        dump_samples_jsonl([second], path)

        assert load_samples_jsonl(path) == [first, second]

    def test_loading_a_missing_file_returns_empty_list(self, tmp_path):
        assert load_samples_jsonl(tmp_path / "does-not-exist.jsonl") == []


class TestSamplesDbfs:
    """Task 01a0d4a0 stage 4 round 2: the energy gate. Dalton's moon run found
    the harness measured ~7ms median because it counted the agent's silent
    keepalive frames (sent every ~20ms regardless of speech) as "first audio".
    """

    def test_all_zero_samples_is_silence_floor(self):
        assert samples_dbfs([0] * 480) == SILENCE_DBFS_FLOOR

    def test_empty_samples_is_silence_floor(self):
        assert samples_dbfs([]) == SILENCE_DBFS_FLOOR

    def test_full_scale_square_wave_is_zero_dbfs(self):
        # Alternating +/- full scale: RMS == 32768 == 0 dBFS by definition.
        samples = [32767, -32768] * 240
        assert samples_dbfs(samples) == pytest.approx(0.0, abs=0.01)

    def test_quiet_signal_is_lower_dbfs_than_loud_signal(self):
        quiet = [100, -100] * 240
        loud = [10000, -10000] * 240
        assert samples_dbfs(quiet) < samples_dbfs(loud)

    def test_accepts_a_memoryview_like_livekit_frame_data(self):
        import array

        buf = array.array("h", [5000, -5000] * 10)
        # `rtc.AudioFrame.data` is a memoryview cast to "h" -- confirm a real
        # memoryview over int16 samples works identically to a plain list.
        view = memoryview(buf)
        assert samples_dbfs(view) == samples_dbfs(list(buf))


class TestIsAudioFrameLoud:
    def test_silence_is_not_loud(self):
        assert is_audio_frame_loud([0] * 480) is False

    def test_full_scale_is_loud(self):
        assert is_audio_frame_loud([32767, -32768] * 240) is True

    def test_quiet_frame_below_default_threshold_is_not_loud(self):
        # A very quiet frame should sit below the -45 dBFS default gate.
        quiet = [3, -3] * 240
        assert samples_dbfs(quiet) < DEFAULT_ENERGY_GATE_DBFS
        assert is_audio_frame_loud(quiet) is False

    def test_custom_threshold_is_respected(self):
        moderate = [3000, -3000] * 240
        assert is_audio_frame_loud(moderate, threshold_dbfs=-6.0) is False
        assert is_audio_frame_loud(moderate, threshold_dbfs=-30.0) is True


class TestSampleWithToolCall:
    def test_no_tool_names_returns_sample_unchanged(self):
        sample = _sample("tool_call", speech_end=0.0, first_audio=1.0)
        assert sample_with_tool_call(sample, tool_names=[]) == sample

    def test_records_tool_call_true_and_names_in_notes(self):
        sample = _sample("tool_call", speech_end=0.0, first_audio=1.0)
        updated = sample_with_tool_call(sample, tool_names=["space_list"])

        assert updated.tool_call is True
        assert "space_list" in updated.notes
        # Original is untouched -- LatencySample is frozen, this must be a copy.
        assert sample.tool_call is False

    def test_deduplicates_repeated_tool_names_preserving_order(self):
        sample = _sample("tool_call", speech_end=0.0, first_audio=1.0)
        updated = sample_with_tool_call(
            sample, tool_names=["space_list", "space_list", "post_to_meeting_chat"]
        )

        assert updated.notes == "tool_call: space_list, post_to_meeting_chat"

    def test_includes_latency_when_given(self):
        sample = _sample("tool_call", speech_end=0.0, first_audio=1.0)
        updated = sample_with_tool_call(
            sample, tool_names=["space_list"], first_call_latency_ms=2984.0
        )

        assert "2984.0 ms" in updated.notes


class TestFormatReport:
    def test_report_contains_the_measured_number(self):
        report = aggregate_samples([_sample("simple_latency", speech_end=0.0, first_audio=0.15)])

        text = format_report(report)

        assert "150.0 ms" in text

    def test_report_cites_the_reference_date_and_not_an_invented_target(self):
        report = aggregate_samples([_sample("simple_latency", speech_end=0.0, first_audio=0.15)])

        text = format_report(report)

        assert REFERENCE_TARGET_DATE in text
        assert "Brosnan" in text

    def test_report_never_asserts_pass_or_fail(self):
        """This stage reports the measured number as reference against
        Brosnan's target; it must not invent or assert an independent
        pass/fail verdict. Guard that property directly so a future edit to
        format_report can't reintroduce it silently."""
        fast = aggregate_samples([_sample("simple_latency", speech_end=0.0, first_audio=0.01)])
        slow = aggregate_samples([_sample("simple_latency", speech_end=0.0, first_audio=5.0)])

        for report in (fast, slow):
            text = format_report(report).lower()
            assert "pass" not in text
            assert "fail" not in text
