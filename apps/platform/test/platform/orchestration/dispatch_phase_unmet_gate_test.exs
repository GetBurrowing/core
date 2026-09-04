defmodule Platform.Orchestration.DispatchPhaseUnmetGateTest do
  @moduledoc """
  Task `01a01b00` stage 1 — pin the unmet-gate branch defect with tests that
  fail on today's code.

  ## The defect

  `DispatchPhase.pending_validations/1` counts a validation as still-open ONLY
  at the literal status `"pending"`. `Platform.Tasks.Validation` declares four
  statuses — `pending | running | passed | failed` — and
  `PlanEngine.all_validations_resolved?/1` already treats `pending` AND
  `running` as unresolved. The two modules disagree about what "open" means.

  After one review round an `e2e_behavior` case sits at `failed`, and
  `PlanEngine.maybe_advance_resolved_stage/1` re-opens the stage to `running`.
  On the next dispatch `pending_validations/1` returns `[]`,
  `phase_for_pending/1` answers `nil`, and `phase_for/2` falls through to the
  LAST resort — `status_phase(task)`, still reading the stale `"in_review"` —
  so the UI-judgment template (`dispatch.in_review`) is rendered for a stage
  that carries no `manual_approval` gate at all. Observed four times on stage
  `01a0180b-0625-74a2-b79d-9157457d4341` of task
  `01a01796-2be2-78e3-870e-116542d65af5`.

  ## Anti-vacuity — read before touching an assertion here

  This defect is entirely about WHICH BRANCH IS SELECTED, so a test that is
  green both before and after the fix proves nothing about it. The cases below
  are therefore split into two kinds, and the split is load-bearing:

    * `@tag :pending_fix` — RED when stage 1 wrote them. Stage 2 landed
      `Platform.Tasks.Validation.unmet_statuses/0` and classified on it
      instead of `"pending"`, which turned FOUR of the five green; their tags
      were deleted in that same commit.

      ONE tag survived stage 2, on purpose: "an all-passed stage on an
      in_review task must NOT resolve a review slug". Widening the predicate
      could not reach it — with nothing unmet the list is empty either way and
      `phase_for/2` still fell through to `status_phase(task)`. Stage 3
      retired it by teaching `phase_for/2` to refuse that fallthrough into a
      reviewer slug (`review_status_without_unmet_gate?/2`), and deleted the
      tag and its `Platform.PendingFix` entry in the same commit. No tag
      survives in this file.

    * UNTAGGED CONTROLS — green today and REQUIRED to stay green. Widening
      "unmet" must move the `e2e_behavior` case WITHOUT moving the
      `manual_approval` one. A fix implemented as "any non-passed validation
      classifies behaviourally" would satisfy every red test above and break
      these; they are the only thing standing between the narrow fix and that
      over-wide one. They are deliberately not tagged, so they run in the
      default suite where a regression is visible.

  Pure functions, no DB — `async: true`.
  """
  use ExUnit.Case, async: true

  alias Platform.Orchestration.DispatchPhase
  alias Platform.Tasks.Validation

  # Slugs that address a REVIEWER. `dispatch.in_review` is the UI-judgment
  # body; `dispatch.review_e2e` is the behavioural one. Named here so the
  # all-passed case below asserts a set membership rather than one string.
  @review_slugs ["dispatch.in_review", "dispatch.review_e2e"]

  # Fixture shape mirrors `dispatch_phase_test.exs` deliberately — same
  # `task/2` and `stage/2` helpers, so the two files can be read side by side
  # and a difference in outcome is attributable to the validation STATUSES
  # rather than to a different fixture.
  defp task(status, extra \\ %{}), do: Map.merge(%{id: "task-1", status: status}, extra)

  defp stage(kinds, extra \\ %{}) do
    Map.merge(
      %{
        id: "stage-1",
        position: 3,
        status: "running",
        name: "Migrate the staging stack into named modules",
        validations:
          Enum.map(kinds, fn
            {kind, status} -> %{id: "v-#{kind}-#{status}", kind: kind, status: status}
            kind -> %{id: "v-#{kind}", kind: kind, status: "pending"}
          end)
      },
      extra
    )
  end

  describe "the status vocabulary this defect turns on" do
    test "Validation declares five statuses, of which three are still owed" do
      # Anti-vacuity floor for the whole file: every red case below rests on
      # `failed` and `running` being REAL, declared statuses rather than typos
      # that no production row could ever hold. If this assertion ever fails,
      # the cases below stop being evidence about anything.
      assert "failed" in Validation.statuses()
      assert "running" in Validation.statuses()
      assert "pending" in Validation.statuses()
      assert "passed" in Validation.statuses()
      # `skipped` (task 01a0665e stage 3): a could_not_evaluate e2e case the
      # engine moved out of the way once its host stage passed. Terminal and
      # MET — it must never read as still owed.
      assert "skipped" in Validation.statuses()
      refute "skipped" in Validation.unmet_statuses()
      assert length(Validation.statuses()) == 5
      assert length(Validation.unmet_statuses()) == 3
    end
  end

  describe "an e2e_behavior gate that is unmet but not literally \"pending\"" do
    test "a FAILED e2e_behavior on an in_review task resolves review_e2e, not the UI template" do
      # The live repro shape, reduced: lint and test gates already passed, the
      # behavioural gate came back failed, the stage was re-opened. Nothing on
      # this stage is at literal "pending", so today `pending_validations/1`
      # returns [] and the resolver falls through to the stale task status.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([
            {"lint_pass", "passed"},
            {"test_pass", "passed"},
            {"e2e_behavior", "failed"}
          ])
        )

      assert phase.slug == "dispatch.review_e2e",
             "a failed e2e_behavior gate is work still owed — the stage's own contract " <>
               "must decide the template, not the task row's stale in_review status"

      assert phase.stage_id == "stage-1"
      assert phase.ack_mode == :stage
    end

    test "a RUNNING e2e_behavior on an in_review task resolves review_e2e, not the UI template" do
      # `running` is the status `PlanEngine.all_validations_resolved?/1`
      # already treats as unresolved, so this case is the plainest statement
      # of the disagreement between the two modules.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([
            {"lint_pass", "passed"},
            {"test_pass", "passed"},
            {"e2e_behavior", "running"}
          ])
        )

      assert phase.slug == "dispatch.review_e2e",
             "PlanEngine.all_validations_resolved?/1 already counts `running` as unresolved; " <>
               "the dispatch classifier must not disagree with it"
    end

    test "the failed e2e case still resolves review_e2e when the task status is NOT in_review" do
      # Direction control for the two cases above. If they were passing only
      # because some future change re-mapped `in_review` wholesale, this would
      # stay red — the answer must come from the STAGE, so the task status
      # must not be able to supply it.
      phase =
        DispatchPhase.resolve(
          task("in_progress"),
          %{},
          stage([{"test_pass", "passed"}, {"e2e_behavior", "failed"}])
        )

      assert phase.slug == "dispatch.review_e2e"
    end
  end

  describe "CONTROL — the working manual_approval case that must not move" do
    test "a PENDING manual_approval on an in_review task still resolves the UI template" do
      # GREEN TODAY AND GREEN AFTER THE FIX, on purpose. This is the case the
      # widening must NOT move. Untagged so it runs in the default suite.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([{"test_pass", "passed"}, {"manual_approval", "pending"}])
        )

      assert phase.slug == "dispatch.in_review",
             "widening `unmet` must move the e2e case and leave this one exactly where it is"

      assert phase.ack_mode == :stage
    end

    test "a FAILED manual_approval — a re-opened UI gate — still resolves the UI template" do
      # The variant stage 4's second e2e case names. Today this lands on
      # `dispatch.in_review` by ACCIDENT (nothing is pending, so the stale
      # in_review status supplies the answer); after the fix it lands there by
      # the stage's own contract (`manual_approval` is the only unmet kind).
      # Same slug, different route — which is why the assertion is green on
      # both sides and is a mutation guard rather than a defect witness.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([{"test_pass", "passed"}, {"manual_approval", "failed"}])
        )

      assert phase.slug == "dispatch.in_review",
             "a re-opened UI gate must not be reclassified as behavioural"
    end
  end

  describe "a stage that owes nothing at all" do
    test "an all-passed stage on an in_review task must NOT resolve a review slug" do
      # STAGE 3 ANSWERED THE OPEN QUESTION THIS NOTE USED TO CARRY.
      #
      # The question was whether the clause belonged here at all, given that
      # stage 3 as SPECIFIED put the withholding in `TaskRouter`, which does
      # not change what `DispatchPhase.resolve/3` returns. The answer on the
      # record: the spec named one seam for two different symptoms, and both
      # are real.
      #
      #   * The RESOLVER must stop answering a reviewer slug for a stage that
      #     owes no gate — that is this assertion, and no amount of router
      #     suppression can satisfy it. `phase_for/2` now consults
      #     `review_status_without_unmet_gate?/2` before its last-resort
      #     `status_phase(task)` fallthrough and answers `:fallback`.
      #   * The ROUTER must withhold the dispatch entirely when the rest of
      #     the plan owes nothing either — the resolver cannot see the plan, so
      #     it cannot make that call. That half is pinned in
      #     `task_router_no_unmet_gate_suppression_test.exs`, along with the
      #     three negative controls that keep the withholding from strangling
      #     a task in the transient not-yet-advanced window.
      #
      # So the clause did not move; a second one was added beside it.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([
            {"lint_pass", "passed"},
            {"test_pass", "passed"},
            {"e2e_behavior", "passed"}
          ])
        )

      refute phase.slug in @review_slugs,
             "a stage that owes no gate must not be handed a reviewer template on the " <>
               "strength of a task status that DispatchPhase's own moduledoc calls stale"
    end

    test "CONTROL — an UNGATED stage on an in_review task still resolves the UI template" do
      # THE OVER-SUPPRESSION CONTROL, and the one that actually caught a
      # too-wide first draft of stage 3's predicate (it red two provider-
      # guidance cases in `heartbeat_scheduler_test.exs`, whose fixture stage
      # carries `validations: []`).
      #
      # "Every gate met" requires a gate. `PlanEngine` auto-advances a stage
      # from exactly one place — the `cond` inside `evaluate_validation/2` —
      # so an UNGATED stage is never advanced by the engine at all. The only
      # thing that moves it is an agent calling `stage_complete`, and the only
      # thing that makes an agent do that is this dispatch. Answering
      # `dispatch.fallback` here (and, in the router, withholding it) parks
      # the task forever, which is strictly worse than the defect stage 3
      # fixes.
      ungated = stage([])
      assert ungated.validations == [], "fixture floor — this stage must carry NO gates"

      phase = DispatchPhase.resolve(task("in_review"), %{}, ungated)

      assert phase.slug == "dispatch.in_review"
      assert phase.stage_id == "stage-1"
    end

    test "CONTROL — the all-passed stage does resolve a stage, so nothing is being fabricated" do
      # Green today and after. Guards the reading of the case above: it must
      # red because of the SLUG, never because the stage failed to resolve.
      phase =
        DispatchPhase.resolve(
          task("in_review"),
          %{},
          stage([{"test_pass", "passed"}])
        )

      assert phase.stage_id == "stage-1"
      assert phase.ack_mode == :stage
    end
  end
end
