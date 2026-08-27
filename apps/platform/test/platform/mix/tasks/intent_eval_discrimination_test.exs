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

  ## Two findings recorded here rather than tuned away

  1. **The spec's "parse_error exceeds half the set" assertion is VACUOUS on
     this branch, so it is not the assertion made.** `off_topic_default`
     itself lands 96 of 174 rows in `parse_error` already, and
     `broken_always_off_topic` lands 174 of 174. A parse_error count
     therefore separates nothing. The cause is a known defect fixed on
     `task/01a03f57`, not here: the model emits JSON `null` for
     `target_role` exactly as its prompt's enum instructs, and
     `parse_content/2`'s `is_binary` guard rejects it. So the assertions
     below compare `broken_malformed_schema` against `off_topic_default`'s
     background rate ON THE SAME SLICE, and against the shape of the
     recorded response, rather than against zero.

  2. **`broken_always_off_topic` does NOT show the shape the plan predicted**
     — it was expected to be near-perfect on the 102 negatives, and it
     scores 0. Same root cause: its perfectly-valid `"target_role": null`
     JSON is rejected before its correct decline can be counted. That is
     recorded as an observation about the branch, not corrected by editing
     the control. The discrimination the control exists to prove — that a
     reject-everything gate collapses on the control slice — holds either
     way, and is what is asserted.

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

      # Observed 2026-08-27: malformed 60/60 parse_error on this slice;
      # off_topic_default's background rate on the same slice is 1/60.
      # Whole-set: malformed 174/174, off_topic_default 96/174 — which is
      # why the whole-set comparison is not the one made.
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

    # The assertion that separates the two broken arms that the parse_error
    # COUNT cannot separate, and the one that names finding (1) in the
    # moduledoc. `broken_always_off_topic` emits 174 syntactically perfect
    # JSON objects and is still called a parse_error; `broken_malformed_schema`
    # emits 174 things that are not JSON at all. Same outcome class today,
    # very different failures.
    test "the two arms differ in the recorded response SHAPE even though the outcome class is identical",
         %{runs: runs} do
      assert runs[@always]["summary"]["error_classes"]["parse_error"] ==
               runs[@malformed]["summary"]["error_classes"]["parse_error"],
             "if these have diverged, the branch's target_role:null defect was fixed — " <>
               "re-read this test's moduledoc before adjusting anything"

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
