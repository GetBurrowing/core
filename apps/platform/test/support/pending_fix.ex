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
  # The registry is EMPTY, and that is its healthy state. `excluded_tags/0`
  # then returns `[]`, so `test/test_helper.exs` excludes nothing on this
  # account and every test in the suite runs by default.

  @entries []

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
