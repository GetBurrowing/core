defmodule Platform.Tasks.ListTasksAssigneeFilterTest do
  @moduledoc """
  `Tasks.list_tasks/1`, `list_tasks_page/2` and `count_tasks/1` accept
  `:assignee_id` (+ optional `:assignee_type`) — task 01a0acc3 stage 2.

  "Assigned to X" means ANY phase: the flat `assignee_id` column holds only
  the CURRENT phase's assignee, while `phase_assignees` holds every phase, and
  the two can differ. So a task matches when X is in the flat column OR in any
  phase slot. Matching the flat column alone would recreate the ticket's
  failure (an agent asking "what is mine" gets a wrong answer) as a quieter
  undercount.

  Rows are written with `Repo.update_all` rather than through the assignment
  API so the flat column and the slots can be made to diverge on purpose;
  each divergence is asserted on the persisted row before it is queried.
  """
  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  defp u, do: System.unique_integer([:positive])

  defp project, do: elem(Tasks.create_project(%{name: "Assignee Proj #{u()}"}), 1)

  defp slot(id, type), do: %{"assignee_id" => id, "assignee_type" => type}

  defp seed_task(project, title, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp ids(tasks), do: tasks |> Enum.map(& &1.id) |> MapSet.new()

  # A: flat X + planning slot X.
  # B: flat Y, review slot X (phase-only match for X).
  # C: flat Y only.
  # D: unassigned.
  # E: flat X typed "user".
  # plus one soft-deleted task assigned to X.
  setup do
    x = Ecto.UUID.generate()
    y = Ecto.UUID.generate()
    p = project()

    a =
      seed_task(p, "A",
        assignee_id: x,
        assignee_type: "agent",
        phase_assignees: %{"planning" => slot(x, "agent")}
      )

    b =
      seed_task(p, "B",
        assignee_id: y,
        assignee_type: "agent",
        phase_assignees: %{"execution" => slot(y, "agent"), "review" => slot(x, "agent")}
      )

    c =
      seed_task(p, "C",
        assignee_id: y,
        assignee_type: "agent",
        phase_assignees: %{"planning" => slot(y, "agent")}
      )

    d = seed_task(p, "D", assignee_id: nil, assignee_type: nil, phase_assignees: %{})

    e =
      seed_task(p, "E",
        assignee_id: x,
        assignee_type: "user",
        phase_assignees: %{}
      )

    deleted =
      seed_task(p, "Deleted",
        assignee_id: x,
        assignee_type: "agent",
        phase_assignees: %{"planning" => slot(x, "agent")},
        deleted_at: DateTime.utc_now()
      )

    %{x: x, y: y, p: p, a: a, b: b, c: c, d: d, e: e, deleted: deleted}
  end

  describe "assignee_id" do
    test "returns exactly the tasks X holds in any phase, and the filter removes rows", ctx do
      # Positive control: without the filter the project has 5 live rows, so
      # the 3 below are the filter's doing, not an empty project.
      assert Tasks.count_tasks(project_id: ctx.p.id) == 5

      result = Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x)

      assert ids(result) == MapSet.new([ctx.a.id, ctx.b.id, ctx.e.id])
      refute ctx.c.id in ids(result)
      refute ctx.d.id in ids(result)
      refute ctx.deleted.id in ids(result)
    end

    test "a phase-slot-only assignment matches although the flat column is someone else", ctx do
      persisted = Repo.get!(Task, ctx.b.id)
      assert persisted.assignee_id == ctx.y
      refute persisted.assignee_id == ctx.x
      assert persisted.phase_assignees["review"]["assignee_id"] == ctx.x

      assert ctx.b.id in ids(Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x))
    end

    test "a flat-only assignment (empty phase_assignees) matches", ctx do
      persisted = Repo.get!(Task, ctx.e.id)
      assert persisted.phase_assignees == %{}
      assert persisted.assignee_id == ctx.x

      assert ctx.e.id in ids(Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x))

      # Same shape with an agent type, so the flat branch is not only
      # reachable through the "user" row.
      f =
        seed_task(ctx.p, "F", assignee_id: ctx.x, assignee_type: "agent", phase_assignees: %{})

      assert Repo.get!(Task, f.id).phase_assignees == %{}

      assert f.id in ids(
               Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x, assignee_type: "agent")
             )
    end

    test "a null or legacy scalar slot does not match", ctx do
      g =
        seed_task(ctx.p, "G",
          assignee_id: nil,
          assignee_type: nil,
          phase_assignees: %{"planning" => nil, "review" => ctx.x}
        )

      refute g.id in ids(Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x))
    end

    test "an id nobody holds returns nothing while the project is non-empty", ctx do
      nobody = Ecto.UUID.generate()

      assert Tasks.count_tasks(project_id: ctx.p.id) > 0
      assert Tasks.list_tasks(project_id: ctx.p.id, assignee_id: nobody) == []
      assert Tasks.count_tasks(project_id: ctx.p.id, assignee_id: nobody) == 0
    end

    test "nil assignee_id is the unfiltered passthrough", ctx do
      assert Tasks.count_tasks(project_id: ctx.p.id, assignee_id: nil) == 5
    end
  end

  describe "assignee_type" do
    test "\"agent\" excludes the user-typed flat row; \"user\" returns only it", ctx do
      agent = Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x, assignee_type: "agent")
      assert ids(agent) == MapSet.new([ctx.a.id, ctx.b.id])

      user = Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x, assignee_type: "user")
      assert ids(user) == MapSet.new([ctx.e.id])
    end
  end

  describe "composition" do
    test "ANDs with project_id and status, never ORs", ctx do
      # C (Y's task) shares A's project AND status, so only the assignee
      # clause can exclude it. With C left in backlog the status filter alone
      # would exclude it and this test would pass with the assignee filter
      # deleted (measured: mutation probe (a), first draft of this test).
      ac = [ctx.a.id, ctx.c.id]
      {2, _} = Repo.update_all(from(t in Task, where: t.id in ^ac), set: [status: "in_progress"])

      assert Repo.get!(Task, ctx.a.id).status == "in_progress"
      assert Repo.get!(Task, ctx.c.id).status == "in_progress"

      # Another project's task assigned to X must not leak in.
      other = project()

      o =
        seed_task(other, "Other",
          assignee_id: ctx.x,
          assignee_type: "agent",
          phase_assignees: %{"planning" => slot(ctx.x, "agent")}
        )

      in_progress =
        Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x, status: "in_progress")

      assert ids(in_progress) == MapSet.new([ctx.a.id])

      # C matches project_id and status but not assignee; ORing (or dropping)
      # the assignee clause would admit it.
      refute ctx.c.id in ids(in_progress)

      assert ids(Tasks.list_tasks(project_id: ctx.p.id, status: "in_progress")) ==
               MapSet.new([ctx.a.id, ctx.c.id])

      refute o.id in ids(Tasks.list_tasks(project_id: ctx.p.id, assignee_id: ctx.x))

      assert ids(Tasks.list_tasks(project_id: other.id, assignee_id: ctx.x)) ==
               MapSet.new([o.id])
    end
  end

  describe "count and page agree with the list" do
    test "count_tasks == length(list_tasks) for every filter combination", ctx do
      for opts <- [
            [project_id: ctx.p.id],
            [project_id: ctx.p.id, assignee_id: ctx.x],
            [project_id: ctx.p.id, assignee_id: ctx.y],
            [project_id: ctx.p.id, assignee_id: ctx.x, assignee_type: "agent"],
            [project_id: ctx.p.id, assignee_id: ctx.x, assignee_type: "user"],
            [project_id: ctx.p.id, assignee_id: Ecto.UUID.generate()]
          ] do
        assert Tasks.count_tasks(opts) == length(Tasks.list_tasks(opts)),
               "count/list disagree for #{inspect(opts)}"
      end
    end

    test "paging with limit 1 walks exactly total rows with no repeats", ctx do
      opts = [project_id: ctx.p.id, assignee_id: ctx.x]
      total = Tasks.count_tasks(opts)
      assert total == 3

      pages =
        for offset <- 0..(total - 1) do
          Tasks.list_tasks_page(opts, limit: 1, offset: offset)
        end

      assert Enum.all?(pages, &(length(&1) == 1))
      walked = pages |> List.flatten() |> Enum.map(& &1.id)
      assert length(Enum.uniq(walked)) == total
      assert MapSet.new(walked) == MapSet.new([ctx.a.id, ctx.b.id, ctx.e.id])
      assert Tasks.list_tasks_page(opts, limit: 1, offset: total) == []
    end
  end
end
