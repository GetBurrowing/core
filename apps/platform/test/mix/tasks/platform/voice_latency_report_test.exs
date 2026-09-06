defmodule Mix.Tasks.Platform.VoiceLatencyReportTest do
  @moduledoc """
  Tests for the meeting-voice latency report (task 01a07400 stage 3).

  Async: false. The report reads every matching `audit_events` row and prints
  exact `n` values, and `Mix.shell/0` is process-global.

  ## What these tests are actually defending

  The centre of this file is the 19-vs-20 boundary, and it is asserted on the
  ABSENCE OF A SPECIFIC TOKEN — no `p50=` in the measure's own section — rather
  than on some looser property of the output. A looser assertion ("the output
  mentions the sample size", "the output is short") would also hold if the
  report crashed, printed nothing, or skipped the measure entirely, which
  would make it green for the wrong reason. Every refusal test here is paired
  with a positive control whose percentiles are PREDICTED FROM THE SEEDED DATA
  by hand, so a report that silently stopped printing percentiles could not
  pass the file.

  That is only possible because the task never prints the token `p50` except on
  a line reporting one: not in its header, not in its legend. If a later edit
  puts a percentile name into fixed prose, these assertions go quietly weak,
  and `the report never names a percentile outside a stats line` is here to
  catch exactly that.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.VoiceLatencyReport
  alias Platform.Audit
  alias Platform.Audit.Event
  alias Platform.Meetings.SayTelemetry
  alias Platform.Meetings.TranscriptTelemetry
  alias Platform.Repo

  # Derived from the emitting modules, never restated as literals: if stage 1
  # or stage 2 renames an event, this file must fail rather than quietly stop
  # measuring anything.
  @responded Enum.map_join(TranscriptTelemetry.responded_event(), ".", &Atom.to_string/1)
  @ack Enum.map_join(SayTelemetry.ack_event(), ".", &Atom.to_string/1)
  @delivered Enum.map_join(TranscriptTelemetry.delivered_event(), ".", &Atom.to_string/1)

  @min VoiceLatencyReport.min_sample()

  describe "the refusal boundary" do
    test "at n = min_sample - 1 the percentiles are SUPPRESSED, not warned about" do
      seed_responded(1..(@min - 1))

      output = run()
      measure = section(output, 1)

      # The assertion that is the whole point: no percentile token for this
      # measure. Not "a warning appears" — the numbers must be absent.
      refute measure =~ "p50"
      refute measure =~ "p90"
      refute measure =~ "p99"

      # And it said why, with the size, and showed the raw sample instead.
      assert measure =~ "sample too small: n=#{@min - 1}, need #{@min}"
      assert measure =~ "raw values: 1, 2, 3,"
      assert measure =~ ", 18, 19"
    end

    test "at n = min_sample the percentiles print, with values predicted from the seed" do
      seed_responded(1..@min)

      measure = section(run(), 1)

      # Nearest rank over 1..20: p50 is the 10th value, p90 the 18th, p99 the
      # 20th. Every number here was worked out from the seed by hand, so this
      # cannot pass against a report that computes something else.
      assert measure =~ "n=20  p50=10  p90=18  p99=20  min=1  max=20"
      refute measure =~ "sample too small"
    end

    test "one observation below the line is still a refusal, not a rounding" do
      seed_responded(1..1)

      measure = section(run(), 1)

      refute measure =~ "p50"
      assert measure =~ "sample too small: n=1, need #{@min}"
      assert measure =~ "raw values: 1"
    end
  end

  describe "the refusal is per measure, never global" do
    test "a rich measure reports while a thin one refuses, in the same output" do
      seed_responded(1..@min)
      seed_acks("spoken", 1..6)

      output = run()

      assert section(output, 1) =~ "n=20  p50=10"
      refute section(output, 1) =~ "sample too small"

      assert section(output, 2) =~ "sample too small: n=6, need #{@min}"
      refute section(output, 2) =~ "p50"
    end

    test "within measure 2 the rule applies per ack status" do
      seed_acks("spoken", 1..@min)
      seed_acks("failed", 101..106)

      measure = section(run(), 2)

      spoken = status_block(measure, "spoken")
      failed = status_block(measure, "failed")

      assert spoken =~ "n=20  p50=10  p90=18  p99=20  min=1  max=20"
      refute spoken =~ "sample too small"

      refute failed =~ "p50"
      assert failed =~ "sample too small: n=6, need #{@min}"
      assert failed =~ "raw values: 101, 102, 103, 104, 105, 106"
    end

    test "status is the literal string the runtime sent, not a re-derivation" do
      seed_acks("wandered off", 1..3)

      measure = section(run(), 2)

      assert measure =~ ~s(status "wandered off")
      refute measure =~ ~s(status "spoken")
    end
  end

  describe "the two kinds of empty" do
    test "a measure with a sink and no rows says NO EVENTS RECORDED" do
      measure = section(run(), 1)

      assert measure =~ "NO EVENTS RECORDED"
      refute measure =~ "NO SINK"
    end

    test "measure 3 says NO SINK and names the unregistered event" do
      measure = section(run(), 3)

      assert measure =~ "NO SINK"
      assert measure =~ @delivered
      assert measure =~ "not registered in"
      refute measure =~ "NO EVENTS RECORDED"
    end

    test "the two sentences appear in ONE output, so they cannot be conflated" do
      output = run()

      assert section(output, 1) =~ "NO EVENTS RECORDED"
      assert section(output, 3) =~ "NO SINK"
    end

    test "measure 3 is not hardcoded as unsourced — rows, if any existed, would report" do
      # The NO SINK branch is reached because the event carries no rows, not
      # because the measure is special-cased. Seeding rows under that event
      # type makes it report a distribution like any other, which is what
      # makes this report survive the day someone wires a sink for it.
      seed(@delivered, Enum.map(1..@min, &%{"lag_ms" => &1}))

      measure = section(run(), 3)

      assert measure =~ "n=20  p50=10  p90=18  p99=20  min=1  max=20"
      refute measure =~ "NO SINK"
    end

    test "an entirely empty database reports it once and returns :ok" do
      output = capture_io(fn -> assert VoiceLatencyReport.run([]) == :ok end)

      assert output =~ "NO EVENTS"
      refute output =~ "p50"
    end
  end

  describe "measure 4 — paired ack latency against audio duration" do
    test "prints the pairs, with the excess over the audio length" do
      seed_pairs(1..@min)

      measure = section(run(), 4)

      assert measure =~ "AUDIO_S"
      assert measure =~ "ACK_MS"
      assert measure =~ "EXCESS_MS"

      # The shortest clip: 0.1 s of audio, 1070 ms to ack, so 970 ms of the
      # wait was not the audio. The longest: 2.0 s of audio acked in 1000 ms,
      # which is NEGATIVE excess — the runtime acked before the audio would
      # have finished playing. Both are asserted exactly, and both partners
      # come from the row they were seeded on.
      assert measure =~ ~r/^\s+0\.100\s+1070\s+970$/m
      assert measure =~ ~r/^\s+2\.000\s+1000\s+-1000$/m
    end

    test "pairs are matched per row, not two independently sorted columns" do
      seed_pairs(1..@min)

      measure = section(run(), 4)

      # Sorting the two columns separately would put the smallest latency
      # against the shortest clip and print 0.100 / 1000 / 900. The seeded row
      # says 1070, and the third value is arithmetic on the pair, so a report
      # that lost the row association cannot produce this line.
      assert measure =~ ~r/^\s+0\.100\s+1070\s+970$/m
      refute measure =~ ~r/^\s+0\.100\s+1000\s+900$/m

      # Mid-sample, where an off-by-one in the association would also land.
      assert measure =~ ~r/^\s+0\.300\s+1010\s+710$/m
    end

    test "both columns get their own stats line, predicted from the seed" do
      seed_pairs(1..@min)

      measure = section(run(), 4)

      assert measure =~ ~r/^\s+ack_ms\s+n=20  p50=1090  p90=1170  p99=1190  min=1000  max=1190$/m

      assert measure =~
               ~r/^\s+audio_s\s+n=20  p50=1\.000  p90=1\.800  p99=2\.000  min=0\.100  max=2\.000$/m
    end

    test "a thin pair sample refuses percentiles but still shows every pair" do
      seed_pairs(1..6)

      measure = section(run(), 4)

      refute measure =~ "p50"
      assert measure =~ "sample too small: n=6, need #{@min}"
      assert measure =~ "the pairs below ARE the raw values."
      assert measure =~ ~r/^\s+0\.100\s+1070\s+970$/m
      assert measure =~ ~r/^\s+0\.600\s+1020\s+420$/m
    end

    test "acks with no reported duration count in measure 2 but cannot be paired" do
      seed_acks("spoken", 1..5)

      output = run()

      assert section(output, 2) =~ "n=5"
      assert section(output, 4) =~ "n=0"
      assert section(output, 4) =~ "none carrying BOTH latency_ms and"
    end

    test "the pair list is capped and the cap announces itself" do
      seed_pairs(1..@min)

      measure =
        capture_io(fn -> VoiceLatencyReport.report(max_pairs: 5) end)
        |> section(4)

      assert measure =~ "further pair(s) not shown"
      assert measure =~ "--max-pairs 5"
      assert measure =~ ~r/^\s+0\.500\s+1150\s+650$/m
      refute measure =~ ~r/^\s+0\.600\s+1020\s+420$/m
    end
  end

  describe "the report's own claims about itself" do
    test "measure 1 carries its proxy label on the same screen as its numbers" do
      seed_responded(1..@min)

      measure = section(run(), 1)

      # The caveat travels WITH the distribution. A reader who scrolls to the
      # percentiles and stops reading has still been told what they are: the
      # label sits in measure 1's own block, not in a preamble or a docstring
      # that the number can be quoted away from.
      assert measure =~ "PROXY"
      assert measure =~ "not a first-token time"
      assert measure =~ "n=20  p50=10"

      # Core observes a federated agent's ACTIONS, never its tokens, and the
      # report says so where the number is.
      assert measure =~ "never"
      assert measure =~ "its tokens"
    end

    test "the report never claims to measure time to first token" do
      # Core observes a federated agent's ACTIONS, never its tokens, so no
      # surface here may name the quantity it cannot measure.
      #
      # This is a different property from the proxy-label test above, and both
      # are needed. That one checks the caveat is PRESENT; this one checks the
      # false claim is ABSENT. A `ttft:` column heading added tomorrow would
      # disturb neither the PROXY label nor the disclaimer prose, and only a
      # refutation catches it.
      #
      # Both shapes of the report are swept, because a heading can only be
      # introduced on a line one of them renders: the empty run prints every
      # no-data sentence, the populated run every stats, refusal and pair line.
      refute String.downcase(run()) =~ "ttft"

      seed_responded(1..@min)
      seed_acks("failed", 101..106)
      seed_pairs(1..@min)
      seed(@delivered, Enum.map(1..@min, &%{"lag_ms" => &1}))

      populated = run()

      # The refutation would also pass against a report that printed nothing,
      # so pin one line from each branch first. Without these three the guard
      # above is vacuous.
      assert populated =~ "n=20  p50=10"
      assert populated =~ "sample too small: n=6"
      assert populated =~ "EXCESS_MS"

      refute String.downcase(populated) =~ "ttft"
    end

    test "the report never names a percentile outside a stats line" do
      # Guards the refusal assertions in this file: they work by the absence of
      # `p50`, so fixed prose must never contain it. With an empty database
      # there is no stats line anywhere, so a single hit is a regression.
      output = run()

      refute output =~ "p50"
      refute output =~ "p90"
      refute output =~ "p99"
    end

    test "names its percentile method, so the convention is not left to guess" do
      assert run() =~ "nearest rank"
    end
  end

  describe "the window" do
    test "--days excludes rows recorded before it" do
      seed_responded(1..@min)
      backdate_all(10)
      seed_responded(500..(500 + @min - 1))

      measure =
        capture_io(fn -> VoiceLatencyReport.report(days: 1) end)
        |> section(1)

      assert measure =~ "min=500  max=519"

      # Without the window both cohorts are in scope, which is what proves the
      # filter removed rows rather than the seed never landing.
      assert section(run(), 1) =~ "min=1  max=519"
    end
  end

  # -- Helpers --

  defp run, do: capture_io(fn -> VoiceLatencyReport.report() end)

  defp section(output, number) do
    output
    |> String.split(~r/^MEASURE /m)
    |> Enum.find("", &String.starts_with?(&1, "#{number} —"))
  end

  defp status_block(measure_2, status) do
    measure_2
    |> String.split(~r/^  status /m)
    |> Enum.find("", &String.starts_with?(&1, ~s("#{status}")))
  end

  defp seed_responded(range) do
    seed(@responded, Enum.map(range, &%{"response_ms" => &1}))
  end

  defp seed_acks(status, range) do
    seed(@ack, Enum.map(range, &%{"latency_ms" => &1, "status" => status}))
  end

  # duration_s climbs 0.1 s at a time, but the ack latency deliberately does
  # NOT climb with it: `rem(i * 7, 20)` walks a permutation of 0..19, so the
  # two columns are a genuine pairing rather than two copies of the same
  # ordering.
  #
  # That matters more than it looks. The obvious seed — latency rising in step
  # with duration — cannot tell a correct report from one that sorts the two
  # columns independently and prints them side by side, because both produce
  # the identical table. Under this seed a mispairing changes every excess
  # value, and `pairs are matched per row` fails when it should.
  defp seed_pairs(range) do
    seed(
      @ack,
      Enum.map(range, fn i ->
        %{
          "latency_ms" => 1000 + rem(i * 7, 20) * 10,
          "duration_s" => i / 10,
          "status" => "spoken"
        }
      end)
    )
  end

  defp seed(event_type, metadatas) do
    Enum.each(metadatas, fn metadata ->
      {:ok, _event} =
        Audit.record(%{
          event_type: event_type,
          actor_type: "agent",
          action: "measured",
          resource_type: "meeting_utterance",
          metadata: metadata
        })
    end)
  end

  defp backdate_all(days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Repo.update_all(Event, set: [inserted_at: at])
  end
end
