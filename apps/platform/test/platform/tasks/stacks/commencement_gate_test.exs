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

  # ── helpers ──────────────────────────────────────────────────────────────

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
