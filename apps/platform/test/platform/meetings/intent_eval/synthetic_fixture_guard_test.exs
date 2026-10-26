defmodule Platform.Meetings.IntentEval.SyntheticFixtureGuardTest do
  @moduledoc """
  The intent-eval fixtures must carry no production identity.

  `negatives_102` was normalised from recorded producer removals: real
  utterances from real meetings. The pre-public scrub replaced all 102 rows
  with synthetic stand-ins and re-keyed every cassette entry for them, so the
  set stays reproducible offline without shipping anyone's speech. This file
  keeps it that way.

  Scanned: every TRACKED file under `priv/intent_eval/{slices,cassettes,runs,
  exemplars}` and the `test/support/fixtures/intent_classify_*.jsonl`
  originals. Three checks:

    * no full UUID. Meeting, segment, participant and task ids in this
      system are UUIDv7 (`01a0…-…-7…`); the old slice headers carried one, a
      task id in `source_branch`. A 16-hex row id is a digest of the row's own
      text and is not matched.
    * no speaker or meeting identity field (`speaker`, `speaker_id`,
      `participant_identity`, `meeting_id`, `segment_id`, `room_name`,
      `author_id`) and no diarisation label (`SPEAKER_00`, `Speaker 2:`).
    * every `negatives_102` row is `origin: "synthetic"`, and the
      test/support fixture it is paired with holds the same texts in the same
      order, so neither copy can quietly go back to recorded speech.

  Measured on the tree before the scrub: the UUID check named all five slice
  headers and the exemplar header, and the origin check named all 102
  negatives rows (`curated`). The field and label checks found nothing there:
  the recorded data never carried speaker or meeting ids, only its text.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../../..", __DIR__)

  @scanned_dirs ~w(priv/intent_eval/slices priv/intent_eval/cassettes priv/intent_eval/runs priv/intent_eval/exemplars)
  @fixture_glob "test/support/fixtures/intent_classify_*.jsonl"

  @uuid ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
  @identity_key ~r/"(speaker|speaker_id|speaker_label|participant_identity|meeting_id|segment_id|segment_ids|room_name|author_id)"\s*:/
  @diarisation ~r/\bSPEAKER_\d+\b|\bSpeaker \d+\s*:/

  defp tracked_files do
    args = ["-c", "safe.directory=*", "-C", @app_root, "ls-files", "-z", "--"] ++ @scanned_dirs

    {out, 0} = System.cmd("git", args)
    tracked = out |> String.split(<<0>>, trim: true)

    fixtures =
      @app_root
      |> Path.join(@fixture_glob)
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @app_root))

    Enum.sort(tracked ++ fixtures)
  end

  @doc false
  def problems(root, rels) do
    for rel <- rels,
        body = File.read!(Path.join(root, rel)),
        {label, re} <- [uuid: @uuid, identity_field: @identity_key, diarisation: @diarisation],
        match <- Regex.scan(re, body) |> Enum.map(&hd/1) |> Enum.uniq(),
        do: "#{rel}: #{label} #{inspect(match)}"
  end

  defp jsonl_rows(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "the scanned set is the real one" do
    files = tracked_files()

    assert "priv/intent_eval/slices/negatives_102.jsonl" in files
    assert "test/support/fixtures/intent_classify_negatives.jsonl" in files
    assert Enum.count(files, &String.starts_with?(&1, "priv/intent_eval/cassettes/")) >= 6
    assert Enum.count(files, &String.starts_with?(&1, "priv/intent_eval/runs/")) >= 6
  end

  test "no fixture carries a production-style id, identity field or speaker label" do
    assert problems(@app_root, tracked_files()) == []
  end

  test "negatives_102 is synthetic, row for row, in both copies" do
    [header | rows] =
      jsonl_rows(Path.join(@app_root, "priv/intent_eval/slices/negatives_102.jsonl"))

    assert header["header"] == true
    assert length(rows) == 102

    not_synthetic = for row <- rows, row["origin"] != "synthetic", do: row["id"]
    assert not_synthetic == []

    fixture =
      jsonl_rows(Path.join(@app_root, "test/support/fixtures/intent_classify_negatives.jsonl"))

    assert Enum.map(fixture, & &1["text"]) == Enum.map(rows, & &1["text"])
    assert Enum.map(fixture, & &1["reason"]) == Enum.map(rows, & &1["source_reason"])
  end

  @tag :tmp_dir
  test "POSITIVE CONTROL: each check names a planted id", %{tmp_dir: dir} do
    # Invented values in the production shapes. Without this the guard could
    # be green because its patterns match nothing at all.
    planted = [
      ~s({"header":true,"source_branch":"task/0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000"}),
      ~s({"text":"hello","meeting_id":"m-1"}),
      ~s({"text":"SPEAKER_01: hello"})
    ]

    File.write!(Path.join(dir, "planted.jsonl"), Enum.join(planted, "\n") <> "\n")
    found = problems(dir, ["planted.jsonl"])

    assert Enum.any?(found, &(&1 =~ "uuid"))
    assert Enum.any?(found, &(&1 =~ "identity_field"))
    assert Enum.any?(found, &(&1 =~ "diarisation"))

    # And a 16-hex row id, the digest every slice row carries, is not a hit.
    File.write!(Path.join(dir, "clean.jsonl"), ~s({"id":"4bee1ac9b34c5f65","text":"hi"}\n))
    assert problems(dir, ["clean.jsonl"]) == []
  end
end
