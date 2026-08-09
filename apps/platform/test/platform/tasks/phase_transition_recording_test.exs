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
end
