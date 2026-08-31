defmodule Platform.Tasks.Stacks.CommencementGate do
  @moduledoc """
  Pure predicate module for the Stack-v2 task-commencement gate
  (ADR 0042 Decision 4).

  ## The invariant

  No member of a stack transitions from `pending`/`backlog`/`planning` to
  `in_progress` until **every** member of the stack has an approved plan.
  Once the last plan is approved, the gate opens and members become
  eligible to start (subject to their in-stack dependency ordering, which
  is enforced elsewhere).

  This module owns the boolean check only. Wiring it into the transition
  primitives (`transition_task_status/2`, `apply_dispatch_gate/1`,
  `Stacks.start_stack/1`) lands in the next stage; the last-approval
  broadcast lands in stage 3. Telemetry lands in stage 4.

  ## Surface

    * `open?/1` — is a specific task allowed to run right now? For
      non-stack tasks (`stack_id: nil`) this is vacuously `true` so
      caller sites can be a one-liner. For stack members, this checks
      **both** that the stack has actually opened (`status == "in_progress"`)
      AND that every sibling has an approved plan. Missing stack row →
      `false` (safer to stall than to falsely open).

    * `plans_ready?/1` — subset of `open?` used at the moment
      `Stacks.start_stack/1` is trying to flip the stack itself into
      `in_progress`. Ignores current stack status; asks only "do all
      members have approved plans?".

    * `waiting_on/1` — the member ids that are missing approved plans,
      preserving `stack_position` ordering. Callers surface this inside
      the structured error payload (`{:error, :stack_plans_pending,
      %{stack_id, waiting_on}}`) so UIs can point at the blockers.

    * `waiting_detail/1` — the same members as `waiting_on/1`, in the
      same order, each carrying `title` and a `reason` atom that says
      WHY the member is still waiting (`:no_planner_assigned` /
      `:plan_pending_review` / `:no_plan`). Rendered by the MCP
      `stack_plans_pending` refusal so a caller learns what to chase.

  ## What counts as "approved"

  We reuse the same predicate `Platform.Tasks.current_plan/1` uses:
  a plan with status in `["approved", "completed"]`. A completed plan
  is one that has advanced past approval into execution — it satisfies
  the gate for the same reason `current_plan/1` accepts it. Rejected,
  superseded, draft, and pending_review plans do NOT count.

  A member with no plan at all also does not count as ready.

  ## Which members count

  Soft-deleted members (`deleted_at` set) are not gate members, and
  neither are members whose status is:

    * `cancelled` — a cancelled member can never acquire an approved
      plan, so counting it would wedge the stack at `stack_pending`
      permanently.
    * `done` — a done member normally holds a `completed` plan and
      would pass anyway; excluding it also keeps the gate robust to a
      done member whose plan was later superseded.

  Every other status still counts, `blocked` included: a blocked member
  is still expected to run and must still hold the gate shut.

  ## Empty-stack policy

  A stack with zero counted members is vacuously ready — the gate
  is `plans_ready?/1 == true` and `waiting_on/1 == []`. Whether
  `Stacks.start_stack/1` should even accept an empty stack is a
  question for the caller; this module is neutral.

  ## Query shape

  Two round-trips per `open?/1`:

    1. `Repo.get(Stack, stack_id)` for the status field.
    2. One combined query for members' latest plan status via a
       `DISTINCT ON (task_id) ... ORDER BY task_id, version DESC`
       subquery joined against `tasks`. This avoids the N+1 pattern
       that `Platform.Tasks.current_plan/1` per-member would produce.

  `plans_ready?/1` skips the stack fetch (it's given the stack or id
  and doesn't care about status).
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Tasks.{Plan, Stack, Stacks, Task}
  alias Platform.Tasks.Stacks.MemberSet

  @approved_plan_statuses ~w(approved completed)

  # Member statuses that are NOT counted as gate members. Shared by both
  # member queries (`load_member_ids/1` and `load_members_ordered/1`) so
  # `plans_ready?/1` and `waiting_on/1` can never disagree about the
  # membership set. The list itself now lives in `MemberSet` so the
  # completion path (`Stacks.pending_members/1`) cannot drift from it.
  # (see `MemberSet.excluded_statuses/0`, called directly at both query sites)

  # Latest-plan statuses that mean "a plan exists and is still on its way
  # to approval". A `rejected`/`superseded` latest plan is NOT pending —
  # no live plan exists and a fresh one has to be produced — so it reads
  # as `:no_plan` in `waiting_detail/1`, alongside the no-row case.
  @pending_plan_statuses ~w(draft pending_review)

  @doc """
  True when the given task is allowed to be in `in_progress` under the
  Stack-v2 gate.

  Non-stacked tasks (`stack_id: nil`) are vacuously open — this module
  never blocks a plain task. Stack members require both the stack itself
  to be at `in_progress` AND every sibling to hold an approved plan.

  Emits `[:platform, :stacks, :commencement, :gate_check]` on every
  invocation (measured after we know the answer so `open` is truthful
  and `blocked_by_count` reflects the actual sibling gap). Non-stack
  tasks and missing-stack short-circuits emit too — dashboards want the
  real check volume, not just the stack-member subset.
  """
  @spec open?(Task.t()) :: boolean()
  def open?(%Task{stack_id: nil} = task) do
    emit_gate_check(nil, task.id, true, 0)
    true
  end

  def open?(%Task{stack_id: stack_id} = task) when is_binary(stack_id) do
    {open, blocked_by_count} =
      case Repo.get(Stack, stack_id) do
        nil ->
          {false, 0}

        %Stack{status: "in_progress"} = stack ->
          if plans_ready?(stack) do
            {true, 0}
          else
            {false, length(waiting_on(stack))}
          end

        %Stack{} = stack ->
          # Stack exists but is not yet `in_progress`. Report the plan-gap
          # separately so telemetry disambiguates "waiting on start_stack"
          # (blocked_by_count = 0) from "still missing plans"
          # (blocked_by_count > 0).
          {false, length(waiting_on(stack))}
      end

    emit_gate_check(stack_id, task.id, open, blocked_by_count)
    open
  end

  @doc """
  True when every (non-deleted) member of the stack currently holds an
  approved-or-completed plan.

  Ignores `stack.status`. Used by `Stacks.start_stack/1` at the moment
  it is about to flip the stack into `in_progress`; at that instant the
  stack is still `forming`, so we cannot include a status check.

  Empty stacks (no members) return `true` vacuously.

  Accepts a `%Stack{}` or a stack id. A missing stack id → `false`
  (defensive; symmetric with `open?/1`).
  """
  @spec plans_ready?(Stack.t() | binary()) :: boolean()
  def plans_ready?(%Stack{id: stack_id}), do: plans_ready?(stack_id)

  def plans_ready?(stack_id) when is_binary(stack_id) do
    case load_member_ids(stack_id) do
      nil ->
        false

      [] ->
        true

      member_ids ->
        approved = approved_member_ids(member_ids)
        MapSet.size(approved) == length(member_ids)
    end
  end

  @doc """
  Member task ids that do NOT currently hold an approved plan, ordered
  by `stack_position` ascending (so the UI surfaces the earliest
  blocker first).

  A member with no plan at all is included; a member with only a
  `draft`/`pending_review`/`rejected`/`superseded` plan is included;
  a member with an `approved` or `completed` latest plan is excluded.

  Empty stacks return `[]`. Missing stacks return `[]` (no members =
  nothing to wait on; symmetric with `plans_ready?/1` returning
  `false` for the missing case — that layer decides the error, this
  layer just doesn't invent phantom blockers).
  """
  @spec waiting_on(Stack.t() | binary()) :: [binary()]
  def waiting_on(%Stack{id: stack_id}), do: waiting_on(stack_id)

  def waiting_on(stack_id) when is_binary(stack_id) do
    case load_members_ordered(stack_id) do
      [] ->
        []

      members ->
        approved = approved_member_ids(Enum.map(members, & &1.id))

        members
        |> Enum.reject(&MapSet.member?(approved, &1.id))
        |> Enum.map(& &1.id)
    end
  end

  @type waiting_reason :: :no_planner_assigned | :plan_pending_review | :no_plan

  @doc """
  `waiting_on/1` with a reason attached: `[%{task_id, title, reason}]`
  in the same `stack_position` order, one entry per member that does
  NOT currently hold an approved plan. `waiting_on/1` keeps its bare id
  shape — other callers pattern-match on it — so this is a sibling, not
  a replacement.

  `reason` is resolved in this precedence:

    1. `:no_planner_assigned` — `Stacks.dispatchable_planning_assignee?/2`
       is false for the member against its stack. Checked FIRST: a
       member with no planner will never produce a plan at all, so
       reporting `:no_plan` for it would be the quiet degradation the
       reason exists to remove — even if a stale `pending_review` plan
       row is lying around from before the planner was unassigned.
    2. `:plan_pending_review` — the member's latest plan is `draft` or
       `pending_review`.
    3. `:no_plan` — no plan row at all, or the latest one is
       `rejected`/`superseded` (no live plan exists either way).

  One member query plus one batched latest-plan query, same as
  `waiting_on/1` — no per-member round-trip. Missing stacks and empty
  stacks return `[]`.
  """
  @spec waiting_detail(Stack.t() | binary()) :: [
          %{task_id: binary(), title: String.t() | nil, reason: waiting_reason()}
        ]
  def waiting_detail(%Stack{id: stack_id} = stack), do: do_waiting_detail(stack, stack_id)

  def waiting_detail(stack_id) when is_binary(stack_id) do
    case Stacks.get_stack(stack_id) do
      nil -> []
      %Stack{} = stack -> do_waiting_detail(stack, stack_id)
    end
  end

  defp do_waiting_detail(%Stack{} = stack, stack_id) do
    case load_members_ordered(stack_id) do
      [] ->
        []

      members ->
        statuses = latest_plan_status_by_member(Enum.map(members, & &1.id))

        members
        |> Enum.reject(&(Map.get(statuses, &1.id) in @approved_plan_statuses))
        |> Enum.map(fn member ->
          %{
            task_id: member.id,
            title: member.title,
            reason: waiting_reason(member, stack, Map.get(statuses, member.id))
          }
        end)
    end
  end

  defp waiting_reason(member, stack, latest_status) do
    cond do
      not Stacks.dispatchable_planning_assignee?(member, stack) -> :no_planner_assigned
      latest_status in @pending_plan_statuses -> :plan_pending_review
      true -> :no_plan
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  # Returns nil when the stack row is missing (defensive short-circuit for
  # `plans_ready?/1`), `[]` for a stack with no members, or a list of
  # member task ids ordered by `stack_position` asc.
  defp load_member_ids(stack_id) do
    if Repo.exists?(from(s in Stack, where: s.id == ^stack_id)) do
      Task
      |> where(
        [t],
        t.stack_id == ^stack_id and is_nil(t.deleted_at) and
          t.status not in ^MemberSet.excluded_statuses()
      )
      |> order_by([t], asc: t.stack_position)
      |> select([t], t.id)
      |> Repo.all()
    else
      nil
    end
  end

  # Same shape as `load_member_ids/1` but returns full `%Task{}` structs.
  # Used by `waiting_on/1` because it needs `stack_position` to preserve
  # ordering AND `id` in the return.
  defp load_members_ordered(stack_id) do
    Task
    |> where(
      [t],
      t.stack_id == ^stack_id and is_nil(t.deleted_at) and
        t.status not in ^MemberSet.excluded_statuses()
    )
    |> order_by([t], asc: t.stack_position)
    |> Repo.all()
  end

  # Batched "which of these members have an approved-or-completed latest
  # plan?" query. Uses `DISTINCT ON (task_id) ... ORDER BY task_id,
  # version DESC` inside a subquery to collapse to the latest plan per
  # task in a single round-trip, then filters those rows to the
  # approved-or-completed set. Returns a `MapSet` of task ids for O(1)
  # membership tests in the caller.
  defp approved_member_ids([]), do: MapSet.new()

  defp approved_member_ids(member_ids) when is_list(member_ids) do
    member_ids
    |> latest_plan_status_by_member()
    |> Enum.filter(fn {_task_id, status} -> status in @approved_plan_statuses end)
    |> MapSet.new(fn {task_id, _status} -> task_id end)
  end

  # `%{task_id => latest plan status}` for the given members, in one
  # round-trip. Members with no plan row are absent from the map. Shared
  # by `approved_member_ids/1` and `waiting_detail/1` so the two can never
  # disagree about which plan is "latest".
  defp latest_plan_status_by_member([]), do: %{}

  defp latest_plan_status_by_member(member_ids) when is_list(member_ids) do
    from(p in Plan,
      where: p.task_id in ^member_ids,
      distinct: p.task_id,
      order_by: [asc: p.task_id, desc: p.version],
      select: {p.task_id, p.status}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Telemetry emission for `open?/1`. Kept as a thin helper so the two
  # call sites (nil-stack short-circuit and stack-member check) stay
  # branch-free. Mirrors the `:telemetry.execute/3` shape used in
  # `Platform.Tasks.PlanEngine` and `Platform.Tasks.StackDeployer` —
  # measurements are numeric, metadata carries the ids and the boolean
  # answer.
  defp emit_gate_check(stack_id, task_id, open, blocked_by_count) do
    :telemetry.execute(
      [:platform, :stacks, :commencement, :gate_check],
      %{blocked_by_count: blocked_by_count},
      %{stack_id: stack_id, task_id: task_id, open: open}
    )
  end
end
