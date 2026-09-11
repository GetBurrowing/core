defmodule Platform.Tasks.UpdateTaskIfUnmodifiedTest do
  @moduledoc """
  Tests for `Platform.Tasks.update_task_if_unmodified/4` — the compare-and-set
  writer that refuses a write composed against a stale `updated_at`.

  There is deliberately NO `Process.sleep` and no timing assertion in this
  file. Both writers are composed against ONE captured base, so no wall-clock
  gap is needed to create the conflict — a sleep here would only measure
  itself. There is also deliberately no assertion that two successive writes
  produce two DIFFERENT `updated_at` values: that is already true on main and
  so proves nothing about this change. The subject is the REFUSAL.
  """

  # NOT async: `update_task/3` broadcasts `{:task_updated, task}` on the
  # `tasks:board` topic, which the singleton `TaskRouterWatcher` consumes from
  # a process that does not own an async test's sandbox connection. A sync
  # module puts the sandbox in shared mode so that consumer is legal.
  use Platform.DataCase

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    {:ok, project} = Tasks.create_project(%{name: "CAS Project"})
    %{project: project}
  end

  defp insert_task(project, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Task{
          project_id: project.id,
          title: "CAS subject",
          status: "planning",
          description: "seed"
        },
        attrs
      )
    )
  end

  defp stored(task), do: Repo.get(Task, task.id)

  describe "update_task_if_unmodified/4" do
    test "refuses a second writer composed against the same stale base", %{project: project} do
      task = insert_task(project)
      base = task.updated_at

      # Writer A: base is current, so it lands.
      assert {:ok, %Task{} = a} = Tasks.update_task_if_unmodified(task, %{description: "A"}, base)
      assert a.description == "A"

      # Writer B composes against the SAME struct and the SAME base it read
      # before A wrote. It must NOT re-read — re-reading would silently repair
      # the staleness this test exists to detect.
      assert {:error, {:stale_base, detail}} =
               Tasks.update_task_if_unmodified(task, %{description: "B"}, base)

      assert detail.base_updated_at == base
      assert detail.current_updated_at == a.updated_at

      # The refusal is a refusal, not a warning: nothing was written.
      assert stored(task).description == "A"
    end

    test "positive control: a write whose base IS current succeeds and applies", %{
      project: project
    } do
      task = insert_task(project)

      assert {:ok, %Task{} = updated} =
               Tasks.update_task_if_unmodified(task, %{description: "first"}, task.updated_at)

      assert updated.description == "first"

      # And again, against the freshly-advanced base — so an implementation
      # that refuses every call carrying a base cannot pass this test.
      assert {:ok, %Task{} = second} =
               Tasks.update_task_if_unmodified(
                 updated,
                 %{description: "second"},
                 updated.updated_at
               )

      assert second.description == "second"
      assert stored(task).description == "second"
    end

    test "the guard is on the base, not on the struct it was handed", %{project: project} do
      task = insert_task(project)
      stale_base = task.updated_at

      {:ok, advanced} = Tasks.update_task(task, %{description: "elsewhere"})

      # `advanced` IS current, but the caller supplies the base its edit was
      # actually composed against. The WHERE clause pins the supplied base, so
      # this is still refused.
      assert {:error, {:stale_base, detail}} =
               Tasks.update_task_if_unmodified(advanced, %{description: "mine"}, stale_base)

      assert detail.current_updated_at == advanced.updated_at
      assert stored(task).description == "elsewhere"
    end

    test "an invalid changeset is returned as a changeset error, not a stale base", %{
      project: project
    } do
      task = insert_task(project)

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Tasks.update_task_if_unmodified(task, %{title: nil}, task.updated_at)

      assert stored(task).title == "CAS subject"
    end

    test "a successful guarded write broadcasts {:task_updated, _} exactly once", %{
      project: project
    } do
      task = insert_task(project)
      Tasks.subscribe_board()

      assert {:ok, _} =
               Tasks.update_task_if_unmodified(task, %{description: "bcast"}, task.updated_at)

      assert_receive {:task_updated, %Task{}}, 1_000
      refute_receive {:task_updated, %Task{}}, 200
    end

    test "a refused write broadcasts nothing", %{project: project} do
      task = insert_task(project)
      base = task.updated_at
      {:ok, _} = Tasks.update_task_if_unmodified(task, %{description: "A"}, base)

      Tasks.subscribe_board()

      assert {:error, {:stale_base, _}} =
               Tasks.update_task_if_unmodified(task, %{description: "B"}, base)

      refute_receive {:task_updated, %Task{}}, 200
    end
  end

  describe "update_task/3 back-compat" do
    test "still succeeds against a row another writer just advanced", %{project: project} do
      task = insert_task(project)

      {:ok, _other} = Tasks.update_task(task, %{description: "other writer"})

      # The original struct is now stale, and `update_task/3` does not care —
      # last-write-wins is the pre-existing contract and every current caller
      # depends on it. Making the base mandatory would wedge all of them.
      assert {:ok, %Task{description: "mine"}} = Tasks.update_task(task, %{description: "mine"})
      assert stored(task).description == "mine"
    end
  end
end
