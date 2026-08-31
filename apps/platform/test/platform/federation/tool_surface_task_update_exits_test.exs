defmodule Platform.Federation.ToolSurfaceTaskUpdateExitsTest do
  @moduledoc """
  Task 01a05394 stage 3: `task_update`'s `:invalid_transition` envelope names
  the legal exits for the task's CURRENT status, derived from
  `Platform.Tasks.valid_task_transitions/0`, instead of the generic "check
  allowed transitions" sentence. A status with no exits says so in words.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks

  # The pre-stage-3 suggestion opened with this sentence. It is the
  # distinctive phrase of the generic text — refutes aim here, never at
  # "status" / "transition" / "invalid" / "task".
  @old_generic_phrase "Check allowed transitions for the current status"

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Exits #{System.unique_integer([:positive])}"})

    project
  end

  # `create_task/1` defaults to `backlog`; `stack_pending` is set through
  # `Tasks.update_task/2` (the same changeset write tool_surface_stacks_test
  # uses to park a member), not by transcribing an engine path.
  defp stack_pending_task!(project) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Parked member"})
    {:ok, task} = Tasks.update_task(task, %{status: "stack_pending"})
    assert task.status == "stack_pending"
    task
  end

  defp cancelled_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Retired", status: "cancelled"})

    assert task.status == "cancelled"
    task
  end

  defp invalid_update!(task, target) do
    {:error, error} =
      ToolSurface.execute(
        "task_update",
        %{"task_id" => task.id, "status" => target},
        %{}
      )

    assert error.recoverable == true
    error
  end

  describe "task_update :invalid_transition names the legal exits" do
    test "stack_pending → done lists the four literal exits in error AND suggestion" do
      task = stack_pending_task!(create_project())

      # `done` is not an exit of stack_pending — the engine refuses it.
      error = invalid_update!(task, "done")
      joined = error.error <> " || " <> error.suggestion

      # (a) actionable tokens: the exact rendered enumeration, pinned as
      # LITERAL strings, present in both halves of the envelope.
      literal =
        "Valid next statuses from 'stack_pending': in_progress, blocked, backlog, cancelled."

      assert error.error =~ literal
      assert error.suggestion =~ literal

      # (b) the old generic sentence is gone from both halves.
      refute joined =~ @old_generic_phrase

      # The existing prefix pinned by sibling tests survives.
      assert error.error =~ "Invalid status transition from 'stack_pending' to 'done'"

      # No dangling empty enumeration anywhere.
      refute joined =~ ~r/from '\w+': *\./
    end

    test "the listed exits equal Tasks.valid_task_transitions/0 for the task's status" do
      task = stack_pending_task!(create_project())
      error = invalid_update!(task, "done")

      # (c) equality-of-derivation: parse the rendered enumeration back out
      # and compare to the table entry, order included.
      [_, rendered] =
        Regex.run(~r/Valid next statuses from 'stack_pending': ([^.]+)\./, error.error)

      assert String.split(rendered, ", ") == Tasks.valid_task_transitions()["stack_pending"]

      # Anti-vacuity for the table side: a mutation that empties the map
      # entry cannot make the equality above pass, because this literal pin
      # is asserted independently of the map.
      assert Tasks.valid_task_transitions()["stack_pending"] ==
               ~w(in_progress blocked backlog cancelled)

      refute error.suggestion =~ @old_generic_phrase
    end

    test "backlog → done lists backlog's exits (a second status, derived not copied)" do
      project = create_project()
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Fresh"})
      assert task.status == "backlog"

      error = invalid_update!(task, "done")
      expected = Enum.join(Tasks.valid_task_transitions()["backlog"], ", ")
      assert expected != ""
      assert error.error =~ "Valid next statuses from 'backlog': #{expected}."
      assert error.suggestion =~ "Valid next statuses from 'backlog': #{expected}."
      # backlog's exits differ from stack_pending's — proves the text follows
      # the task's status rather than a fixed list.
      refute error.error =~
               "Valid next statuses from 'backlog': in_progress, blocked, backlog, cancelled."

      refute error.suggestion =~ @old_generic_phrase
    end

    test "cancelled → in_progress says explicitly there are no outbound transitions" do
      task = cancelled_task!(create_project())
      assert Tasks.valid_task_transitions()["cancelled"] == []

      error = invalid_update!(task, "in_progress")
      joined = error.error <> " || " <> error.suggestion

      # (d) the terminal sentence, in both halves.
      assert error.error =~ "'cancelled' has no valid outbound transitions."
      assert error.suggestion =~ "'cancelled' has no valid outbound transitions."

      # Never a dangling empty enumeration.
      refute joined =~ "Valid next statuses from 'cancelled'"
      refute joined =~ ~r/from 'cancelled': *\./

      # The pre-existing terminal guidance is preserved, the generic sentence is not.
      assert error.suggestion =~ "reinstate_cancelled_task/3"
      assert error.suggestion =~ "'cancelled' is TERMINAL"
      refute joined =~ @old_generic_phrase
    end
  end
end
