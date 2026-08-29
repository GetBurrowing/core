defmodule Platform.Mix.Tasks.IntentEvalDiscriminationTest do
  @moduledoc """
  The anti-vacuity test for the offline intent-eval harness
  (task `01a03fbb` stage 5).

  ## What this file is for

  A harness that reports success for everything is worse than no harness: it
  converts "we did not look" into "we looked and it was fine". Stages 1-4
  built the instrument. This file is the evidence that the instrument can
  tell a good configuration from a broken one — and it is the assertion most
  likely to be quietly dropped, because everything passes without it.

  Three DELIBERATELY BROKEN configs are committed alongside the two
  reference ones, each with its own cassette, so every number below replays
  with no network at all:

    * `broken_always_off_topic`  — declines every utterance
    * `broken_never_off_topic`   — never declines
    * `broken_malformed_schema`  — answers in prose instead of JSON

  ## The thresholds are deliberately wide

  They exist to catch a harness that cannot separate configs AT ALL, not to
  pin this model's score. The observed gaps are enormous (0.0 vs 0.983 on
  control fire rate; 102 vs 8 on negative false-fires; 0 vs 174 JSON-shaped
  responses). Tightening these numbers to look rigorous would buy nothing
  and would turn this into the flaky test somebody deletes.

  ## Two findings recorded here, and what the `target_role: null` fix did to
  ## them

  Both findings below were recorded when this file was written against a
  tree that still rejected the JSON `null` the classifier's own prompt enum
  instructs for `target_role`. Task `01a03f57` fixed that, and the numbers
  moved exactly where the finding predicted they would — so the findings are
  kept here with their outcome rather than deleted, because the movement IS
  the evidence that the harness measures the thing it claims to.

  1. **The spec's "parse_error exceeds half the set" assertion was VACUOUS
     before the fix, and it is still not the assertion made.** It used to be
     vacuous because EVERYTHING errored: `off_topic_default` landed 96 of
     174 rows in `parse_error` and `broken_always_off_topic` 174 of 174, so
     the count separated nothing. After the fix both land 0 of 174 — the
     count is no longer vacuous, but it is now carrying the whole
     separation, so the assertions below still ALSO compare the recorded
     response SHAPE. A single number that happens to separate two configs
     today is not a reason to stop checking the thing underneath it.

  2. **`broken_always_off_topic` now shows the shape the plan predicted.**
     It was expected to be near-perfect on the 102 negatives and scored 0,
     because its perfectly-valid `"target_role": null` JSON was rejected
     before its correct decline could be counted. That was recorded as an
     observation about the tree rather than corrected by editing the
     control — and the fix turned it into 102 of 102. The discrimination the
     control exists to prove (a reject-everything gate collapses on the
     control slice) held under both, and is what is asserted.

  `binary_actionable` is deliberately NOT used as a comparison point: stage 4
  recorded that its prompt is a labelled reconstruction (the original was
  never committed), so it is a different arm, not a peer of
  `off_topic_default`.
  """

  # `Platform.DataCase` rather than a plain `ExUnit.Case`: the harness itself
  # touches no database, but `IntentClassifier.decide/1` emits telemetry that
  # `Platform.Meetings.TelemetryHandler` turns into an audit-row INSERT. With
  # no sandbox checkout that INSERT raises inside `decide/1`'s rescue and is
  # swallowed — the numbers came out right anyway, but a swallowed database
  # error inside the code under test is exactly the kind of silence this
  # stage exists to refuse.
  use Platform.DataCase, async: true

  alias Platform.Meetings.IntentEval.Harness

  @good "off_topic_default"
  @always "broken_always_off_topic"
  @never "broken_never_off_topic"
  @malformed "broken_malformed_schema"

  # Only these three manifest fields may differ between two replays of one
  # config. The reproducibility test deletes exactly this set and demands
  # byte-equality of everything else — a looser comparison (say, checking a
  # handful of headline numbers) would pass on a harness that varied every
  # other score.
  @volatile_manifest_fields ~w(started_at finished_at wall_clock_seconds)

  setup do
    {:ok, runs: Map.new([@good, @always, @never, @malformed], &{&1, replay!(&1)})}
  end

  defp replay!(config) do
    {:ok, result} = Harness.run(config, mode: :replay, write: false)
    result
  end

  defp slice(result, name), do: result["summary"]["per_slice"][name]

  # The control slice's FIRE RATE: rows that produced a dispatchable intent,
  # over rows in the slice.
  #
  # Fire rate, not exact-label accuracy, because the question the control
  # slice answers is "does a real ask get through this gate at all". Exact
  # label accuracy is reported too (and is lower — 47/60 for the good
  # config), but a gate that routes a `visual_adjust` as an
  # `interaction_design` has still let the work through, whereas a gate that
  # declines it has not. Both numbers are asserted below so neither hides
  # behind the other.
  defp control_fire_rate(result) do
    stats = slice(result, "control_60")
    stats["fired"] / stats["rows"]
  end

  describe "reject-everything is caught by the control slice" do
    test "broken_always_off_topic fires on no control row, off_topic_default on nearly all", %{
      runs: runs
    } do
      always = control_fire_rate(runs[@always])
      good = control_fire_rate(runs[@good])

      # Observed 2026-08-27: always = 0.0 (0/60), good = 0.9833 (59/60).
      assert always < 0.2,
             "broken_always_off_topic control fire rate #{always} — a config that declines " <>
               "every utterance must collapse on the control slice, or the control slice is " <>
               "not being scored"

      assert good > 0.9,
             "off_topic_default control fire rate #{good} — the reference config must let real " <>
               "asks through, or the gap below measures nothing"

      assert good - always > 0.7
    end

    test "the good config's exact-label control accuracy is recorded, not just its fire rate", %{
      runs: runs
    } do
      good = slice(runs[@good], "control_60")
      always = slice(runs[@always], "control_60")

      # Observed 2026-08-27: good 47/60 exactly right, always 0/60. The 13
      # rows the good config mis-routes are asserted as a FLOOR, not hidden:
      # 0.7 is well under the observed 0.783 so a real regression still
      # shows, and the number is named here so a reader sees it.
      assert good["correct"] / good["rows"] > 0.7
      assert always["correct"] == 0
    end
  end

  describe "fire-on-everything is caught by the negative slice" do
    test "broken_never_off_topic false-fires on essentially every negative", %{runs: runs} do
      never = slice(runs[@never], "negatives_102")
      good = slice(runs[@good], "negatives_102")

      # Observed 2026-08-27: never = 102/102 fired, good = 8/102.
      # Re-measured 2026-08-29 after the frame gate (task 01a04b6b):
      # never = 93/102, good = 3/102. The broken config is FORCED to
      # answer with a non-`off_topic` intent on every row, so the 9 it
      # lost are rows where the frame gate demoted a forced fire — the
      # gate working, not the discrimination weakening. Worth saying out
      # loud that the headroom on this threshold is now 3, not 12: a
      # further widening of the gate would break this test, and that is
      # the right place for it to break.
      assert never["fired"] > 90,
             "broken_never_off_topic fired on #{never["fired"]} of #{never["rows"]} negatives — " <>
               "a config forbidden from declining must false-fire, or the negative slice is " <>
               "not being scored"

      assert good["fired"] < 20,
             "off_topic_default fired on #{good["fired"]} of #{good["rows"]} negatives"

      assert never["fired"] - good["fired"] > 70
    end
  end

  describe "prose-not-JSON is caught, and is not reported as a decline or a success" do
    # This is the assertion that replaces the spec's vacuous "parse_error
    # exceeds half the set" (see the moduledoc). It compares against the
    # good config's background rate on the SAME slice, where that rate is 1
    # of 60 rather than the whole-set 96 of 174.
    test "broken_malformed_schema parse_errors dwarf the good config's background rate", %{
      runs: runs
    } do
      malformed = slice(runs[@malformed], "control_60")
      background = slice(runs[@good], "control_60")

      # Observed 2026-08-27, after the `target_role: null` fix: malformed
      # 60/60 parse_error on this slice; off_topic_default's background
      # rate on the same slice is 0/60. Whole-set: malformed 174/174,
      # off_topic_default 0/174 (it was 96/174 before the fix, which is
      # why the whole-set comparison is not the one this test makes).
      assert background["errors"] < 10,
             "off_topic_default control-slice error count #{background["errors"]} — if the " <>
               "background rate is high here too, the assertion below is vacuous"

      assert malformed["errors"] > 50
      assert malformed["errors"] > background["errors"] * 10
    end

    test "a prose answer is neither a decline nor a success", %{runs: runs} do
      malformed = runs[@malformed]["summary"]

      # Errors are their OWN outcome class. Folding them into `off_topic`
      # is the exact defect that once made 83 of 102 correct declines read
      # as parse failures in one instrument and as declines in another.
      assert malformed["error_classes"]["parse_error"] == malformed["total"]

      for {_slice, stats} <- malformed["per_slice"] do
        assert stats["off_topic"] == 0, "an unparseable answer was counted as a decline"
        assert stats["correct"] == 0, "an unparseable answer was counted as correct"
        assert stats["fired"] == 0
      end

      assert malformed["per_class"]["off_topic"]["true_positives"] == 0
    end

    # The two broken arms fail in completely different ways:
    # `broken_always_off_topic` emits 174 syntactically perfect JSON
    # objects that decline every row, and `broken_malformed_schema` emits
    # 174 things that are not JSON at all.
    #
    # Before the `target_role: null` fix, the outcome CLASS could not tell
    # them apart — both scored 174 parse_errors — and only the recorded
    # response shape could. The fix separated them on outcome class as
    # well. Both separations are asserted: the shape check is what caught
    # the conflation in the first place, and dropping it now that a
    # headline number happens to work would remove the only assertion that
    # survived the period when that number was lying.
    test "the two arms differ in both outcome class and recorded response SHAPE",
         %{runs: runs} do
      always_errors = runs[@always]["summary"]["error_classes"]["parse_error"]
      malformed_errors = runs[@malformed]["summary"]["error_classes"]["parse_error"]

      # Observed 2026-08-27, after the fix: always 0, malformed 174.
      assert malformed_errors == 174

      assert always_errors == 0,
             "broken_always_off_topic scored #{always_errors} parse_errors — its answers are " <>
               "valid JSON declines, so anything above zero means the target_role:null defect " <>
               "task 01a03f57 fixed has regressed"

      # Valid-JSON-but-wrong versus not-JSON-at-all, independent of how
      # either is scored.
      assert json_object_count(@always) == 174
      assert json_object_count(@malformed) == 0
    end
  end

  describe "reproducibility is demonstrated, not asserted" do
    test "two replays of one config are byte-identical outside the timestamp set" do
      first = replay!(@good)
      second = replay!(@good)

      assert scrub(first) == scrub(second)

      # And the exclusion set is not a licence to differ everywhere: prove
      # the scrub actually removed something, so a future change that made
      # every field volatile could not pass by widening it.
      assert first["manifest"]["started_at"] != second["manifest"]["started_at"]
      assert Map.keys(scrub(first)["manifest"]) != Map.keys(first["manifest"])
    end
  end

  defp scrub(result) do
    update_in(result["manifest"], &Map.drop(&1, @volatile_manifest_fields))
  end

  defp json_object_count(config) do
    Platform.Meetings.IntentEval.root()
    |> Platform.Meetings.IntentEval.Cassette.path(config)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.count(fn entry ->
      match?({:ok, %{}}, Jason.decode(entry["response"]["content"] || ""))
    end)
  end
end
