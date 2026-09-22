defmodule Platform.Federation.TaskListAssigneeFilterTest do
  @moduledoc """
  `task_list` declares and applies `assignee_id` / `assignee_type`, refuses
  malformed input recoverably, and echoes the filters it applied in
  `filters` — task 01a0acc3 stage 3.

  Every call goes through `ToolArguments.dispatch/3`, the door both transports
  use. `ToolSurface.execute/3` is `@doc false` and bypasses argument policy, so
  a test through it would not exercise the unknown-parameter refusal that the
  declaration is what lifts.

  Each test seeds its own project and scopes by `project_id`, so every count
  is bounded to rows this test wrote. The flat column and the phase slots are
  written with `Repo.update_all` so they can diverge on purpose.
  """
  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  defp u, do: System.unique_integer([:positive])

  defp project, do: elem(Tasks.create_project(%{name: "TL Assignee #{u()}"}), 1)

  defp slot(id, type), do: %{"assignee_id" => id, "assignee_type" => type}

  defp seed_task(project, title, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp call(args), do: ToolArguments.dispatch("task_list", args, %{})

  defp list!(args) do
    assert {:ok, env} = call(args)
    env
  end

  defp ids(env), do: env.tasks |> Enum.map(& &1.id) |> MapSet.new()

  # A: flat X (agent).
  # B: flat Y, review slot X — the phase-slot-only match for X.
  # C: flat Y only.
  # D: unassigned.
  # E: flat X typed "user".
  setup do
    x = Ecto.UUID.generate()
    y = Ecto.UUID.generate()
    p = project()

    a = seed_task(p, "A", assignee_id: x, assignee_type: "agent", phase_assignees: %{})

    b =
      seed_task(p, "B",
        assignee_id: y,
        assignee_type: "agent",
        phase_assignees: %{"execution" => slot(y, "agent"), "review" => slot(x, "agent")}
      )

    c = seed_task(p, "C", assignee_id: y, assignee_type: "agent", phase_assignees: %{})
    d = seed_task(p, "D", assignee_id: nil, assignee_type: nil, phase_assignees: %{})
    e = seed_task(p, "E", assignee_id: x, assignee_type: "user", phase_assignees: %{})

    %{x: x, y: y, p: p, a: a, b: b, c: c, d: d, e: e}
  end

  describe "the filter works" do
    test "assignee_id X returns only X's tasks, against a larger unfiltered control", ctx do
      filtered = list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x})
      unfiltered = list!(%{"project_id" => ctx.p.id})

      assert ids(filtered) == MapSet.new([ctx.a.id, ctx.b.id, ctx.e.id])
      assert filtered.total == 3
      assert filtered.has_more == false

      # Positive control: the same project unfiltered is larger and contains
      # Y's rows and the unassigned row the filter excluded.
      assert unfiltered.total == 5
      assert unfiltered.total > filtered.total
      assert MapSet.subset?(MapSet.new([ctx.c.id, ctx.d.id]), ids(unfiltered))
      refute MapSet.member?(ids(filtered), ctx.c.id)
      refute MapSet.member?(ids(filtered), ctx.d.id)
    end

    test "total and has_more are counted over the filtered set, not the page", ctx do
      env = list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x, "limit" => 1})

      assert length(env.tasks) == 1
      assert env.total == 3
      assert env.has_more == true

      last = list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x, "offset" => 2})
      assert length(last.tasks) == 1
      assert last.has_more == false
    end

    test "a phase-slot-only assignment is returned, and it is really slot-only", ctx do
      env = list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x})
      row = Enum.find(env.tasks, &(&1.id == ctx.b.id))

      assert row
      # Discriminates the filter from its absence: without these two lines the
      # test passes on an unfiltered list too (mutation probe (a), stage 3).
      refute Enum.any?(env.tasks, &(&1.id == ctx.c.id))
      assert env.filters["assignee_id"] == ctx.x
      assert row.assignee_id != ctx.x
      assert row.assignee_id == ctx.y
      assert get_in(row.phase_assignees, ["review", "assignee_id"]) == ctx.x
    end

    test "an uppercase assignee_id returns the same set, slot-only match included", ctx do
      lower = list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x})
      upper = list!(%{"project_id" => ctx.p.id, "assignee_id" => String.upcase(ctx.x)})

      assert ids(upper) == ids(lower)
      assert MapSet.member?(ids(upper), ctx.b.id)
      assert upper.total == lower.total
      # The echo reports the id the query actually applied: the canonical form.
      assert upper.filters["assignee_id"] == ctx.x
    end
  end

  describe "assignee_type" do
    test "narrows the results", ctx do
      agent =
        list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x, "assignee_type" => "agent"})

      user =
        list!(%{"project_id" => ctx.p.id, "assignee_id" => ctx.x, "assignee_type" => "user"})

      assert ids(agent) == MapSet.new([ctx.a.id, ctx.b.id])
      assert ids(user) == MapSet.new([ctx.e.id])
      assert agent.filters["assignee_type"] == "agent"
    end

    test "alone is refused, not silently dropped", ctx do
      assert {:error, env} = call(%{"project_id" => ctx.p.id, "assignee_type" => "agent"})

      assert env.code == :assignee_type_requires_assignee_id
      assert env.recoverable == true
      assert env.error =~ "assignee_type requires assignee_id"
    end

    test "a value other than agent/user is refused", ctx do
      assert {:error, env} =
               call(%{"assignee_id" => ctx.x, "assignee_type" => "robot"})

      assert env.code == :invalid_assignee_type
      assert env.recoverable == true
    end
  end

  describe "a malformed assignee_id" do
    test "is refused recoverably rather than raised" do
      for bad <- ["higgins", "higginshigginsxx", "", 42] do
        assert {:error, env} = call(%{"assignee_id" => bad})
        assert env.code == :invalid_assignee_id
        assert env.recoverable == true
        assert env.error == "task_list: assignee_id must be a UUID"
        assert is_binary(env.suggestion)
      end
    end
  end

  describe "the zero case" do
    test "a fresh UUID answers an empty, complete page and echoes the filter", ctx do
      fresh = Ecto.UUID.generate()
      env = list!(%{"project_id" => ctx.p.id, "assignee_id" => fresh})

      assert env.tasks == []
      assert env.total == 0
      assert env.has_more == false
      assert env.filters == %{"assignee_id" => fresh, "project_id" => ctx.p.id}

      # Same call without the filter: the zero came from the filter, not from
      # an empty project.
      control = list!(%{"project_id" => ctx.p.id})
      assert control.total > 0
      assert control.filters == %{"project_id" => ctx.p.id}
    end

    test "an unfiltered call echoes an empty filters map" do
      assert list!(%{"limit" => 1}).filters == %{}
    end
  end

  describe "strictness is not widened" do
    test "an undeclared assignee key is still refused with unknown_parameter", ctx do
      assert {:error, env} = call(%{"assignee" => ctx.x})
      assert env.code == :unknown_parameter
      assert env.unknown_parameters == ["assignee"]
    end
  end

  describe "regression" do
    test "status and project_id still AND-compose and both are echoed", ctx do
      {1, _} =
        Repo.update_all(from(t in Task, where: t.id == ^ctx.a.id), set: [status: "in_progress"])

      env = list!(%{"project_id" => ctx.p.id, "status" => "in_progress"})

      assert ids(env) == MapSet.new([ctx.a.id])
      assert env.filters == %{"project_id" => ctx.p.id, "status" => "in_progress"}

      # Other project, same status: the project filter is still applied.
      other = list!(%{"project_id" => project().id, "status" => "in_progress"})
      assert other.total == 0
    end

    test "status, project_id and assignee_id compose together", ctx do
      {1, _} =
        Repo.update_all(from(t in Task, where: t.id == ^ctx.b.id), set: [status: "in_review"])

      env =
        list!(%{"project_id" => ctx.p.id, "status" => "in_review", "assignee_id" => ctx.x})

      assert ids(env) == MapSet.new([ctx.b.id])

      assert env.filters == %{
               "project_id" => ctx.p.id,
               "status" => "in_review",
               "assignee_id" => ctx.x
             }
    end
  end
end
