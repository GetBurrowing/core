defmodule Platform.Tasks.PhaseTransitionsTest do
  use Platform.DataCase

  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransition, PhaseTransitions}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Phase Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Phase Task"})

    %{task: task}
  end

  # `Platform.DataCase` does not export the usual `errors_on/1` helper, so
  # traverse the changeset locally.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp attrs(task, overrides \\ %{}) do
    Map.merge(
      %{
        task_id: task.id,
        from_status: "backlog",
        to_status: "planning",
        occurred_at: DateTime.utc_now(),
        actor_kind: "system"
      },
      overrides
    )
  end

  describe "record/2" do
    test "round-trips a valid transition", %{task: task} do
      assert {:ok, row} =
               PhaseTransitions.record(
                 attrs(task, %{
                   actor_kind: "user",
                   actor_id: "11111111-1111-1111-1111-111111111111",
                   actor_label: "mcp:task_update",
                   via: "transition_task"
                 })
               )

      assert row.task_id == task.id
      assert row.from_status == "backlog"
      assert row.to_status == "planning"
      assert row.actor_kind == "user"
      assert row.actor_id == "11111111-1111-1111-1111-111111111111"
      assert row.actor_label == "mcp:task_update"
      assert row.via == "transition_task"
      assert %DateTime{} = row.occurred_at
    end

    test "rejects a to_status outside Task.statuses/0", %{task: task} do
      assert {:error, changeset} =
               PhaseTransitions.record(attrs(task, %{to_status: "marinating"}))

      assert %{to_status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts a nil from_status", %{task: task} do
      assert {:ok, row} = PhaseTransitions.record(attrs(task, %{from_status: nil}))
      assert row.from_status == nil
    end

    test "rejects a non-nil invalid from_status", %{task: task} do
      assert {:error, changeset} =
               PhaseTransitions.record(attrs(task, %{from_status: "marinating"}))

      assert %{from_status: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects an actor_kind outside the domain", %{task: task} do
      assert {:error, changeset} =
               PhaseTransitions.record(attrs(task, %{actor_kind: "robot"}))

      assert %{actor_kind: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts every declared actor_kind", %{task: task} do
      assert PhaseTransition.actor_kinds() == ~w(user agent system unknown)

      for kind <- PhaseTransition.actor_kinds() do
        assert {:ok, row} = PhaseTransitions.record(attrs(task, %{actor_kind: kind}))
        assert row.actor_kind == kind
      end
    end

    test "requires task_id, to_status, occurred_at and actor_kind" do
      assert {:error, changeset} = PhaseTransitions.record(%{})

      errors = errors_on(changeset)
      assert errors[:task_id] == ["can't be blank"]
      assert errors[:to_status] == ["can't be blank"]
      assert errors[:occurred_at] == ["can't be blank"]
      assert errors[:actor_kind] == ["can't be blank"]
    end

    test "a task may re-enter the same status: two rows for one (task_id, to_status)",
         %{task: task} do
      # This is the assertion that stops someone adding a unique index later.
      # `in_progress` is legitimately re-enterable from both `in_review` and
      # `deploying`, so uniqueness here would reject real transitions.
      assert {:ok, first} =
               PhaseTransitions.record(
                 attrs(task, %{from_status: "planning", to_status: "in_progress"})
               )

      assert {:ok, second} =
               PhaseTransitions.record(
                 attrs(task, %{from_status: "in_review", to_status: "in_progress"})
               )

      refute first.id == second.id

      rows = PhaseTransitions.list_for_task(task.id)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.to_status == "in_progress"))
      assert Enum.map(rows, & &1.from_status) |> Enum.sort() == ["in_review", "planning"]
    end
  end

  describe "list_for_task/1" do
    test "returns rows in ascending occurred_at order", %{task: task} do
      now = DateTime.utc_now()

      for {offset, to_status} <- [
            {2, "in_review"},
            {0, "planning"},
            {1, "in_progress"}
          ] do
        {:ok, _} =
          PhaseTransitions.record(
            attrs(task, %{
              to_status: to_status,
              occurred_at: DateTime.add(now, offset, :second)
            })
          )
      end

      assert PhaseTransitions.list_for_task(task.id) |> Enum.map(& &1.to_status) ==
               ["planning", "in_progress", "in_review"]
    end

    test "scopes to the given task", %{task: task} do
      {:ok, project} = Tasks.create_project(%{name: "Other Project"})
      {:ok, other} = Tasks.create_task(%{project_id: project.id, title: "Other Task"})

      {:ok, _} = PhaseTransitions.record(attrs(task))
      {:ok, _} = PhaseTransitions.record(attrs(other))

      assert [row] = PhaseTransitions.list_for_task(task.id)
      assert row.task_id == task.id
    end

    test "returns [] for a task with no recorded transitions", %{task: task} do
      assert PhaseTransitions.list_for_task(task.id) == []
    end
  end
end
