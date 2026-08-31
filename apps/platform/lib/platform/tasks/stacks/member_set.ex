defmodule Platform.Tasks.Stacks.MemberSet do
  @moduledoc """
  One definition of "a stack member that counts".

  Before this module the engine carried two disagreeing answers: the
  commencement gate excluded `cancelled` AND `done` members
  (`CommencementGate`'s `@excluded_member_statuses`), while
  `Stacks.pending_members/1` excluded only `done` — so a cancelled member
  was invisible to the gate but wedged `complete_stack/2` at
  `{:error, :members_not_done}` forever.

  Every predicate here is pure: it reads the fields off a `%Task{}` (or any
  map carrying `:status`, `:deleted_at` and `:metadata`) and returns a
  boolean. Nothing here touches the `Repo`.

  ## Why a cancelled predecessor releases its dependents but a `done` one
  ## without a rollup stamp does not

  `dependency_satisfied?/1` is deliberately NOT "status == done". The
  landed test stays `Stacks.member_landed_on_rollup?/1`, which requires a
  non-nil `merged_into_rollup_at` stamp, because that same predicate is
  what `StackDeployer` uses to decide a member's branch is already in the
  rollup. Loosening it to accept `done`-without-a-stamp would let the
  rollup merge past a member whose branch was never merged in — silent code
  loss, strictly worse than the stalled dependent it would fix.

  `cancelled` is the one status that gets its own release arm: a cancelled
  predecessor can never acquire a stamp, so waiting on it is waiting
  forever. `blocked` does NOT release — a blocked predecessor is still
  expected to run.
  """

  alias Platform.Tasks.Stacks

  # Copied verbatim from `CommencementGate`, which now delegates here so the
  # two can never drift apart.
  @excluded_member_statuses ~w(cancelled done)

  @doc """
  Member statuses that are NOT counted as gate members.
  """
  @spec excluded_statuses() :: [String.t()]
  def excluded_statuses, do: @excluded_member_statuses

  @doc """
  True when the member counts toward the commencement gate's membership set.

  False for a soft-deleted member and for any member whose status is in
  `excluded_statuses/0`.
  """
  @spec counts_as_gate_member?(map()) :: boolean()
  def counts_as_gate_member?(%{deleted_at: deleted_at}) when not is_nil(deleted_at), do: false

  def counts_as_gate_member?(%{status: status}) when is_binary(status),
    do: status not in @excluded_member_statuses

  def counts_as_gate_member?(_), do: false

  @doc """
  True when the member still owes work before the stack can complete.

  False for `done`, false for `cancelled`, false for a soft-deleted member;
  true otherwise. This is the completion-side twin of
  `counts_as_gate_member?/1` — the two share one exclusion set on purpose.
  """
  @spec counts_as_pending?(map()) :: boolean()
  def counts_as_pending?(%{deleted_at: deleted_at}) when not is_nil(deleted_at), do: false

  def counts_as_pending?(%{status: status}) when is_binary(status),
    do: status not in @excluded_member_statuses

  def counts_as_pending?(_), do: false

  @doc """
  True when an in-stack dependency no longer holds its dependent back.

  Two independent arms, kept as separate clauses so a mutation probe can
  aim at either alone:

    * the dependency is `cancelled` — it can never acquire a rollup stamp,
      so it must release; or
    * the dependency has landed on the rollup per
      `Stacks.member_landed_on_rollup?/1` (status in
      `in_review|deploying|done` AND a non-nil `merged_into_rollup_at`).

  Notably `done` WITHOUT a stamp is NOT satisfied, and `blocked` is NOT
  satisfied. See the moduledoc for why.
  """
  @spec dependency_satisfied?(map()) :: boolean()
  def dependency_satisfied?(%{status: "cancelled"}), do: true

  def dependency_satisfied?(dep), do: Stacks.member_landed_on_rollup?(dep)
end
