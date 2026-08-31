defmodule Platform.Tasks.Stacks.CommencementGateTest do
  @moduledoc """
  Unit tests for the ADR 0042 Decision 4 predicate module.

  These tests exercise the pure boolean surface only — the wiring into
  transition primitives (`transition_task_status/2`,
  `apply_dispatch_gate/1`, `Stacks.start_stack/1`) and the
  gate-opened broadcast land in later stages and carry their own
  integration tests.

  `async: false` is intentional: the tests write via `Repo.update!` on
  shared plan/task rows and load full stacks via
  `Stacks.get_stack/1`. The DataCase sandbox strategy handles it, but
  future rollup-status side-effects (which touch global config) fire
  from `Tasks.approve_plan/3`. We do not call `approve_plan/3` here —
  we drive statuses through the changeset directly to keep this a pure
  predicate test — but staying non-async is cheap insurance.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stack, Stacks, Task}
  alias Platform.Tasks.Stacks.CommencementGate

  describe "open?/1" do
    test "returns true for a non-stacked task (stack_id: nil)" do
      {:ok, project} = Tasks.create_project(%{name: "Loner Project " <> short_id()})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "No-stack task"})

      assert task.stack_id == nil
      assert CommencementGate.open?(task) == true
    end

    test "returns true when stack is in_progress AND every member has an approved plan" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "approved")
      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == true
    end

    test "accepts a `completed` plan the same as `approved` (mirrors current_plan/1)" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "completed")
      set_plan_status(m2, "approved")
      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == true
    end

    test "returns false when stack.status is forming even if every plan is approved" do
      {_stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "approved")
      # stack remains "forming" — the default status from `create_stack/1`

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == false
    end

    test "returns false when one member is missing its plan entirely" do
      {stack, [m1, _m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      # m2 has no plan at all
      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == false
    end

    test "returns false when one member's latest plan is pending_review" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "pending_review")
      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == false
    end

    test "returns false when a member's latest plan is rejected" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "rejected")
      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == false
    end

    test "uses the LATEST plan when a member has multiple versions" do
      # Members with a stale draft superseded by an approved v2 must
      # still count as ready — mirrors `current_plan/1`'s max-version
      # semantics.
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")

      # Create v1 (draft, superseded), then v2 (approved) for m2.
      {:ok, _v1} = Tasks.create_plan(%{task_id: m2.id, version: 1, status: "superseded"})
      {:ok, _v2} = Tasks.create_plan(%{task_id: m2.id, version: 2, status: "approved"})

      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == true
    end

    test "returns false for a member with a stale approved plan superseded by a pending_review v2" do
      # Inverse of the above — an approved v1 then a pending_review v2
      # means the LATEST plan is not approved, so the gate is closed.
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")

      {:ok, _v1} = Tasks.create_plan(%{task_id: m2.id, version: 1, status: "approved"})
      {:ok, _v2} = Tasks.create_plan(%{task_id: m2.id, version: 2, status: "pending_review"})

      {:ok, _} = force_stack_status(stack, "in_progress")

      m1 = Repo.reload!(m1)
      assert CommencementGate.open?(m1) == false
    end

    test "returns false when the stack row is missing (defensive)" do
      # Fabricate a task struct pointing at a stack that never existed.
      # We build it directly rather than persisting so the FK doesn't
      # complain — the predicate must handle the not-found case without
      # a Repo.get raise.
      phantom_stack_id = Ecto.UUID.generate()
      task = %Task{id: Ecto.UUID.generate(), stack_id: phantom_stack_id}
      assert CommencementGate.open?(task) == false
    end
  end

  describe "plans_ready?/1" do
    test "returns true when every member has an approved plan, regardless of stack.status" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "approved")
      # stack is still "forming" — plans_ready? must ignore that.
      assert CommencementGate.plans_ready?(stack) == true
      assert CommencementGate.plans_ready?(stack.id) == true
    end

    test "still returns true after the stack has advanced to in_progress" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "approved")
      {:ok, stack} = force_stack_status(stack, "in_progress")
      assert CommencementGate.plans_ready?(stack) == true
    end

    test "returns false when one member has no plan" do
      {stack, [m1, _m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      # m2 intentionally left plan-less
      assert CommencementGate.plans_ready?(stack) == false
    end

    test "returns false when one member has a pending_review plan" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "pending_review")
      assert CommencementGate.plans_ready?(stack) == false
    end

    test "returns true for an empty stack (no members = nothing to wait on)" do
      stack = empty_stack()
      assert CommencementGate.plans_ready?(stack) == true
    end

    test "returns false for a missing stack id (defensive)" do
      assert CommencementGate.plans_ready?(Ecto.UUID.generate()) == false
    end
  end

  describe "waiting_on/1" do
    test "returns an empty list when every member has an approved plan" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "approved")
      assert CommencementGate.waiting_on(stack) == []
      assert CommencementGate.waiting_on(stack.id) == []
    end

    test "returns the member ids of the not-yet-approved members, ordered by stack_position" do
      {stack, [m1, m2, m3, m4]} = stack_with_members(4)
      # Approve the middle two, leave positions 1 and 4 unapproved.
      set_plan_status(m2, "approved")
      set_plan_status(m3, "approved")
      set_plan_status(m1, "pending_review")
      # m4 has no plan at all

      result = CommencementGate.waiting_on(stack)
      assert result == [m1.id, m4.id]
    end

    test "returns every member id when no plans exist" do
      {stack, [m1, m2, m3]} = stack_with_members(3)

      result = CommencementGate.waiting_on(stack)
      assert result == [m1.id, m2.id, m3.id]
    end

    test "includes members whose latest plan is rejected" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "rejected")
      assert CommencementGate.waiting_on(stack) == [m2.id]
    end

    test "excludes members whose latest plan is completed (mirrors open?/1 acceptance)" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      set_plan_status(m2, "completed")
      assert CommencementGate.waiting_on(stack) == []
    end

    test "returns [] for an empty stack" do
      stack = empty_stack()
      assert CommencementGate.waiting_on(stack) == []
    end

    test "returns [] for a missing stack id (no phantom blockers)" do
      assert CommencementGate.waiting_on(Ecto.UUID.generate()) == []
    end
  end

  describe "member status exclusions" do
    test "a cancelled member without an approved plan does not hold the gate shut" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      cancelled = set_task_status(m2, "cancelled")

      # Precondition: the cancelled member genuinely has no approved plan.
      assert latest_plan_row(cancelled.id) == nil

      assert CommencementGate.plans_ready?(stack) == true
      refute cancelled.id in CommencementGate.waiting_on(stack)

      {:ok, stack} = force_stack_status(stack, "in_progress")
      assert CommencementGate.open?(Repo.get!(Task, m1.id)) == true
      assert CommencementGate.plans_ready?(stack) == true
    end

    test "a cancelled member alongside a live unapproved member leaves the gate shut" do
      {stack, [m1, m2, m3]} = stack_with_members(3)
      set_plan_status(m1, "approved")
      cancelled = set_task_status(m2, "cancelled")
      live = m3

      # Preconditions: neither the cancelled nor the live member holds an
      # approved plan, so "gate stays shut" can only be about the live one.
      assert latest_plan_row(cancelled.id) == nil
      assert latest_plan_row(live.id) == nil
      assert live.status not in ~w(cancelled done)

      assert CommencementGate.plans_ready?(stack) == false
      assert CommencementGate.waiting_on(stack) == [live.id]

      {:ok, stack} = force_stack_status(stack, "in_progress")
      assert CommencementGate.open?(Repo.get!(Task, m1.id)) == false
      assert CommencementGate.waiting_on(stack) == [live.id]
    end

    test "a blocked member without an approved plan still holds the gate shut" do
      {stack, [m1, m2]} = stack_with_members(2)
      set_plan_status(m1, "approved")
      blocked = set_task_status(m2, "blocked")

      assert latest_plan_row(blocked.id) == nil
      assert CommencementGate.plans_ready?(stack) == false
      assert CommencementGate.waiting_on(stack) == [blocked.id]
    end
  end

  # Task 01a05394 stage 5: `waiting_detail/1` attaches WHY each waiting
  # member is waiting, so the MCP `stack_plans_pending` refusal can say
  # `no_planner_assigned` / `plan_pending_review` / `no_plan` instead of
  # only naming the member.
  describe "waiting_detail/1" do
    test "reports three DISTINCT reasons in stack_position order and omits the approved member" do
      {stack, [orphan, pending, planless, approved]} = stack_with_members(4)

      # Anti-vacuity: the orphan really has nothing to resolve a planner
      # from — nil per-phase entry, nil top-level assignee, no stack-level
      # planning default — so `:no_planner_assigned` is earned, not
      # defaulted into.
      assert get_in(orphan.phase_assignees || %{}, ["planning"]) == nil
      assert orphan.assignee_id == nil
      assert get_in(stack.metadata || %{}, ["phase_assignees", "planning"]) == nil
      refute Stacks.dispatchable_planning_assignee?(orphan, stack)

      pending = give_planner(pending)
      planless = give_planner(planless)
      approved = give_planner(approved)
      assert Stacks.dispatchable_planning_assignee?(pending, stack)
      assert Stacks.dispatchable_planning_assignee?(planless, stack)

      set_plan_status(pending, "pending_review")
      # planless: planner, but no plan row at all
      set_plan_status(approved, "approved")

      detail = CommencementGate.waiting_detail(stack)

      assert detail == [
               %{task_id: orphan.id, title: orphan.title, reason: :no_planner_assigned},
               %{task_id: pending.id, title: pending.title, reason: :plan_pending_review},
               %{task_id: planless.id, title: planless.title, reason: :no_plan}
             ]

      reasons = Enum.map(detail, & &1.reason)
      assert length(Enum.uniq(reasons)) == 3
      refute approved.id in Enum.map(detail, & &1.task_id)

      # Same members, same order as the bare-id sibling.
      assert Enum.map(detail, & &1.task_id) == CommencementGate.waiting_on(stack)
      # The id form goes through `Stacks.get_stack/1` and agrees.
      assert CommencementGate.waiting_detail(stack.id) == detail
    end

    test "planner check wins over a stale pending plan (precedence 1 before 2)" do
      # A member whose planner was unassigned AFTER a plan was drafted:
      # a plan row in `pending_review` exists, but nobody will ever carry
      # it to approval. Reporting `:plan_pending_review` here is the
      # quiet degradation the reason exists to remove.
      {stack, [stale]} = stack_with_members(1)
      refute Stacks.dispatchable_planning_assignee?(stale, stack)
      set_plan_status(stale, "pending_review")

      assert [%{task_id: id, reason: :no_planner_assigned}] =
               CommencementGate.waiting_detail(stack)

      assert id == stale.id
    end

    test "a draft plan reads as :plan_pending_review; rejected/superseded read as :no_plan" do
      {stack, [drafted, rejected, superseded]} = stack_with_members(3)
      drafted = give_planner(drafted)
      rejected = give_planner(rejected)
      superseded = give_planner(superseded)
      set_plan_status(drafted, "draft")
      set_plan_status(rejected, "rejected")
      set_plan_status(superseded, "superseded")

      assert Enum.map(CommencementGate.waiting_detail(stack), & &1.reason) ==
               [:plan_pending_review, :no_plan, :no_plan]
    end

    test "a stack-level planning default resolves the planner (member is not :no_planner_assigned)" do
      {stack, [member]} = stack_with_members(1)
      assert get_in(member.phase_assignees || %{}, ["planning"]) == nil

      {:ok, %{stack: stack}} =
        Stacks.set_stack_phase_assignees(stack, %{
          "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        })

      assert [%{reason: :no_plan}] = CommencementGate.waiting_detail(stack)
    end

    test "returns [] for an empty stack and for a missing stack id" do
      assert CommencementGate.waiting_detail(empty_stack()) == []
      assert CommencementGate.waiting_detail(Ecto.UUID.generate()) == []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Give a member an agent-typed planning assignee so
  # `Stacks.dispatchable_planning_assignee?/2` is true for it.
  defp give_planner(%Task{} = task) do
    {:ok, task} =
      Tasks.set_phase_assignees(task, %{
        "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
      })

    task
  end

  # Build a stack + `count` members already attached in `stack_position`
  # order. Members carry no plan by default; individual tests seed plans
  # via `set_plan_status/2` for the paths they care about.
  defp stack_with_members(count) when count > 0 do
    {:ok, project} =
      Tasks.create_project(%{name: "Gate Fixture Project " <> short_id()})

    slug = "gate-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Gate Fixture Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    members =
      Enum.map(1..count, fn i ->
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Member #{i} " <> short_id()
          })

        {:ok, attached} = Stacks.add_task(stack, task)
        attached
      end)

    {stack, members}
  end

  defp empty_stack do
    {:ok, project} =
      Tasks.create_project(%{name: "Empty Gate Stack Project " <> short_id()})

    slug = "empty-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Empty Gate Fixture",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Create-or-update the sole plan for `task` at v1 with the given
  # status. We short-circuit the `create_plan/1` reject-when-pending
  # guard by writing directly to `Repo`; that guard is a policy on the
  # public API, not on the schema, and would refuse the second write
  # in tests that flip statuses.
  defp set_plan_status(%Task{id: task_id}, status) do
    case latest_plan_row(task_id) do
      nil ->
        %Plan{}
        |> Plan.changeset(%{task_id: task_id, version: 1, status: status})
        |> Repo.insert!()

      %Plan{} = plan ->
        plan
        |> Plan.changeset(%{status: status})
        |> Repo.update!()
    end
  end

  # Flip a member's status field directly. The public transition
  # primitives run dispatch/gate cascades; these are pure predicate
  # tests, so we write the field.
  defp set_task_status(%Task{} = task, status) do
    task
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update!()
  end

  defp latest_plan_row(task_id) do
    import Ecto.Query

    Plan
    |> where([p], p.task_id == ^task_id)
    |> order_by([p], desc: p.version)
    |> limit(1)
    |> Repo.one()
  end

  # `Stacks.start_stack/1` runs a cascade with side effects (deployer
  # calls, dispatch guards). For the pure predicate tests we just want
  # to flip the status field.
  defp force_stack_status(%Stack{} = stack, status) do
    stack
    |> Stack.changeset(%{status: status})
    |> Repo.update()
  end

  defp short_id do
    Ecto.UUID.generate() |> String.slice(0, 8)
  end
end
