defmodule Platform.Tasks.Stacks.MigrationSlotAuditTest do
  @moduledoc """
  Task 019f7b7e stage 4 — defensive collision audit across a stack's
  reserved migration slots.

  Stages 1-3 make collisions impossible for slots the allocator issues.
  This covers the backstop for the cases where the allocator was never
  consulted (detection-regex miss, hand-authored plan, executor minting
  its own timestamp) — the exact bypass that produced the 2026-07-17
  M1/M4 incident.

  The load-bearing behavioral claim here is that the audit is LOG-ONLY:
  a collision must never stop a planning wave from dispatching.

  `async: false` mirrors the rest of the stack suite — the planning
  cascade broadcasts on the board PubSub and touches process-global
  state.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, Task}

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp stack_with_members(count) do
    {:ok, project} = Tasks.create_project(%{name: "Audit Project #{uniq()}"})
    slug = "audit-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Audit Stack #{slug}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    members =
      Enum.map(1..count, fn i ->
        {:ok, task} =
          Tasks.create_task(%{project_id: project.id, title: "Member #{i} #{uniq()}"})

        {:ok, attached} = Stacks.add_task(stack, task)
        attached
      end)

    {stack, members}
  end

  # Forge a reservation directly onto task.metadata, simulating a slot
  # that reached the task by some path other than the allocator.
  defp forge_slots!(%Task{} = task, timestamps) when is_list(timestamps) do
    entries =
      Enum.with_index(timestamps, 1)
      |> Enum.map(fn {ts, i} ->
        %{
          "stage_id" => Ecto.UUID.generate(),
          "stage_name" => "Stage #{i}",
          "timestamp" => ts,
          "allocated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      end)

    base = if is_map(task.metadata), do: task.metadata, else: %{}

    {:ok, updated} =
      task
      |> Task.changeset(%{metadata: Map.put(base, "reserved_migration_slots", entries)})
      |> Repo.update()

    updated
  end

  defp forge_raw_metadata!(%Task{} = task, value) do
    base = if is_map(task.metadata), do: task.metadata, else: %{}

    {:ok, updated} =
      task
      |> Task.changeset(%{metadata: Map.put(base, "reserved_migration_slots", value)})
      |> Repo.update()

    updated
  end

  @collision_event [:platform, :stacks, :migration_slot, :collision]

  defp attach_collision_handler! do
    handler_id = :telemetry_test.attach_event_handlers(self(), [@collision_event])
    # Telemetry handlers are process-global. Detaching in `on_exit` keeps
    # a collision fired by a sibling test from landing in a later test's
    # mailbox — leaked handlers are a classic source of order-dependent
    # flakes in this suite.
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Builds a 2-member chain A -> B with wave 0 (A) already planning and
  # A's plan approved, so the next `advance_planning_waves/1` dispatches
  # wave 1 (B).
  defp chain_ready_to_advance do
    {:ok, project} = Tasks.create_project(%{name: "Advance Audit #{uniq()}"})
    slug = "advance-audit-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Advance Audit Stack #{slug}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    # Manual-mode dispatch refuses members with no dispatchable planning
    # assignee (Stacks.dispatchable_planning_assignee?/2), so give each a
    # planner agent.
    {:ok, a} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "A #{uniq()}",
        phase_assignees: %{
          "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, b} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "B #{uniq()}",
        phase_assignees: %{
          "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, a} = Stacks.add_task(stack, a)
    {:ok, b} = Stacks.add_task(stack, b)
    {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)

    {:ok, %{planning: [_a]}} = Stacks.start_planning(stack)
    {:ok, _} = Tasks.create_plan(%{task_id: a.id, status: "approved"})

    {stack, a, b}
  end

  # ── audit_migration_slots/1 ───────────────────────────────────────────────

  describe "audit_migration_slots/1 — clean" do
    test "three members with distinct slots audit clean" do
      {stack, [a, b, c]} = stack_with_members(3)

      forge_slots!(a, ["20260719120000"])
      forge_slots!(b, ["20260719120001"])
      forge_slots!(c, ["20260719120002"])

      assert {:ok, %{slots: slots, collisions: []}} = Stacks.audit_migration_slots(stack)
      assert length(slots) == 3

      assert Enum.map(slots, & &1.timestamp) |> Enum.sort() ==
               ["20260719120000", "20260719120001", "20260719120002"]

      assert Enum.map(slots, & &1.task_id) |> Enum.sort() == Enum.sort([a.id, b.id, c.id])
    end

    test "a stack whose members carry no reservations audits clean" do
      {stack, _members} = stack_with_members(3)

      assert {:ok, %{slots: [], collisions: []}} = Stacks.audit_migration_slots(stack)
    end

    test "one member holding several distinct slots audits clean" do
      {stack, [a | _]} = stack_with_members(2)

      forge_slots!(a, ["20260719120000", "20260719120001", "20260719120002"])

      assert {:ok, %{slots: slots, collisions: []}} = Stacks.audit_migration_slots(stack)
      assert length(slots) == 3
    end

    test "slots issued by the real allocator never collide" do
      {stack, [a, b, c]} = stack_with_members(3)

      for member <- [a, b, c] do
        {:ok, ts} = Stacks.allocate_migration_slot(stack)
        forge_slots!(member, [ts])
      end

      assert {:ok, %{collisions: []}} = Stacks.audit_migration_slots(stack)
    end

    test "accepts a bare stack_id binary as well as a %Stack{}" do
      {stack, [a, b]} = stack_with_members(2)

      forge_slots!(a, ["20260719120000"])
      forge_slots!(b, ["20260719120001"])

      assert {:ok, %{collisions: []}} = Stacks.audit_migration_slots(stack.id)
    end

    test "unknown stack id returns :stack_not_found" do
      assert {:error, :stack_not_found} = Stacks.audit_migration_slots(Ecto.UUID.generate())
    end
  end

  describe "audit_migration_slots/1 — collisions" do
    test "two members claiming the same timestamp is reported" do
      {stack, [a, b, c]} = stack_with_members(3)

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])
      forge_slots!(c, ["20260719120002"])

      assert {:error, :collision, [offender]} = Stacks.audit_migration_slots(stack)
      assert offender.timestamp == "20260717000000"
      assert offender.offenders == Enum.sort([a.id, b.id])
    end

    test "three-way collision lists every offending task" do
      {stack, [a, b, c]} = stack_with_members(3)

      for m <- [a, b, c], do: forge_slots!(m, ["20260717000000"])

      assert {:error, :collision, [offender]} = Stacks.audit_migration_slots(stack)
      assert offender.offenders == Enum.sort([a.id, b.id, c.id])
    end

    test "multiple independent collisions are all reported, sorted by timestamp" do
      {stack, [a, b, c]} = stack_with_members(3)

      forge_slots!(a, ["20260717000000", "20260718000000"])
      forge_slots!(b, ["20260717000000"])
      forge_slots!(c, ["20260718000000"])

      assert {:error, :collision, offenders} = Stacks.audit_migration_slots(stack)
      assert Enum.map(offenders, & &1.timestamp) == ["20260717000000", "20260718000000"]
    end

    test "a single member claiming the same timestamp twice is still a collision" do
      # Impossible via the allocator, but it is a genuine duplicate and
      # the point of a backstop is to be loud about the unexpected.
      {stack, [a | _]} = stack_with_members(2)

      forge_slots!(a, ["20260717000000", "20260717000000"])

      assert {:error, :collision, [offender]} = Stacks.audit_migration_slots(stack)
      assert offender.offenders == [a.id]
    end

    test "a soft-deleted member's slots are excluded from the audit" do
      {stack, [a, b]} = stack_with_members(2)

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])

      assert {:error, :collision, _} = Stacks.audit_migration_slots(stack)

      {:ok, _} = Tasks.soft_delete_task(b)

      assert {:ok, %{collisions: []}} = Stacks.audit_migration_slots(stack)
    end

    test "members of a different stack do not collide with each other" do
      {stack_one, [a]} = stack_with_members(1)
      {stack_two, [b]} = stack_with_members(1)

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])

      assert {:ok, %{collisions: []}} = Stacks.audit_migration_slots(stack_one)
      assert {:ok, %{collisions: []}} = Stacks.audit_migration_slots(stack_two)
    end
  end

  describe "audit_migration_slots/1 — malformed metadata" do
    test "skips entries missing a timestamp, blank, or non-map" do
      {stack, [a | _]} = stack_with_members(2)

      forge_raw_metadata!(a, [
        %{"stage_id" => Ecto.UUID.generate(), "stage_name" => "No ts"},
        %{"timestamp" => ""},
        %{"timestamp" => 12_345},
        "not-a-map",
        nil,
        %{"timestamp" => "20260719120000"}
      ])

      assert {:ok, %{slots: [slot], collisions: []}} = Stacks.audit_migration_slots(stack)
      assert slot.timestamp == "20260719120000"
    end

    test "a non-list reserved_migration_slots value is ignored" do
      {stack, [a | _]} = stack_with_members(2)

      forge_raw_metadata!(a, %{"timestamp" => "20260719120000"})

      assert {:ok, %{slots: [], collisions: []}} = Stacks.audit_migration_slots(stack)
    end

    test "malformed metadata on one member does not mask a real collision on others" do
      {stack, [a, b, c]} = stack_with_members(3)

      forge_raw_metadata!(a, "garbage")
      forge_slots!(b, ["20260717000000"])
      forge_slots!(c, ["20260717000000"])

      assert {:error, :collision, [offender]} = Stacks.audit_migration_slots(stack)
      assert offender.offenders == Enum.sort([b.id, c.id])
    end
  end

  # ── advance_planning_waves/1 integration ──────────────────────────────────

  describe "advance_planning_waves/1 collision backstop" do
    test "a colliding stack still dispatches the wave, and logs ERROR" do
      {stack, a, b} = chain_ready_to_advance()

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])

      {result, log} =
        with_log(fn -> Stacks.advance_planning_waves(stack) end)

      # The load-bearing assertion: the guard is log-only. The wave
      # dispatched despite the collision.
      assert {:ok, %{dispatched: [dispatched], wave_index: 1}} = result
      assert dispatched.id == b.id
      assert dispatched.status == "planning"
      assert Tasks.get_task_record(b.id).status == "planning"

      assert log =~ "[Stacks] migration slot collision detected"
      assert log =~ stack.id
      assert log =~ "20260717000000"
    end

    test "fires the collision telemetry event with offender metadata" do
      attach_collision_handler!()
      {stack, a, b} = chain_ready_to_advance()

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])

      capture_log(fn ->
        assert {:ok, %{wave_index: 1}} = Stacks.advance_planning_waves(stack)
      end)

      assert_receive {@collision_event, _ref, %{count: 1}, %{stack_id: stack_id} = meta}
      assert stack_id == stack.id
      assert [%{timestamp: "20260717000000", offenders: offenders}] = meta.offenders
      assert offenders == Enum.sort([a.id, b.id])
    end

    test "a clean stack neither logs nor fires the collision event" do
      attach_collision_handler!()
      {stack, a, b} = chain_ready_to_advance()

      forge_slots!(a, ["20260719120000"])
      forge_slots!(b, ["20260719120001"])

      {result, log} = with_log(fn -> Stacks.advance_planning_waves(stack) end)

      assert {:ok, %{wave_index: 1}} = result
      refute log =~ "migration slot collision detected"
      refute_receive {@collision_event, _ref, _measurements, _meta}, 100
    end

    test "no-op advances do not run the audit" do
      attach_collision_handler!()
      {:ok, project} = Tasks.create_project(%{name: "Advance Noop #{uniq()}"})
      slug = "advance-noop-#{uniq()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Advance Noop Stack #{slug}",
          rollup_branch: Stacks.rollup_branch_name(slug)
        })

      {:ok, a} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "A #{uniq()}",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B #{uniq()}",
          phase_assignees: %{
            "planning" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
          }
        })

      {:ok, a} = Stacks.add_task(stack, a)
      {:ok, b} = Stacks.add_task(stack, b)
      {:ok, _} = Stacks.add_dependency_edge(stack, b.id, a.id)
      {:ok, %{planning: [_a]}} = Stacks.start_planning(stack)

      forge_slots!(a, ["20260717000000"])
      forge_slots!(b, ["20260717000000"])

      # Wave 0's plan is not approved, so nothing advances — and the
      # audit, which hangs off the dispatch path, does not run.
      assert {:ok, :noop, :upstream_incomplete} = Stacks.advance_planning_waves(stack)
      refute_receive {@collision_event, _ref, _measurements, _meta}, 100
    end
  end
end
