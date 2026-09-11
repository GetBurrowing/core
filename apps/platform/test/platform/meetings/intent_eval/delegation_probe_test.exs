defmodule Platform.Meetings.IntentEval.DelegationProbeTest do
  @moduledoc """
  The roster-grounding gate for task `01a05997` (stage 4).

  Stage 3 rewrote `meetings.intent_classify` so the addressing rule is stated
  against the org's AGENT ROSTER. This file scores that revision against the
  committed `agent_roster` cassette and pins what it actually does to the
  three utterances the brief named:

    * `Dalton file a ticket for the purse-based meeting problem.` — the
      reproduction. The transcript said "Octavius", which is on no roster; the
      slice uses `Dalton`, the agent actually assigned `triage_officer` on the
      production roster pinned in `configs/agent_roster_20260831.json`.
    * `Agent Voice, can you hear me?` — control, `off_topic`.
    * `Is anything happening?` — control, `off_topic`.

  ## What this file asserts, and what it refuses to assert

  The rebalance DOES fix the reproduction: the utterance that landed
  `off_topic` on the shipped prompt is now routable, cited, and carries
  `target_role: triage_officer`.

  The PROMPT alone did NOT discriminate. `Octavius file a ticket for the
  purse-based meeting problem.` — byte-identical except for the name, and the
  name is not on the roster — fired routable too, as did four more off-roster
  asks. The roster was in the prompt and the model was not using it: what
  moved was the model's willingness to fire on a ticket-filing ask, not its
  ability to tell an agent from a person. That finding was recorded here as a
  failing discrimination rather than tuned away, and it is why stage 5
  stopped editing the prompt.

  **Stage 5 closed it in CODE.** `Platform.Meetings.IntentAddressee` is a
  post-model gate: a routable answer whose ADDRESSED NAME is absent from the
  roster the model was shown is demoted to `off_topic` with
  `demotion_reason: :off_roster_addressee`. The same cassette, unchanged, now
  scores 0 off-roster false fires on this slice instead of 5, with both
  on-roster positives still firing and still cited. The block below is
  written from BOTH sides — the model's own answer is still asserted to be
  the wrong one, and the gate is asserted to be what corrects it — so a
  future prompt revision that genuinely teaches the model the roster shows up
  as a change here rather than hiding behind the gate.

  ## Every claim here is shown going red

  `broken_never_off_topic` is the committed negative control — a config whose
  only instruction is to never decline. `check/1` returns the list of failed
  expectations for a config, so the SAME expectations that come back empty for
  `agent_roster` come back populated and named for the broken config. An
  assertion that only ever ran against the good arm would be passing on a
  property it never showed itself able to detect.

  ## Why the arm is named `agent_roster_20260831` and not `agent_roster`

  Task `01a08f9f` stage 2 moved the LIVE `agent_roster` arm onto the body that
  `20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged.exs`
  actually ships, so the byte-identity drift guard has something true to assert.
  A cassette key is `sha256(rendered_prompt || 0 || chunk_text)`, so that rewrite
  turned all 9 rows here into a cassette miss — measured, not predicted:
  `{:cassette_miss, %{count: 9, total: 9}}` invalidating this whole module.

  The measurement below belongs to the 08-31 prompt and cannot be re-attributed
  to a different body, so it keeps its own frozen arm — `agent_roster_20260831`,
  with its own prompt file and the same cassette bytes renamed. The numbers in
  this file are therefore unchanged: 4 / 5 / 0 still mean what stage 4 measured.
  Re-recording against the new body is a separate act with a separate name.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentEval
  alias Platform.Meetings.IntentEval.Harness

  @reproduction "Dalton file a ticket for the purse-based meeting problem."
  @off_roster_twin "Octavius file a ticket for the purse-based meeting problem."
  @control_audio "Agent Voice, can you hear me?"
  @control_vague "Is anything happening?"

  # Replay only. A live call here would make the suite host-bound on
  # dev-host:8085 and would score a different sample every run.
  defmodule ForbiddenProvider do
    @moduledoc false
    def chat_completion(_agent, _messages, _opts),
      do: raise("replay test reached the network")
  end

  setup_all do
    %{
      agent_roster: rows_by_text("agent_roster_20260831"),
      baseline: rows_by_text("off_topic_default")
    }
  end

  defp rows_by_text(config) do
    {:ok, result} =
      Harness.run(config,
        root: IntentEval.root(),
        mode: :replay,
        slice: "delegation_probe",
        live_module: ForbiddenProvider,
        repo_root: Path.expand("../../../..", __DIR__),
        write: false
      )

    Map.new(result["rows"], &{&1["text"], &1})
  end

  describe "the reproduction" do
    test "landed off_topic on the shipped prompt — the defect, from its own cassette", %{
      baseline: baseline
    } do
      row = baseline[@reproduction]

      assert row["predicted"] == "off_topic"
      assert row["target_role"] in [nil, "null"]

      refute Harness.fired?(row),
             "the shipped prompt must still show the defect, or the fix below has nothing to fix"
    end

    test "is routable, cited, and routed to triage_officer on the roster prompt", %{
      agent_roster: rows
    } do
      row = rows[@reproduction]

      assert Harness.fired?(row)
      assert row["target_role"] == "triage_officer"
      assert row["demoted_from"] == nil

      # The acceptance bar is a NON-EMPTY citation, not merely a firing: a
      # routed candidate with no quote gives the human nothing to judge.
      assert is_binary(row["evidence_quote"]) and row["evidence_quote"] != ""

      assert String.contains?(@reproduction, row["evidence_quote"]),
             "evidence_quote #{inspect(row["evidence_quote"])} is not a verbatim span of the utterance"

      # Measured, not desired: the labelled intent is `open_question` (the
      # enum member the prompt maps to triage_officer for intake asks) and the
      # model answers `action_items`. It routes to the right role by a
      # different road. Pinned so a later revision that fixes the intent shows
      # up as a change here rather than passing silently.
      assert row["predicted"] == "action_items"
      assert row["label"] == "open_question"
    end
  end

  describe "the two brief controls" do
    test "both stay off_topic on the roster prompt", %{agent_roster: rows} do
      for text <- [@control_audio, @control_vague] do
        row = rows[text]
        assert row["predicted"] == "off_topic", "#{inspect(text)} fired"
        refute Harness.fired?(row)
      end
    end
  end

  describe "the model still does not discriminate — the GATE does (task 01a05997 stage 5)" do
    test "the off-roster twin is turned down by the gate, not by the model", %{
      agent_roster: rows
    } do
      roster = rows[@reproduction]
      off_roster = rows[@off_roster_twin]

      # The two utterances differ only in the addressed name.
      assert Harness.fired?(roster)
      assert roster["demotion_reason"] == nil

      refute Harness.fired?(off_roster),
             "the off-roster twin fired — the addressee gate is not running"

      # And this is the part that stops the assertion above from being read
      # as "the prompt learned the roster". The MODEL still answers a
      # routable intent on this row; what changed is that the answer is now
      # rejected after the fact. If a later revision genuinely teaches the
      # model, `demoted_from` goes nil here and this goes red — which is the
      # correct outcome to have to argue for.
      assert off_roster["demoted_from"] == "open_question"
      assert off_roster["demotion_reason"] == "off_roster_addressee"
      assert off_roster["predicted"] == "off_topic"
      assert off_roster["label"] == "off_topic"
    end

    test "off-roster false fires: 4 shipped, 5 roster-prompt, 0 with the gate", %{
      agent_roster: rows,
      baseline: baseline
    } do
      false_fires = fn rows ->
        rows
        |> Map.values()
        |> Enum.filter(&(&1["label"] == "off_topic"))
        |> Enum.count(&Harness.fired?/1)
      end

      # The shipped prompt, and the roster prompt as stage 4 measured it,
      # are both still scored from their own cassettes. `off_topic_default`
      # pins no `agent_roster` in its config, so the gate is inert there by
      # construction and its 4 stays 4 — the stage-4 finding is preserved,
      # not overwritten.
      assert false_fires.(baseline) == 4
      assert false_fires.(rows) == 0
    end

    test "and the gate is what did it — all 5 are gate demotions, none are model declines", %{
      agent_roster: rows
    } do
      # Anti-vacuity for the zero above: a zero produced by the model
      # declining, by a parse error, or by the citation gate would read
      # identically in `false_fires`. Naming the reason is what ties the
      # number to this stage.
      gated =
        rows
        |> Map.values()
        |> Enum.filter(&(&1["demotion_reason"] == "off_roster_addressee"))
        |> Enum.map(& &1["text"])
        |> Enum.sort()

      assert gated == [
               "Chris, can you file a ticket for the purse-based meeting problem?",
               "Harper, can you write that up?",
               "Marcus, put together a ticket for that login timeout thing.",
               @off_roster_twin,
               "Sam, open a task to track the flaky deploy, would you?"
             ]
    end

    test "the two on-roster positives survive the gate, routable and cited", %{
      agent_roster: rows
    } do
      # The failure mode this fix is most likely to have: fixing the
      # negatives by suppressing the positives. Both rows address `Dalton`,
      # who IS on the roster.
      for text <- [
            @reproduction,
            "Dalton, we need a ticket for the way the purse thing broke the meeting."
          ] do
        row = rows[text]

        assert Harness.fired?(row), "#{inspect(text)} was suppressed by the gate"
        assert row["demotion_reason"] == nil
        assert is_binary(row["evidence_quote"]) and row["evidence_quote"] != ""
      end
    end
  end

  # ── the gate, and the gate going red ──────────────────────────────────

  describe "the negative control" do
    test "the same three expectations come back EMPTY for agent_roster_20260831" do
      assert check("agent_roster_20260831") == []
    end

    test "and come back populated and named for broken_never_off_topic" do
      failures = check("broken_never_off_topic")

      # The expectation set detects the config instructed never to decline.
      assert failures == ["#{@control_vague}: expected off_topic, got open_question"]
    end

    test "only ONE of the two controls catches it — the other is caught by the citation gate" do
      rows = rows_by_text("broken_never_off_topic")

      # Stated rather than left as a residual, because it is the difference
      # between "two independent checks fired" and "one fired and one was
      # rescued by a different mechanism". `broken_never_off_topic` answers
      # `brief_worthy` on the audio check and cites a quote that is not in
      # the utterance, so the evidence gate demotes it to `off_topic` before
      # the expectation ever sees it. The check above passes on that row for
      # a reason that has nothing to do with the prompt under test.
      audio = rows[@control_audio]
      assert audio["predicted"] == "off_topic"
      assert audio["demoted_from"] == "brief_worthy"

      # The row that does the catching, and the one the reproduction shares
      # its shape with: no demotion, a real citation, a routable intent.
      vague = rows[@control_vague]
      assert Harness.fired?(vague)
      assert vague["demoted_from"] == nil
    end
  end

  # The three brief utterances as one checkable predicate: the reproduction
  # must be routable AND cited, the two controls must decline. Returns the
  # failures rather than asserting, so the identical expectation set can be
  # run against the negative control and shown to fail.
  defp check(config) do
    rows = rows_by_text(config)

    reproduction =
      case rows[@reproduction] do
        row ->
          cond do
            not Harness.fired?(row) ->
              ["#{@reproduction}: expected a routable intent, got #{row["predicted"]}"]

            row["evidence_quote"] in [nil, ""] ->
              ["#{@reproduction}: routable but uncited"]

            true ->
              []
          end
      end

    controls =
      for text <- [@control_audio, @control_vague],
          rows[text]["predicted"] != "off_topic",
          do: "#{text}: expected off_topic, got #{rows[text]["predicted"]}"

    reproduction ++ controls
  end
end
