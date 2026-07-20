defmodule Platform.Tasks.PlanMigrationReservationTest do
  @moduledoc """
  Task 019f7b7e stage 2 — migration-slot reservation at plan-approval time.

  Covers the `approve_plan/3` hook that detects migration-authoring stages
  and reserves a per-stack timestamp from `Stacks.allocate_migration_slot/1`,
  stashing it on `task.metadata["reserved_migration_slots"]`.

  `async: false` mirrors the rest of the stack test suite: `approve_plan/3`
  broadcasts on the board PubSub and fires the stack planning cascade, both
  of which touch process-global state.
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stacks, Task}

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp project! do
    {:ok, project} = Tasks.create_project(%{name: "Reservation Project #{uniq()}"})
    project
  end

  defp stack_with_members(count) do
    project = project!()
    slug = "reserve-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Reservation Stack #{slug}",
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

  defp solo_task! do
    project = project!()
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Solo #{uniq()}"})
    task
  end

  # A description that trips `@migration_marker_regex`.
  @migration_desc """
  Add the column. Create `apps/platform/priv/repo/migrations/xxx_add_thing.exs`
  with `use Ecto.Migration` and `alter table(:things)`.
  """

  @plain_desc """
  Refactor the LiveView so the assigns are computed once. No schema work,
  no database changes, pure presentation layer.
  """

  # Builds a `pending_review` plan carrying one stage per description given.
  defp plan_with_stages!(%Task{} = task, descriptions) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    stages =
      descriptions
      |> Enum.with_index(1)
      |> Enum.map(fn {description, position} ->
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: position,
            name: "Stage #{position}",
            description: description
          })

        stage
      end)

    {:ok, plan} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

    {plan, stages}
  end

  defp reservations(%Task{} = task), do: reservations(task.id)

  defp reservations(task_id) when is_binary(task_id) do
    Repo.get!(Task, task_id).metadata
    |> Kernel.||(%{})
    |> Map.get("reserved_migration_slots", [])
  end

  # ── Distinct slots across a stack ─────────────────────────────────────────

  describe "approve_plan/3 — stack members" do
    test "three members each authoring a migration receive three distinct slots" do
      {_stack, members} = stack_with_members(3)

      Enum.each(members, fn member ->
        {plan, _stages} = plan_with_stages!(member, [@migration_desc])
        assert {:ok, _approved} = Tasks.approve_plan(plan, "reviewer:test")
      end)

      all = Enum.map(members, &reservations/1)

      # Exactly one reservation per member.
      assert Enum.map(all, &length/1) == [1, 1, 1]

      timestamps = Enum.map(all, fn [entry] -> entry["timestamp"] end)

      # Distinct, and in the canonical `mix ecto.gen.migration` format.
      assert MapSet.size(MapSet.new(timestamps)) == 3
      assert Enum.all?(timestamps, &Regex.match?(~r/^\d{14}$/, &1))
    end

    test "reservation carries stage_id, stage_name, timestamp and allocated_at" do
      {_stack, [member]} = stack_with_members(1)
      {plan, [stage]} = plan_with_stages!(member, [@migration_desc])

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")

      assert [entry] = reservations(member)
      assert entry["stage_id"] == stage.id
      assert entry["stage_name"] == stage.name
      assert Regex.match?(~r/^\d{14}$/, entry["timestamp"])
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(entry["allocated_at"])
    end

    test "the stack cursor advances so a later member cannot reuse the slot" do
      {stack, [m1, m2]} = stack_with_members(2)

      {p1, _} = plan_with_stages!(m1, [@migration_desc])
      assert {:ok, _} = Tasks.approve_plan(p1, "reviewer:test")
      [%{"timestamp" => t1}] = reservations(m1)

      {p2, _} = plan_with_stages!(m2, [@migration_desc])
      assert {:ok, _} = Tasks.approve_plan(p2, "reviewer:test")
      [%{"timestamp" => t2}] = reservations(m2)

      refute t1 == t2
      assert t1 < t2
      refute is_nil(Repo.reload!(stack).next_migration_slot)
    end

    test "a plan with several migration stages reserves one slot per stage" do
      {_stack, [member]} = stack_with_members(1)

      {plan, _stages} =
        plan_with_stages!(member, [@migration_desc, @plain_desc, @migration_desc])

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")

      entries = reservations(member)
      assert length(entries) == 2
      assert MapSet.size(MapSet.new(entries, & &1["timestamp"])) == 2
    end
  end

  # ── Detection accuracy ────────────────────────────────────────────────────

  describe "migration detection" do
    test "a stage description with no migration marker reserves nothing" do
      {_stack, [member]} = stack_with_members(1)
      {plan, _} = plan_with_stages!(member, [@plain_desc])

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")
      assert reservations(member) == []
    end

    test "a nil stage description is treated as non-authoring" do
      {_stack, [member]} = stack_with_members(1)
      {:ok, plan} = Tasks.create_plan(%{task_id: member.id})

      {:ok, _stage} =
        Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "No description"})

      {:ok, plan} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")
      assert reservations(member) == []
    end

    for {label, snippet} <- [
          {"migrations path", "touches apps/platform/priv/repo/migrations/ here"},
          {"gen task", "run mix ecto.gen.migration add_widget_flag"},
          {"use directive", "the module will `use Ecto.Migration`"},
          {"create table", "create table(:widgets) do ... end"},
          {"alter table", "alter table(:widgets) add :flag, :boolean"}
        ] do
      test "reserves for the #{label} marker" do
        {_stack, [member]} = stack_with_members(1)
        {plan, _} = plan_with_stages!(member, [unquote(snippet)])

        assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")
        assert [_entry] = reservations(member)
      end
    end

    test "detection is case-insensitive" do
      {_stack, [member]} = stack_with_members(1)
      {plan, _} = plan_with_stages!(member, ["Run MIX ECTO.GEN.MIGRATION add_thing"])

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")
      assert [_entry] = reservations(member)
    end
  end

  # ── Idempotency on re-approval ────────────────────────────────────────────

  describe "re-approval" do
    test "re-approving a plan whose stages carried over does not double-reserve" do
      {_stack, [member]} = stack_with_members(1)
      {v1, [stage]} = plan_with_stages!(member, [@migration_desc])

      assert {:ok, _} = Tasks.approve_plan(v1, "reviewer:test")
      assert [%{"timestamp" => original}] = reservations(member)

      # Simulate the reject → revise loop: the operator bounces v1 and the
      # planner resubmits v2 that reuses the SAME stage rows.
      {:ok, v1} = v1 |> Plan.changeset(%{status: "rejected"}) |> Repo.update()
      {:ok, v2} = Tasks.create_plan(%{task_id: member.id})

      {:ok, _} = stage |> Platform.Tasks.Stage.changeset(%{plan_id: v2.id}) |> Repo.update()
      {:ok, v2} = v2 |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      assert {:ok, _} = Tasks.approve_plan(v2, "reviewer:test")

      # Same stage id ⇒ same reservation, no second slot burned.
      assert [%{"timestamp" => ^original, "stage_id" => stage_id}] = reservations(member)
      assert stage_id == stage.id
      refute v1.id == v2.id
    end

    test "a reservation for a stage dropped from the revised plan is discarded" do
      {_stack, [member]} = stack_with_members(1)
      {v1, [old_stage]} = plan_with_stages!(member, [@migration_desc])

      assert {:ok, _} = Tasks.approve_plan(v1, "reviewer:test")
      assert [%{"stage_id" => old_id}] = reservations(member)
      assert old_id == old_stage.id

      # v2 replaces the stage entirely — the planner rewrote the breakdown.
      {:ok, _} = v1 |> Plan.changeset(%{status: "rejected"}) |> Repo.update()
      {v2, [new_stage]} = plan_with_stages!(member, [@migration_desc])

      assert {:ok, _} = Tasks.approve_plan(v2, "reviewer:test")

      entries = reservations(member)
      assert length(entries) == 1, "stale reservation leaked: #{inspect(entries)}"
      assert [%{"stage_id" => new_id}] = entries
      assert new_id == new_stage.id
      refute new_id == old_id
    end
  end

  # ── Solo-task guard ───────────────────────────────────────────────────────

  describe "solo tasks" do
    test "a task with no stack_id gets no reservation even with a migration stage" do
      task = solo_task!()
      assert task.stack_id == nil

      {plan, _} = plan_with_stages!(task, [@migration_desc])
      before = Repo.get!(Task, task.id).metadata

      assert {:ok, _} = Tasks.approve_plan(plan, "reviewer:test")

      reloaded = Repo.get!(Task, task.id)
      refute Map.has_key?(reloaded.metadata || %{}, "reserved_migration_slots")
      assert (reloaded.metadata || %{}) == (before || %{})
    end
  end

  # ── Rollback on allocator failure ─────────────────────────────────────────

  describe "allocator failure" do
    test "approval is rolled back when the stack row is missing" do
      {stack, [member]} = stack_with_members(1)
      {plan, _} = plan_with_stages!(member, [@migration_desc])

      # Orphan the member: point `stack_id` at a stack that does not exist so
      # `allocate_migration_slot/1` hits its `:stack_not_found` branch. The
      # `tasks.stack_id` FK is `ON DELETE SET NULL`, so deleting the stack
      # would nil the column instead of orphaning it — we disable FK triggers
      # for this session to force the state the allocator must defend against.
      ghost_id = Ecto.UUID.generate()
      Repo.query!("SET session_replication_role = replica")

      Repo.query!("UPDATE tasks SET stack_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(ghost_id),
        Ecto.UUID.dump!(member.id)
      ])

      Repo.query!("SET session_replication_role = DEFAULT")

      assert Repo.get!(Task, member.id).stack_id == ghost_id
      assert is_nil(Repo.get(Platform.Tasks.Stack, ghost_id))

      assert {:error, _reason} = Tasks.approve_plan(plan, "reviewer:test")

      # The whole transaction unwound: the plan is still awaiting review and
      # no reservation was written.
      assert Repo.get!(Plan, plan.id).status == "pending_review"
      assert reservations(member) == []

      # And the real stack's cursor never advanced.
      assert is_nil(Repo.reload!(stack).next_migration_slot)
    end
  end

  # ── Auto-approve path ─────────────────────────────────────────────────────

  describe "auto-approve" do
    test "an auto_accept_plan stack reserves via maybe_auto_approve/1 with no extra wiring" do
      project = project!()
      slug = "auto-#{uniq()}"

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Auto Stack #{slug}",
          rollup_branch: Stacks.rollup_branch_name(slug),
          auto_accept_plan: true
        })

      # A top-level assignee satisfies BOTH the execution and review
      # preconditions in `auto_approve_precondition/2`, so the plan really
      # takes the auto path rather than stalling in `pending_review`.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto member #{uniq()}",
          assignee_id: Ecto.UUID.generate(),
          assignee_type: "agent"
        })

      {:ok, member} = Stacks.add_task(stack, task)

      {:ok, plan} = Tasks.create_plan(%{task_id: member.id})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Migration stage",
          description: @migration_desc
        })

      assert {:ok, submitted} = Tasks.submit_plan_for_review(plan)

      # `maybe_auto_approve/1` routes through `approve_plan/3` internally, so
      # the reservation rides along with zero extra wiring. Assert the auto
      # path actually fired rather than assuming it.
      approved = Repo.get!(Plan, submitted.id)
      assert approved.status == "approved"
      refute is_nil(approved.auto_approved_at)

      assert [%{"timestamp" => ts}] = reservations(member)
      assert Regex.match?(~r/^\d{14}$/, ts)
    end
  end
end
