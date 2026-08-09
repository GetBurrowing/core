defmodule Platform.Lifecycle.Steps.WorktreeCleanup do
  @moduledoc """
  EFFECT: remove a run's git worktree when its task reaches a terminal status
  (ADR-0046, task 019fe1b7 stage 3).

  Not a gate and not a notify. It awaits nothing, decides nothing about the
  transition, and cannot send a task back — `await: false, can_divert: false`
  in the declaration `Platform.Lifecycle.Edges.default_steps/1` ships, and the
  executor reads authority from that declaration and never from position.

  ## "Terminal" means THE LAST TRANSITION, not "after the deploy agent"

  The edge set is `Platform.Lifecycle.EdgeInventory.terminal_edges/0`, DERIVED
  from the transition table as every inbound edge to `done` or `cancelled`.
  Hanging this on `deploying->done` alone would be wrong in a way nothing
  would report: an ADR-0041 stack member rides the rollup-PR merge fan-out,
  owns no per-task deploy stage, and reaches `done` from `in_review` (or
  `in_progress`) WITHOUT EVER PASSING THROUGH `deploying`. Its worktree would
  simply never be cleaned up. Terminality is a property of the transition
  table, never of the presence of a deploy stage.

  `->cancelled` is included because a run genuinely can exist for a cancelled
  task: `cancelled` is reachable from `in_progress`, runs are started while a
  task is in progress, and cancellation's teardown
  (`maybe_dispatch_teardown/2`) abandons leases and stops the router but
  removes no directory. A cancelled task's worktree is exactly the one nobody
  comes back for.

  ## Finding nothing to do is `complete`, not `not_applicable`

  Most tasks reaching a terminal status have no worktree: no run, a run that
  never allocated a workspace, a workspace a previous terminal transition
  already removed (every edge can fire more than once), or a directory removed
  out of band. In ALL of those this step returns `{:completed, _}`.

  `not_applicable` is a different fact and belongs to a different layer: it is
  what `Platform.Lifecycle.Executor` records for a TRAVERSED edge whose
  configured pipeline is EMPTY. A configured hook that ran and found nothing
  to do is `complete`. Conflating them would make "no cleanup configured"
  indistinguishable from "nothing needed cleaning".

  ## A real failure is `failed`. There is no catch-all rescue

  `git worktree remove` refusing a dirty worktree is CORRECT behaviour and
  surfaces as `{:failed, _}` — the hard-failure preference, not an obstacle to
  force past with `--force`. "Nothing there" is decided by `File.exists?`
  BEFORE acting (`Platform.Execution.LocalWorkspace.remove_git_worktree/2`
  returns `{:ok, :absent}`), so the two are genuinely distinguishable rather
  than collapsed by a rescue that cannot tell them apart.

  ## Reach is bounded by what the VM still knows

  `Platform.Execution.run_ids_for_task/1` is a LIVE index — runs are never
  persisted (see its docs). This step therefore cleans up the runs whose
  servers are still alive at the terminal transition and nothing else. That is
  a real limit, stated rather than papered over; a durable task->run index is
  the prerequisite for widening it and does not exist today.
  """

  @behaviour Platform.Lifecycle.Step

  alias Platform.Execution
  alias Platform.Execution.LocalWorkspace

  @impl Platform.Lifecycle.Step
  def kind, do: :sync

  @doc """
  Arity-1 entry point for the registry's `{mod, fun, 1}` MFA shape.

  The executor prefers `start/2` when the module exports it and only falls
  back to this, but `StepRegistry`'s entries are arity-1 and a test asserts
  every built-in resolves to a real arity-1 function. Same shim the designer
  and architect steps carry.
  """
  @spec start(map()) :: Platform.Lifecycle.Step.start_result()
  def start(context) when is_map(context), do: start(%{}, context)

  @impl Platform.Lifecycle.Step
  def start(_step_config, %{task: task}) do
    results =
      task.id
      |> Execution.run_ids_for_task()
      |> Enum.map(fn run_id -> {run_id, LocalWorkspace.remove_git_worktree(run_id)} end)

    case Enum.filter(results, &match?({_run_id, {:error, _reason}}, &1)) do
      [] ->
        {:completed, tally(results)}

      failures ->
        {:failed, {:worktree_cleanup_failed, Enum.map(failures, fn {id, err} -> {id, err} end)}}
    end
  end

  defp tally(results) do
    %{
      removed: for({run_id, {:ok, :removed}} <- results, do: run_id),
      absent: for({run_id, {:ok, :absent}} <- results, do: run_id)
    }
  end
end
