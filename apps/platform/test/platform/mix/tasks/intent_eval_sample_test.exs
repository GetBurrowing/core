defmodule Mix.Tasks.Platform.IntentEval.SampleTest do
  @moduledoc """
  The sampler for the labelling set (task `01a03fbb` stage 2).

  ## Every assertion here is built to be capable of failing

  * **Determinism** is measured by running the sampler TWICE and comparing
    the two rendered bodies. Comparing one run to itself, or asserting the
    function merely returns rows, would pass against a sampler that shuffled
    freshly on every call.
  * **Caps** are measured against a fixture that WOULD violate them. The
    chatty transcript below carries 40 segments and `Alex` speaks 40 of the
    fixture's 58 — with the caps removed the run would take far more than 8
    from that transcript, and Alex would be the overwhelming majority of the
    set. The pre-cap counts are asserted directly so the fixture cannot
    silently drift into a shape that could never violate anything.
  * **Redaction** asserts BOTH the absence of the secret literal and the
    presence of the placeholder. Absence alone passes if the row was simply
    dropped.
  """

  use Platform.DataCase, async: false

  alias Mix.Tasks.Platform.IntentEval.Sample
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  # Small, so the fixture's own shape — not the default 400 — decides what
  # the caps do.
  @limit 20
  @per_transcript 8
  @speaker_share 0.15

  defp opts(overrides \\ []) do
    Sample.normalize_opts(
      Keyword.merge(
        [
          limit: @limit,
          seed: 20_260_827,
          per_transcript: @per_transcript,
          speaker_share: @speaker_share
        ],
        overrides
      )
    )
  end

  defp insert_transcript(room_id, segments) do
    %Transcript{}
    |> Transcript.changeset(%{
      room_id: room_id,
      segments: segments,
      status: "complete"
    })
    |> Repo.insert!()
  end

  defp segment(speaker, text, ms) do
    %{"speaker_name" => speaker, "text" => text, "start_time" => ms}
  end

  # A "chatty standup": one transcript, one speaker, 40 segments. Both caps
  # are violated by this fixture if either is not enforced.
  defp chatty_fixture do
    segments =
      for i <- 1..40 do
        segment("Alex", "standup line number #{i}, and then some more words", i * 1000)
      end

    insert_transcript("room-chatty", segments)
  end

  # A transcript that is long but NOT single-speaker: 40 segments, 40
  # distinct speakers. Only the per-transcript cap can limit this one — the
  # speaker cap never binds, so a test that uses it isolates the transcript
  # cap instead of passing on the speaker cap's behalf.
  defp many_voiced_fixture do
    segments =
      for i <- 1..40 do
        segment("voice-#{i}", "a long meeting line number #{i} about the plan", i * 1000)
      end

    insert_transcript("room-many-voices", segments)
  end

  # Eighteen other segments spread over six speakers and three transcripts,
  # so there is somewhere else for the selection to go once the caps bite.
  defp varied_fixture do
    for t <- 1..3 do
      segments =
        for i <- 1..6 do
          segment("speaker-#{t}-#{i}", "a varied utterance #{t}/#{i} about the roadmap", i * 500)
        end

      insert_transcript("room-varied-#{t}", segments)
    end
  end

  describe "determinism" do
    test "two separate invocations produce byte-identical output" do
      chatty_fixture()
      varied_fixture()

      o = opts()

      first = Sample.render(Sample.sample_rows(o), o)

      # Deliberately disturb the process-global `:rand` state between the
      # runs. A sampler that leaned on ambient randomness rather than
      # re-seeding from `--seed` would diverge here.
      :rand.seed(:exsss, {1, 2, 3})
      _ = Enum.shuffle(1..100)

      second = Sample.render(Sample.sample_rows(o), o)

      assert first == second
      refute first == ""
    end

    test "a different seed produces a different selection" do
      chatty_fixture()
      varied_fixture()

      a = Sample.sample_rows(opts(seed: 1))
      b = Sample.sample_rows(opts(seed: 999_983))

      assert Enum.map(a, & &1["id"]) != Enum.map(b, & &1["id"]),
             "both seeds returned the same order — the seed is not reaching :rand"
    end

    test "the header line records the seed" do
      chatty_fixture()

      o = opts(seed: 4242)

      [header_line | _] =
        Sample.render(Sample.sample_rows(o), o) |> String.split("\n", trim: true)

      header = Jason.decode!(header_line)

      assert header["header"] == true
      assert header["seed"] == 4242
      assert header["per_transcript"] == @per_transcript
    end
  end

  describe "stratification caps" do
    test "no more than per_transcript rows come from one transcript" do
      many = many_voiced_fixture()
      varied_fixture()

      # Pre-cap: this transcript contributes 40 of the 58 candidates, and
      # every one of its segments has a DIFFERENT speaker, so the speaker
      # cap never binds here. Uncapped, a limit-20 run would draw ~14 of
      # them and could legally draw all 20; only the per-transcript cap
      # holds it to 8. The companion test below shows the uncapped draw.
      assert length(many.segments) == 40
      assert many.segments |> Enum.map(& &1["speaker_name"]) |> Enum.uniq() |> length() == 40

      rows = Sample.sample_rows(opts())

      counts =
        rows |> Enum.group_by(& &1["transcript_id"]) |> Map.new(fn {k, v} -> {k, length(v)} end)

      assert Map.get(counts, many.id, 0) <= @per_transcript
      assert Enum.all?(Map.values(counts), &(&1 <= @per_transcript))
    end

    test "no speaker exceeds speaker_share of the emitted set" do
      chatty_fixture()
      varied_fixture()

      # Pre-cap: "Alex" owns 40 of 58 candidates (69%), far above the 15%
      # share. The cap for limit 20 is ceil(20 * 0.15) = 3.
      cap = ceil(@limit * @speaker_share)
      assert cap == 3

      rows = Sample.sample_rows(opts())

      alex_rows = Enum.count(rows, &(&1["speaker"] == "Alex"))

      assert alex_rows <= cap,
             "Alex took #{alex_rows} of #{length(rows)} rows; cap is #{cap}"
    end

    test "the caps are what limit the long transcript, not the candidate supply" do
      many = many_voiced_fixture()
      varied_fixture()

      # With the per-transcript cap raised above the fixture size and the
      # speaker share opened up, the same seed DOES pull far more than the
      # capped run — which is what makes the two assertions above real.
      uncapped =
        Sample.sample_rows(opts(per_transcript: 1_000, speaker_share: 1.0))

      uncapped_many = Enum.count(uncapped, &(&1["transcript_id"] == many.id))

      assert uncapped_many > @per_transcript,
             "uncapped run drew only #{uncapped_many} from the long transcript — " <>
               "the cap assertions above would pass vacuously"
    end
  end

  describe "redaction" do
    test "an account id and an ARN do not survive into the output row" do
      insert_transcript("room-secrets", [
        segment(
          "Alex",
          "the account is 123456789012 and the role is arn:aws:iam::123456789012:role/orion-apply",
          1000
        )
      ])

      rows = Sample.sample_rows(opts())

      row = Enum.find(rows, &(&1["room_id"] == "room-secrets"))
      assert row, "the secret-bearing segment was dropped, so this test proves nothing"

      text = row["text"]

      refute text =~ "123456789012"
      refute text =~ "arn:aws:iam::"

      assert text =~ "<account-id>"
      assert text =~ "<redacted>"

      # And it does not survive the serialized body either.
      body = Sample.render(rows, opts())
      refute body =~ "123456789012"
      refute body =~ "arn:aws:iam::"
    end

    test "prior context is carried and is scrubbed too" do
      insert_transcript("room-prior", [
        segment("Alex", "my key is AKIAIOSFODNN7EXAMPLE by the way", 1000),
        segment("Alex", "second line", 2000),
        segment("Alex", "third line", 3000),
        segment("Alex", "fourth line", 4000)
      ])

      # Speaker share opened up: all four lines are Alex's, and the point of
      # this test is the `prior` window, not the cap.
      rows = Sample.sample_rows(opts(speaker_share: 1.0))

      fourth = Enum.find(rows, &(&1["text"] == "fourth line"))
      assert fourth, "the fourth segment was not selected"

      assert length(fourth["prior"]) == 3
      assert Enum.map(fourth["prior"], & &1["text"]) |> List.first() =~ "<redacted>"
      refute Enum.any?(fourth["prior"], &(&1["text"] =~ "AKIAIOSFODNN7EXAMPLE"))
    end

    test "scrub/1 leaves ordinary speech alone" do
      text = "So I think we should ship the 2026 roadmap by Friday, maybe 30 items."
      assert Sample.scrub(text) == text
    end
  end

  describe "row shape" do
    test "every row carries the archive origin and the full key set" do
      varied_fixture()

      [row | _] = Sample.sample_rows(opts())

      assert row["origin"] == "archive"

      for key <- ~w(id text speaker room_id timestamp_ms transcript_id prior) do
        assert Map.has_key?(row, key), "row is missing #{key}"
      end

      assert String.length(row["id"]) == 16
      assert row["id"] =~ ~r/^[0-9a-f]{16}$/
    end
  end
end
