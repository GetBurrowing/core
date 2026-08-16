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

  # EMPTY BY DESIGN. The registry's only entry — task `01a006e7`'s
  # bounce-leaves-no-open-stage test — was retired by stage 4 of that task,
  # which wired `bounce_to_in_progress/4` to
  # `PlanEngine.open_remediation_stage/2`. Per the contract above, the tag and
  # this entry were deleted in the same commit as the fix; the test now runs
  # in the default suite.
  #
  # An empty list is the honest steady state: it means the suite is hiding no
  # known-open defects. `excluded_tags/0` returns `[]` and `test_helper.exs`
  # excludes nothing on this account.
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
