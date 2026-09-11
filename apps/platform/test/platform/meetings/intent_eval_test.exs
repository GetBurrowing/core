defmodule Platform.Meetings.IntentEvalTest do
  @moduledoc """
  Coverage for the labelled evaluation set and its adjudication round-trip
  (task `01a03fbb` stage 3).

  Every refusal here is paired with a POSITIVE CONTROL. A test that only
  asserts "self-adjudication is refused" is passed by an implementation that
  refuses every ingest, and a test that only asserts "the manifest stays false
  while a row is blank" is passed by one that never flips it at all. Each pair
  shows the check discriminating, not merely firing.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentEval

  @strong "strong-labeller"
  @human "rowan"

  # ── the shipped set ───────────────────────────────────────────────────

  describe "the committed priv set" do
    test "every slice file matches the sha256 recorded in the manifest" do
      assert :ok = IntentEval.verify_slices(IntentEval.root())
    end

    test "editing a slice without regenerating the manifest is caught" do
      # The digest test above proves nothing unless it can go red. Copy the
      # real set into a temp root, flip ONE byte of one labelled row, and show
      # the same call that just passed now names the slice that drifted.
      root = copy_real_set!()
      assert :ok = IntentEval.verify_slices(root)

      path = IntentEval.slice_path(root, "control_60")
      File.write!(path, File.read!(path) <> "\n")

      assert {:error, {:digest_mismatch, ["control_60"]}} = IntentEval.verify_slices(root)

      # ... and refreshing the manifest is the sanctioned way back to green.
      IntentEval.refresh_digests!(root)
      assert :ok = IntentEval.verify_slices(root)
    end

    test "the seed slices and the delegation probe are present, normalised, and carry their provenance" do
      root = IntentEval.root()
      manifest = IntentEval.read_manifest!(root)

      assert [
               "control_60",
               "delegation_probe",
               "negatives_102",
               "unaddressed_meeting_speech_48",
               "unaddressed_probe_12"
             ] = manifest["slices"] |> Enum.map(& &1["name"]) |> Enum.sort()

      rows = IntentEval.load_slice_rows(root)
      by_slice = rows |> Map.values() |> Enum.group_by(& &1["slice"])

      assert length(by_slice["negatives_102"]) == 102
      assert length(by_slice["control_60"]) == 60
      assert length(by_slice["unaddressed_probe_12"]) == 12
      assert length(by_slice["unaddressed_meeting_speech_48"]) == 48

      # Task 01a05997 stage 4. Not a seed slice and not normalised from a
      # fixture: authored to show the roster-grounded prompt discriminating.
      assert length(by_slice["delegation_probe"]) == 9

      # Every negative is the same label — they are recorded
      # `removed_no_action` corrections, i.e. things the classifier should
      # never have fired on.
      assert Enum.all?(by_slice["negatives_102"], &(&1["label"] == "off_topic"))
      # The fixture's recorded reasons are wider than the two the ticket named
      # (`other` and `not_actionable` also appear); the normalisation carries
      # whatever was recorded rather than collapsing it.
      assert by_slice["negatives_102"]
             |> Enum.map(& &1["source_reason"])
             |> Enum.uniq()
             |> Enum.sort() == ~w(not_actionable other wrong_intent wrong_target)

      # Control and probe carry real intents, not the negative label.
      refute Enum.any?(by_slice["control_60"], &(&1["label"] == "off_topic"))
      refute Enum.any?(by_slice["unaddressed_probe_12"], &(&1["label"] == "off_topic"))

      # `delegation_probe` is the one slice that carries BOTH labels on
      # purpose: its positives and its negatives are minimal pairs that
      # differ only in whether the addressed name is on the roster, so a
      # slice of one label could not measure the distinction at all.
      assert by_slice["delegation_probe"]
             |> Enum.map(& &1["label"])
             |> Enum.frequencies() == %{"off_topic" => 7, "open_question" => 2}

      # Common schema across all three, so scoring never branches on slice.
      for row <- Map.values(rows) do
        assert is_binary(row["id"]) and byte_size(row["id"]) == 16
        assert is_binary(row["text"]) and row["text"] != ""
        assert is_binary(row["label"])
        assert is_list(row["prior"])
      end

      # The test/support originals are deliberately retained for the sibling
      # branch; the manifest has to say which copy is canonical.
      provenance = manifest["provenance"]["duplicated_from"]
      assert provenance["canonical"] =~ "priv/intent_eval"
      assert length(provenance["pairs"]) == 3

      for pair <- provenance["pairs"] do
        assert File.exists?(Path.join(root, pair["priv"]))
      end
    end
  end

  # ── open set ──────────────────────────────────────────────────────────

  describe "emit_open/2" do
    test "emits only disagreements and low-confidence rows" do
      root = build_set!()

      {:ok, path, count} = IntentEval.emit_open(root)

      assert count == 2

      [header | rows] =
        path |> File.read!() |> NimbleCSV.RFC4180.parse_string(skip_headers: false)

      assert header == IntentEval.open_columns()
      assert rows |> Enum.map(&hd/1) |> Enum.sort() == ["id-disagree", "id-unsure"]

      # The human's two columns arrive blank — this is their work queue.
      for row <- rows, do: assert(Enum.take(row, -2) == ["", ""])

      # The confident agreement never reaches a person.
      refute Enum.any?(rows, &(hd(&1) == "id-agree"))
    end
  end

  # ── round trip ────────────────────────────────────────────────────────

  describe "ingest/4" do
    test "a filled CSV round-trips and flips the manifest to adjudicated" do
      root = build_set!()
      {:ok, path, 2} = IntentEval.emit_open(root)

      filled = fill(path, %{"id-disagree" => "off_topic", "id-unsure" => "action_items"})

      assert {:ok, summary} = IntentEval.ingest(root, filled, @human)
      assert summary.merged == 2
      assert summary.outstanding == 0
      assert summary.adjudicated

      assert IntentEval.read_manifest!(root)["adjudicated"] == true

      adjudicated = IntentEval.read_adjudicated(root)
      assert adjudicated["id-disagree"]["human_label"] == "off_topic"
      assert adjudicated["id-disagree"]["adjudicated_by"] == @human
      assert {:ok, _, _} = DateTime.from_iso8601(adjudicated["id-disagree"]["adjudicated_at"])
      # The model's opinion is retained next to the human's, so a later reader
      # can measure how often the pre-labeller was wrong.
      assert adjudicated["id-disagree"]["model_label"] == "action_items"
      assert adjudicated["id-disagree"]["prelabel_agent"] == @strong
    end

    test "a partially filled CSV is REFUSED and writes nothing, and a complete one succeeds" do
      # CONTRACT CHANGED, task `01a03fbb` stage 6. This test previously
      # asserted the shipped behaviour: a partial CSV merged its filled rows
      # and only left `manifest["adjudicated"]` false. That was deliberate,
      # not accidental — the assertion is REPLACED rather than deleted so the
      # record shows the old contract existed on purpose. It is now
      # all-or-nothing, because the sibling self-adjudication refusal writes
      # nothing at all and two refusals obeying two contracts is the
      # inconsistency that bites someone at 2am. The CSV is the human's own
      # file on disk, so refusing costs them nothing.
      root = build_set!()
      {:ok, path, 2} = IntentEval.emit_open(root)

      partial = fill(path, %{"id-disagree" => "off_topic"})

      assert {:error, {:incomplete, ["id-unsure"]}} = IntentEval.ingest(root, partial, @human)

      # Nothing on disk changed — same contract as the self-adjudication path.
      refute File.exists?(IntentEval.adjudicated_path(root))
      manifest = IntentEval.read_manifest!(root)
      assert manifest["adjudicated"] == false
      refute Map.has_key?(manifest, "adjudication")

      # Positive control: the ONLY difference is that the second row now
      # carries a label. Without this, an implementation that refused every
      # ingest would pass the assertion above.
      complete = fill(path, %{"id-disagree" => "off_topic", "id-unsure" => "action_items"})

      assert {:ok, second} = IntentEval.ingest(root, complete, @human)
      assert second.merged == 2
      assert second.outstanding == 0
      assert second.adjudicated
      assert IntentEval.read_manifest!(root)["adjudicated"] == true
      assert IntentEval.read_manifest!(root)["adjudication"]["outstanding"] == []
    end

    test "refuses an agent adjudicating its own pre-labels, and allows a different identity" do
      root = build_set!()
      {:ok, path, 2} = IntentEval.emit_open(root)
      filled = fill(path, %{"id-disagree" => "off_topic", "id-unsure" => "action_items"})

      assert {:error, {:self_adjudication, @strong, ids}} =
               IntentEval.ingest(root, filled, @strong)

      assert ids == ["id-disagree", "id-unsure"]

      # Nothing was written — a refused ingest must not half-apply.
      refute File.exists?(IntentEval.adjudicated_path(root))
      assert IntentEval.read_manifest!(root)["adjudicated"] == false

      # Positive control: the identical file under a DIFFERENT identity
      # succeeds. Without this an implementation that refuses every ingest
      # would pass.
      assert {:ok, summary} = IntentEval.ingest(root, filled, @human)
      assert summary.merged == 2
      assert summary.adjudicated
    end

    test "a blank human_label from the pre-labelling agent is not a self-adjudication" do
      # Only FILLED rows are adjudications. A pre-labeller that emits the CSV
      # and hands it on untouched has not adjudicated anything, and must not
      # be blocked from doing so.
      root = build_set!()
      {:ok, path, 2} = IntentEval.emit_open(root)

      # Since stage 6 an untouched CSV is refused for being INCOMPLETE, not
      # for self-adjudication. Which refusal comes back is the whole point of
      # this test: the pre-labeller is not accused of adjudicating rows it
      # left blank.
      assert {:error, {:incomplete, ["id-disagree", "id-unsure"]}} =
               IntentEval.ingest(root, path, @strong)
    end

    test "refuses a prelabels file whose rows carry no agent_slug, and proceeds when they do" do
      # A header-only `agent_slug` would leave the self-adjudication check
      # comparing against nil for every row: it passes because it found no
      # slug to match, not because there is no conflict.
      root = build_set!(row_slug: false)

      assert_raise ArgumentError, ~r/no agent_slug/, fn ->
        IntentEval.open_rows(root)
      end

      assert_raise ArgumentError, ~r/no agent_slug/, fn ->
        IntentEval.emit_open(root)
      end

      # Positive control: the SAME set with per-row slugs proceeds normally,
      # so the refusal above is discriminating rather than refusing anything
      # with a prelabels file in it.
      ok_root = build_set!()
      assert {:ok, _path, 2} = IntentEval.emit_open(ok_root)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "intent_eval_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp copy_real_set! do
    root = Path.join(tmp_root(), "set")
    File.cp_r!(IntentEval.root(), root)
    root
  end

  # A three-row synthetic set: one confident agreement (never opened), one
  # disagreement, one agreement the model is unsure about.
  defp build_set!(opts \\ []) do
    root = tmp_root()
    row_slug? = Keyword.get(opts, :row_slug, true)

    slice_rows = [
      row("id-agree", "Designer, make that button teal.", "visual_adjust"),
      row("id-disagree", "Nah, I'm gonna get Harper in here.", "off_topic"),
      row("id-unsure", "Capture that as an action item.", "action_items")
    ]

    slice_path = IntentEval.slice_path(root, "sample")

    IntentEval.write_jsonl!(
      slice_path,
      %{"header" => true, "slice" => "sample", "count" => 3},
      slice_rows
    )

    IntentEval.write_jsonl!(
      IntentEval.prelabels_path(root),
      %{"header" => true, "kind" => "prelabels", "agent_slug" => @strong},
      [
        prelabel("id-agree", "visual_adjust", 0.97, row_slug?),
        prelabel("id-disagree", "action_items", 0.91, row_slug?),
        prelabel("id-unsure", "action_items", 0.40, row_slug?)
      ]
    )

    IntentEval.write_manifest!(root, %{
      "version" => 1,
      "adjudicated" => false,
      "slices" => [
        %{
          "name" => "sample",
          "file" => "slices/sample.jsonl",
          "count" => 3,
          "sha256" => IntentEval.digest(slice_path)
        }
      ]
    })

    root
  end

  defp row(id, text, label) do
    %{
      "id" => id,
      "text" => text,
      "label" => label,
      "slice" => "sample",
      "prior" => [],
      "origin" => "curated"
    }
  end

  # `row_slug?: false` models the hazard: the slug is present in the file
  # HEADER (see the writer above) but on no individual row.
  defp prelabel(id, label, confidence, row_slug?) do
    base = %{
      "id" => id,
      "label" => label,
      "confidence" => confidence,
      "rationale" => "because #{label}"
    }

    if row_slug?, do: Map.put(base, "agent_slug", @strong), else: base
  end

  # Rewrite the emitted CSV with the human_label column filled for the given
  # ids — the spreadsheet step, performed in code.
  defp fill(path, labels) do
    [header | rows] = path |> File.read!() |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
    label_index = Enum.find_index(header, &(&1 == "human_label"))

    filled =
      Enum.map(rows, fn row ->
        case Map.get(labels, hd(row)) do
          nil -> row
          label -> List.replace_at(row, label_index, label)
        end
      end)

    out = path <> ".filled-#{System.unique_integer([:positive])}.csv"

    File.write!(
      out,
      [header | filled] |> NimbleCSV.RFC4180.dump_to_iodata() |> IO.iodata_to_binary()
    )

    out
  end
end
