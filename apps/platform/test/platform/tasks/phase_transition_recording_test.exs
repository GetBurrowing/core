defmodule Platform.Tasks.PhaseTransitionRecordingTest do
  @moduledoc """
  Every executed status write must produce exactly one transition row, and
  every non-status write must produce none.

  These tests drive the REAL public writers rather than calling
  `PhaseTransitions.record/2` directly — the property under test is that the
  choke point in `Platform.Tasks.Task.changeset/2` catches writers that never
  went near `transition_task/3`, which is only observable through the writers
  themselves.
  """

  use Platform.DataCase

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, Task}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Transition Project"})
    %{project: project}
  end

  defp user_fixture do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Sponsor #{n}",
      email: "sponsor-#{n}@example.com",
      oidc_sub: "transition-sub-#{n}"
    })
  end

  defp task_fixture(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "Transition Task"}, attrs))

    task
  end

  # A task whose sponsor-bypass legs are satisfied, so a human actor can move
  # it into an execution phase without an approved plan.
  defp sponsored_task(project) do
    user = user_fixture()
    {user, task_fixture(project, %{sponsor_user_id: user.id})}
  end

  defp rows(task_id), do: PhaseTransitions.list_for_task(task_id)

  # A plan sitting in `pending_review`, which is the only status
  # `approve_plan/3` accepts.
  defp pending_review_plan(%Task{} = task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    plan
    |> Ecto.Changeset.change(%{status: "pending_review"})
    |> Repo.update!()
  end

  describe "the choke point records executed status writes" do
    test "create_task/1 records nothing — insert is skipped by design", %{project: project} do
      task = task_fixture(project)

      assert rows(task.id) == []
    end

    test "transition_task/3 with a user actor records a user-attributed row", %{
      project: project
    } do
      {user, task} = sponsored_task(project)

      assert {:ok, _updated} = Tasks.transition_task(task, "in_progress", {:user, user.id})

      assert [row] = rows(task.id)
      assert row.from_status == "backlog"
      assert row.to_status == "in_progress"
      assert row.actor_kind == "user"
      assert row.actor_id == user.id
      assert row.via == "transition_task"
    end

    # `sponsor_bypasses_plan_gate?/2` only recognises the `{:user, id}` tuple,
    # so a bare struct is used here on a transition that does not touch the
    # plan gate. The point is the attribution, not the gate.
    test "a bare %User{} struct actor also normalizes to user", %{project: project} do
      {user, task} = sponsored_task(project)

      assert {:ok, _} = Tasks.transition_task(task, "planning", user)

      assert [row] = rows(task.id)
      assert row.actor_kind == "user"
      assert row.actor_id == user.id
    end

    test "transition_task/2 records a system-attributed row", %{project: project} do
      task = task_fixture(project)

      assert {:ok, _} = Tasks.transition_task(task, "planning")

      assert [row] = rows(task.id)
      assert row.to_status == "planning"
      assert row.actor_kind == "system"
      assert is_nil(row.actor_id)
      assert row.via == "transition_task"
    end

    test "transition_task_status/2 with no surrounding context records unknown", %{
      project: project
    } do
      task = task_fixture(project)

      assert {:ok, _} = Tasks.transition_task_status(task, "planning")

      assert [row] = rows(task.id)
      assert row.to_status == "planning"
      # The honest default. An unattributed write must be visibly
      # unattributed, never silently filed as engine time.
      assert row.actor_kind == "unknown"
      assert is_nil(row.actor_id)
      assert is_nil(row.via)
    end

    test "drop_task_to_column/3 records the human-drag path", %{project: project} do
      {user, task} = sponsored_task(project)

      assert {:ok, _} = Tasks.drop_task_to_column(task, "in_progress", {:user, user.id})

      assert [row] = rows(task.id)
      assert row.from_status == "backlog"
      assert row.to_status == "in_progress"
      assert row.actor_kind == "user"
      assert row.via == "drop_task_to_column"
    end

    test "update_task/3 writing a status is caught even though it never sees transition_task",
         %{project: project} do
      task = task_fixture(project)

      assert {:ok, _} = Tasks.update_task(task, %{status: "planning"})

      assert [row] = rows(task.id)
      assert row.from_status == "backlog"
      assert row.to_status == "planning"
      assert row.actor_kind == "unknown"
    end
  end

  describe "the choke point stays silent when it should" do
    test "update_task/3 writing only a title records nothing", %{project: project} do
      task = task_fixture(project)

      assert {:ok, _} = Tasks.update_task(task, %{title: "Renamed"})

      assert rows(task.id) == []
    end

    test "a build-only changeset (the LiveView form path) records nothing", %{project: project} do
      task = task_fixture(project)

      changeset =
        task
        |> Task.changeset(%{status: "planning"})
        |> Map.put(:action, :validate)

      assert changeset.valid?
      # Never touched the repo, so `prepare_changes` never ran.
      assert rows(task.id) == []
    end

    test "an illegal transition records nothing", %{project: project} do
      task = task_fixture(project)

      assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "done")
      assert rows(task.id) == []
    end
  end

  describe "same-transaction semantics" do
    test "a rolled-back transition leaves no row", %{project: project} do
      task = task_fixture(project)

      assert {:error, :abort} =
               Repo.transaction(fn ->
                 {:ok, _} = Tasks.transition_task_status(task, "planning")
                 Repo.rollback(:abort)
               end)

      # Both the status change and its transition row went back together.
      # This is the property `prepare_changes/2` was chosen for.
      assert Repo.get!(Task, task.id).status == "backlog"
      assert rows(task.id) == []
    end

    test "a committed in_progress transition (which rides its own transaction) persists", %{
      project: project
    } do
      {user, task} = sponsored_task(project)

      assert {:ok, updated} = Tasks.transition_task(task, "in_progress", {:user, user.id})
      assert updated.status == "in_progress"

      assert [%{to_status: "in_progress"}] = rows(task.id)
    end
  end

  describe "re-entry" do
    test "a task that revisits a status records every visit in order", %{project: project} do
      {user, task} = sponsored_task(project)

      {:ok, task} = Tasks.transition_task(task, "in_progress", {:user, user.id})
      {:ok, task} = Tasks.transition_task(task, "in_review")
      {:ok, task} = Tasks.transition_task(task, "in_progress")
      {:ok, _task} = Tasks.transition_task(task, "in_review")

      pairs = Enum.map(rows(task.id), &{&1.from_status, &1.to_status})

      assert pairs == [
               {"backlog", "in_progress"},
               {"in_progress", "in_review"},
               {"in_review", "in_progress"},
               {"in_progress", "in_review"}
             ]
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Task 01a094d4 stage 4: the status-writer inventory.
  #
  # Every status writer reachable outside `transition_task/3` is wrapped and
  # names its own path in `via`. Each test below asserts the SPECIFIC via
  # string for its path, not `refute is_nil(via)` — a per-path assertion
  # cannot pass on a row some other writer happened to leave behind.
  # ──────────────────────────────────────────────────────────────────────
  describe "stamped writers name their own path in via" do
    test "promote/2 from the kanban badge attributes the clicking user", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{needs_promotion: true})

      assert {:ok, updated} = Tasks.promote(task, {:user, user.id})
      assert updated.status == "planning"

      assert [row] = rows(task.id)
      assert {row.from_status, row.to_status} == {"backlog", "planning"}
      assert row.via == "board_promote"
      assert row.actor_kind == "user"
      assert row.actor_id == user.id
    end

    test "promote/1 with no caller threaded records unknown WITH a via", %{project: project} do
      task = task_fixture(project, %{needs_promotion: true})

      assert {:ok, _} = Tasks.promote(task)

      assert [row] = rows(task.id)
      # The whole point of the stage: known code path, caller not
      # identifiable. Distinguishable from a not-captured write only
      # because `via` is non-nil.
      assert row.via == "board_promote"
      assert row.actor_kind == "unknown"
      assert is_nil(row.actor_id)
      assert is_nil(row.actor_label)
    end

    test "promote/2 on a non-backlog task writes no row at all", %{project: project} do
      user = user_fixture()

      {:ok, task} =
        Tasks.transition_task(task_fixture(project, %{needs_promotion: true}), "planning")

      assert {:ok, updated} = Tasks.promote(task, {:user, user.id})
      refute updated.needs_promotion

      # One row, from the `transition_task/2` setup above — the promote
      # itself cleared a flag and moved no status.
      assert [%{via: "transition_task"}] = rows(task.id)
    end

    test "stamp_blocked_reason/2 attributes the router escalation to the engine", %{
      project: project
    } do
      task = task_fixture(project)

      assert {:ok, blocked} = Tasks.stamp_blocked_reason(task, "no ack in 5m")
      assert blocked.status == "blocked"

      assert [row] = rows(task.id)
      assert row.to_status == "blocked"
      assert row.via == "blocked_escalation"
      # `:system` and not `:unattributed`: the TaskRouter genuinely decided
      # this, so filing it as engine time is honest rather than a guess.
      assert row.actor_kind == "system"
      assert row.actor_label == "system:auto"
      assert is_nil(row.actor_id)
    end

    test "stamp_blocked_reason/2 on an already-blocked task records nothing new", %{
      project: project
    } do
      task = task_fixture(project)
      {:ok, blocked} = Tasks.stamp_blocked_reason(task, "first")

      assert {:ok, _} = Tasks.stamp_blocked_reason(blocked, "second")

      # `ensure_blocked/1` short-circuits; the metadata write is a
      # plain-field update and the choke point stays silent.
      assert [_only_one] = rows(task.id)
    end

    test "approve_plan/2's dispatch gate attributes the approving human", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{status: "planning"})
      plan = pending_review_plan(task)

      assert {:ok, _} = Tasks.approve_plan(plan, user.id)

      assert [row] = rows(task.id)
      assert {row.from_status, row.to_status} == {"planning", "in_progress"}
      assert row.via == "plan_approval_dispatch_gate"
      assert row.actor_kind == "user"
      # NOT merely "some user": a bare binary would normalize to
      # {"agent", id} without `approval_actor/1` resolving it first.
      assert row.actor_id == user.id
    end

    test "approve_plan/2 by an id that is no user records unknown WITH a via", %{
      project: project
    } do
      task = task_fixture(project, %{status: "planning"})
      plan = pending_review_plan(task)

      # The MCP `plan_approve` default and any non-user id land here.
      assert {:ok, _} = Tasks.approve_plan(plan, Ecto.UUID.generate())

      assert [row] = rows(task.id)
      assert row.via == "plan_approval_dispatch_gate"
      assert row.actor_kind == "unknown"
      assert is_nil(row.actor_id)
    end

    test "the cleanup mix task stamps its path and refuses to claim :system", %{
      project: project
    } do
      {:ok, task} = Tasks.transition_task(task_fixture(project), "planning")

      assert :cleaned = Mix.Tasks.Platform.CleanupGhostTasks.cleanup_one(task.id)

      assert [_planning, cancel_row] = rows(task.id)
      assert cancel_row.to_status == "cancelled"
      assert cancel_row.via == "cleanup_ghost_tasks"
      # An operator at a shell. Their identity never enters the BEAM, so
      # `:system` would be a lie about WHO, not just a missing WHO.
      assert cancel_row.actor_kind == "unknown"
      assert is_nil(cancel_row.actor_id)
    end
  end

  # The inventory assertion. Not a substitute for the per-path tests above
  # (a set can be satisfied by the wrong row); it exists so that ADDING an
  # unwrapped writer to one of these paths is caught by a test that names
  # the whole set, and so the via strings cannot silently drift apart.
  describe "inventory" do
    test "the four newly-stamped paths emit four distinct via strings", %{project: project} do
      user = user_fixture()

      promoted = task_fixture(project, %{needs_promotion: true})
      {:ok, _} = Tasks.promote(promoted, {:user, user.id})

      blocked = task_fixture(project)
      {:ok, _} = Tasks.stamp_blocked_reason(blocked, "stalled")

      approved = task_fixture(project, %{status: "planning"})
      {:ok, _} = Tasks.approve_plan(pending_review_plan(approved), user.id)

      swept = task_fixture(project)
      {:ok, _} = Tasks.transition_task(swept, "planning")
      :cleaned = Mix.Tasks.Platform.CleanupGhostTasks.cleanup_one(swept.id)

      vias =
        [promoted, blocked, approved, swept]
        |> Enum.flat_map(fn t -> Enum.map(rows(t.id), & &1.via) end)
        |> Enum.reject(&(&1 == "transition_task"))
        |> Enum.sort()

      assert vias == [
               "blocked_escalation",
               "board_promote",
               "cleanup_ghost_tasks",
               "plan_approval_dispatch_gate"
             ]

      refute Enum.any?(vias, &is_nil/1)
    end
  end
end
