defmodule Platform.PendingFix do
  @moduledoc """
  Tests written RED on purpose, before the fix that turns them green.

  ## Why this is NOT `Platform.TestQuarantine`

  The quarantine registry records tests the suite cannot TRUST — flaky,
  environment-bound, or leaking state — and its `excluded_tags/0` refuses to
  hide anything whose cause is deterministic or unknown. A `:pending_fix` test
  is the opposite: it is completely trustworthy and perfectly deterministic. It
  fails on every run, for exactly one reason, and that reason is a defect in
  production code that has not been fixed yet.

  Filing such a test as `:intermittent` to borrow the quarantine's
  excludability would be a lie about its cause — precisely the confusion
  `TestQuarantine`'s moduledoc exists to end. Its "What does NOT belong here"
  section is the rule being followed by putting this in its own module.

  ## Why exclude a red test at all

  A red test in the default suite trains everyone to read "N failures" as
  normal, which is how a real regression gets waved through. So the defect
  test is excluded and the suite stays honestly green, while
  `mix test --include pending_fix` runs the whole set of known-open defects on
  demand.

  ## The contract

    * The test's `@moduledoc` names the owning task and the defect.
    * The entry below carries the ticket and what the test proves.
    * The stage that lands the FIX deletes the `@tag :pending_fix` and this
      entry **in the same commit**. A `:pending_fix` tag that outlives its fix
      is a bug: it means a now-passing test is silently not running.

  `test/test_helper.exs` derives its exclusion list from `excluded_tags/0`
  here and from the quarantine registry — never from a literal list, which
  `Platform.TestQuarantineTest` asserts.
  """

  # RETIRED ENTRIES — each was deleted in the same commit as its fix, per the
  # contract above. Kept as a note rather than a list so nothing here can be
  # mistaken for a still-open defect:
  #
  #   * task `01a006e7` — the bounce-leaves-no-open-stage test. Retired by
  #     stage 4 of that task.
  #   * task `01a01b00` — the unmet-gate set. Stage 2 retired four of its five
  #     cases (`failed` / `running` `e2e_behavior` classification); stage 3
  #     retired the last one, "an all-passed stage on an in_review task must
  #     NOT resolve a review slug", by teaching
  #     `DispatchPhase.review_status_without_unmet_gate?/2` to refuse the
  #     stale-status fallthrough into a reviewer slug.
  #   * task `019fcfdd` — the meeting chat space that carried no `org_id`.
  #     Registered by stage 1 and retired by stage 2, which wired the existing
  #     `Meetings.resolve_meeting_org_id/1` + `maybe_put_org_id/2` into
  #     `Meetings.create_meeting/1`.
  #
  @tag :pending_fix

  @entries [
    %{
      tag: @tag,
      test:
        "test/platform_web/components/meetings/candidate_rail_test.exs: " <>
          "the assignment renders after the evidence quote so the byline cannot " <>
          "read as the assignee",
      ticket: "01a064fa",
      reason: """
      The populated candidate card has NO `data-role="meeting-candidate-quote"`
      element. Only the `:skeleton` branch spells the evidence quote that way
      (`candidate_rail.ex:274`); the `:forming` and `:full` branch renders the
      same `evidence_quote` as `data-role="meeting-candidate-title"` at `:289`
      and then puts `meeting-candidate-assignment` at `:312`, immediately under
      the title and beside the byline — where it reads as part of the
      attribution, which is the authorship confusion this component was fixed
      twice to remove.

      The test asserts the approved canvas's reading order on DOM position:
      byline BEFORE the quote, assignment AFTER it, for every card state that
      renders both. Red today with the anti-vacuity guard, which reports the
      markers each card actually rendered.

      Stage 4 of task `01a05b14` is the stage that gives the populated card the
      italic left-ruled quote line and moves the assignment to the card's last
      line. It makes this green and deletes both the `@tag :pending_fix` and
      this entry. Task `01a064fa` deliberately does NOT edit
      `candidate_rail.ex`: two agents editing it on overlapping branches is how
      work gets lost.
      """,
      added_on: ~D[2026-09-02]
    },
    %{
      tag: @tag,
      test:
        "test/platform/meetings/intent_classifier_test.exs: " <>
          "classify_and_enqueue — agent roster in the MIGRATED template",
      ticket: "01a05997",
      reason: """
      The classifier passes an `agent_roster` assign, but the `prompt_templates`
      row for `meetings.intent_classify.v1` carries no `{{agent_roster}}`
      marker, so the roster reaches the INLINE fallback only and never the body
      production actually renders. `render_template/2` prefers the DB row and
      `seed_defaults/0` is INSERT-only, so the marker can only arrive through a
      force-update migration.

      That migration was written (`20260831120000_force_update_intent_classify_
      prompt_agent_roster`) and deliberately NOT shipped with the code, for two
      reasons found when the 08-31 branch was rebased onto main on 2026-09-10:

        * `main` since gained `20260902140000_force_update_intent_classify_
          prompt_unmerge_intent_and_target` (task `01a06575`), which rewrites
          the same row and explicitly REVERSES the "detection and addressing are
          ONE question" framing the 08-31 body is built on, on a production
          measurement. A rebase does not renumber migrations, so the 08-31 file
          would run as a pending LOWER version and clobber the 09-02 revision on
          every already-migrated deployment.
        * The live row was hand-edited by a human on 2026-09-03
          (`updated_by` `86149c7d-1e45-42aa-a250-1e190e169341`). An
          unconditional overwrite authored against the 08-31 content reverts
          that edit with no diff and no error.

      Reconciling the two prompt bodies is a human decision, not an agent's. The
      stage that ships the reconciled migration deletes the `@describetag
      :pending_fix` and this entry in the same commit.
      """,
      added_on: ~D[2026-09-10]
    }
  ]

  @doc "Every known-open-defect entry."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc """
  The ExUnit tags `test/test_helper.exs` excludes for known-open defects.

  Derived, not literal — see the moduledoc.
  """
  @spec excluded_tags([map()]) :: [atom()]
  def excluded_tags(entries \\ @entries) do
    entries |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
