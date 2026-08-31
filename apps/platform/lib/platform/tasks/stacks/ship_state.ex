defmodule Platform.Tasks.Stacks.ShipState do
  @moduledoc """
  Pure predicates for a stack's **shipped** and **conflict-held** state
  (ADR 0045 decision 7: "post-ship adjustments are individual tasks").

  This module answers a question about the STACK — did it actually ship
  through the rollup, and is it halted on an unresolved rollup conflict —
  which is disjoint from `Platform.Tasks.Stacks.MemberSet`'s question of
  which MEMBERS count toward a rollup status. Nothing here touches the
  Repo; every function takes a `%Stack{}` (or a plain metadata map) and
  reads `metadata` only.

  ## Why `shipped?/1` is not `status == "done"`

  `status == "done"` is strictly broader than "shipped through the rollup".
  `Platform.Tasks.StackDeployer`'s rollup-merge handler has an explicit
  `is_nil(rollup_pr)` arm (`stack_deployer.ex:1608-1621`) for a stack that
  was manually flipped to `done` with NO `rollup_pr` metadata — the
  **manual-ship lane**. Such a stack has to stay mutable: its members can
  still be reopened, because nothing was ever merged on their behalf. A
  stack is shipped only when there is evidence of the merge itself:

    * `metadata["rollup_merge"]` — the summary stamped by
      `Stacks.complete_rollup_merge/2`; or
    * `metadata["rollup_pr"]["merged_at"]` — the GitHub merge timestamp.

  The two arms are written as separate `or` operands deliberately, so a
  mutation probe can aim at either alone.

  ## Terminality, and the `abandoned` escape

  A shipped stack is terminal on the function path too:
  `Stacks.abandon_stack/2` refuses a `done` stack outright. The stack
  changeset nevertheless keeps `done -> abandoned` reachable, because
  `recompute_stack_status/1` treats `abandoned` as a no-op terminal and
  the changeset must not block that path. Function refuses, changeset
  allows — consistent, and stated here because a reader will ask.
  """

  alias Platform.Tasks.Stack

  @doc """
  True iff the stack actually shipped through its rollup branch.

  FALSE for a `done` stack with no `rollup_pr` metadata (the manual-ship
  lane) and FALSE for a `done` stack whose rollup PR is open but not yet
  merged (`merged_at` nil).
  """
  @spec shipped?(Stack.t() | map() | nil) :: boolean()
  def shipped?(subject) do
    metadata = metadata_of(subject)

    non_empty_map?(Map.get(metadata, "rollup_merge")) or
      merged_at_present?(get_in(metadata, ["rollup_pr", "merged_at"]))
  end

  @doc """
  True iff the stack is halted on a recorded rollup-merge conflict.

  Producer: `StackDeployer.record_conflict/4`, which writes
  `%{status: "blocked", metadata: %{"conflict" => %{...}}}`.
  """
  @spec conflict_held?(Stack.t() | map() | nil) :: boolean()
  def conflict_held?(subject) do
    subject |> metadata_of() |> Map.get("conflict") |> non_empty_map?()
  end

  @doc """
  The operator-facing refusal string for a shipped stack.

  Always contains the literal phrase "post-ship changes are new individual
  tasks" and names the stack slug; names the rollup PR number when the
  metadata carries one. This message is the only place the engine states
  ADR 0045 decision 7 to an operator — a guard that fires without
  explaining itself is the failure mode being fixed here.
  """
  @spec ship_refusal_message(Stack.t() | map() | nil) :: String.t()
  def ship_refusal_message(subject) do
    slug = slug_of(subject)

    pr_clause =
      case get_in(metadata_of(subject), ["rollup_pr", "number"]) do
        nil -> ""
        number -> " (rollup PR ##{number})"
      end

    "Stack #{slug}#{pr_clause} has already shipped through its rollup branch; " <>
      "post-ship changes are new individual tasks. Re-file the work as its own " <>
      "task rather than reopening a member of a shipped stack."
  end

  defp metadata_of(%Stack{metadata: metadata}), do: normalize(metadata)
  defp metadata_of(metadata) when is_map(metadata), do: normalize(metadata)
  defp metadata_of(_), do: %{}

  defp normalize(metadata) when is_map(metadata), do: metadata
  defp normalize(_), do: %{}

  defp slug_of(%Stack{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp slug_of(%Stack{id: id}) when is_binary(id), do: id
  defp slug_of(_), do: "unknown"

  defp non_empty_map?(value), do: is_map(value) and map_size(value) > 0

  defp merged_at_present?(value), do: is_binary(value) and value != ""
end
