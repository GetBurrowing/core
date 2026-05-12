defmodule Platform.Federation.ToolSurfaceStacksTest do
  @moduledoc """
  End-to-end MCP-tool coverage for the stack_* surface (ADR 0041, Task
  Stacks T3 stage 3).

  These tests exercise the stack tools strictly through
  `Platform.Federation.ToolSurface.execute/3` — i.e. as an MCP client
  would. Stage 2's `tool_surface_test.exs` already covers each tool's
  individual happy/error branches in isolation; this file is the
  integration counterpart that drives full lifecycles end-to-end and
  asserts only on response envelopes. `Repo` is used solely for
  fixture setup, never to verify outcomes — the contract under test is
  the MCP surface.

  Stage 3's stack_start cascade is documented in ADR 0041 but is not
  yet wired (T4 will replace the body with `Stacks.start_stack/1`).
  The cascade test asserts current behaviour and carries a TODO(T4).
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Tasks
  alias Platform.Tasks.Task

  # ── Fixtures ───────────────────────────────────────────────────────

  defp create_project(attrs \\ %{}) do
    default = %{name: "Stacks E2E #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Create a stack via the MCP surface and return the stack_id +
  # rollup_branch. Keeps the test bodies focused on the assertion path.
  defp create_stack_via_tool(project_id, slug, name \\ "E2E Stack") do
    {:ok, result} =
      ToolSurface.execute(
        "stack_create",
        %{"project_id" => project_id, "slug" => slug, "name" => name},
        %{}
      )

    result
  end

  # ── Scenarios ──────────────────────────────────────────────────────

  describe "stack_create end-to-end" do
    test "returns {stack_id, rollup_branch} with rollup_branch derived from slug" do
      project = create_project()
      slug = unique_slug("e2e-create")

      {:ok, result} =
        ToolSurface.execute(
          "stack_create",
          %{"project_id" => project.id, "slug" => slug, "name" => "Created"},
          %{}
        )

      assert is_binary(result.stack_id)
      # rollup_branch derivation is part of the documented contract for
      # this tool (ADR 0041 §branching) — exercised through the MCP
      # response, not by querying the Stacks context directly.
      assert result.rollup_branch == "stack/#{slug}"
    end
  end

  describe "stack_add end-to-end" do
    test "accepts a task and reports task_id + stack_id + stack_position" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-add"))
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Attachable"})

      {:ok, result} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      assert result.task_id == task.id
      assert result.stack_id == stack_id
      assert result.stack_position == 1
    end

    test "rejects a cycle-creating add with the documented error envelope" do
      project = create_project()
      %{stack_id: stack_id} = create_stack_via_tool(project.id, unique_slug("e2e-cycle"))

      # Two tasks: A is a clean root, B blocks on A. We attach A first
      # so the stack has a member; then we patch A in-place to declare
      # a dep on B (A→B and B→A). Once we attach B, the resulting
      # in-stack DAG is cyclic and `stack_add` must roll back.
      {:ok, task_a} = Tasks.create_task(%{project_id: project.id, title: "A"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task_a.id},
          %{}
        )

      {:ok, task_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "B",
          dependencies: [%{"task_id" => task_a.id, "kind" => "blocks"}]
        })

      # Patch A to point at B *after* it's attached. We can't go through
      # the MCP surface to do this (there's no edge-mutation tool), so
      # this is a fixture step.
      attached_a = Tasks.get_task_record(task_a.id)

      attached_a
      |> Task.changeset(%{
        dependencies: [%{"task_id" => task_b.id, "kind" => "blocks"}]
      })
      |> Repo.update!()

      {:error, error} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task_b.id},
          %{}
        )

      assert error.code == "cycle"
      assert is_binary(error.error)
      assert is_binary(error.suggestion)
      assert is_list(error.path)
      # Both members involved in the cycle must surface in `path` so an
      # operator can diagnose the offending edge.
      path_ids = MapSet.new(error.path)
      assert MapSet.member?(path_ids, task_a.id)
      assert MapSet.member?(path_ids, task_b.id)
    end
  end

  describe "stack_get end-to-end" do
    test "returns the documented shape: stack, members, edges, executable_now, cross_stack_deps" do
      project = create_project()
      slug = unique_slug("e2e-get")
      %{stack_id: stack_id} = create_stack_via_tool(project.id, slug, "Get Shape")

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => root.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => child.id},
          %{}
        )

      {:ok, result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      # `stack` sub-map carries the lifecycle fields callers depend on.
      assert result.stack.id == stack_id
      assert result.stack.slug == slug
      assert result.stack.status == "forming"
      assert result.stack.rollup_branch == "stack/#{slug}"
      assert is_binary(result.stack.base_branch)
      assert result.stack.name == "Get Shape"

      # `members` lists each attached task with the in-stack metadata
      # callers need to render a board (status + position + own deps).
      assert length(result.members) == 2
      assert Enum.all?(result.members, &Map.has_key?(&1, :stack_position))
      assert Enum.all?(result.members, &Map.has_key?(&1, :status))
      assert Enum.all?(result.members, &Map.has_key?(&1, :dependencies))

      # `edges` reports the in-stack dep DAG; child → root is the only
      # edge here.
      assert Enum.any?(
               result.edges,
               &(&1.from_task_id == child.id and &1.to_task_id == root.id and &1.kind == "blocks")
             )

      # `executable_now` lists the in-stack roots that have no
      # unsatisfied in-stack deps — the child is blocked by the root.
      assert root.id in result.executable_now
      refute child.id in result.executable_now

      # No cross-stack edges in this scenario.
      assert result.cross_stack_deps == []
    end
  end

  describe "stack_list end-to-end" do
    test "filters by project_id and status" do
      project_a = create_project()
      project_b = create_project()

      slug_forming_a = unique_slug("e2e-list-form-a")
      slug_started_a = unique_slug("e2e-list-start-a")
      slug_forming_b = unique_slug("e2e-list-form-b")

      %{stack_id: forming_a_id} =
        create_stack_via_tool(project_a.id, slug_forming_a, "Forming A")

      %{stack_id: started_a_id} =
        create_stack_via_tool(project_a.id, slug_started_a, "Started A")

      %{stack_id: forming_b_id} =
        create_stack_via_tool(project_b.id, slug_forming_b, "Forming B")

      # Promote one of project_a's stacks to in_progress so we can
      # distinguish status filtering from project filtering.
      {:ok, _} =
        ToolSurface.execute("stack_start", %{"stack_id" => started_a_id}, %{})

      # project filter: only project_a's two stacks come back.
      {:ok, project_a_results} =
        ToolSurface.execute("stack_list", %{"project_id" => project_a.id}, %{})

      project_a_ids = Enum.map(project_a_results, & &1.id)
      assert forming_a_id in project_a_ids
      assert started_a_id in project_a_ids
      refute forming_b_id in project_a_ids

      # status filter (combined with project_id): only the in_progress
      # member of project_a comes back.
      {:ok, in_progress_results} =
        ToolSurface.execute(
          "stack_list",
          %{"project_id" => project_a.id, "status" => "in_progress"},
          %{}
        )

      in_progress_ids = Enum.map(in_progress_results, & &1.id)
      assert started_a_id in in_progress_ids
      refute forming_a_id in in_progress_ids
      refute forming_b_id in in_progress_ids
      assert Enum.all?(in_progress_results, &(&1.status == "in_progress"))
    end
  end

  describe "stack_start end-to-end" do
    test "flips a forming stack to in_progress (cascade pending T4)" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-start"), "Start Me")

      # Two members: a clean root and a child blocked on it. Once T4
      # lands the cascade, `root_task` should flip to `in_progress` and
      # `child_task` should flip to `stack_pending`. For T3 we only
      # assert what stage 1's implementation actually does: the
      # stack-level status flips; member statuses stay untouched.
      {:ok, root_task} = Tasks.create_task(%{project_id: project.id, title: "Root"})

      {:ok, child_task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Child",
          dependencies: [%{"task_id" => root_task.id, "kind" => "blocks"}]
        })

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => root_task.id},
          %{}
        )

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => child_task.id},
          %{}
        )

      {:ok, started} =
        ToolSurface.execute("stack_start", %{"stack_id" => stack_id}, %{})

      assert started.status == "in_progress"
      assert started.id == stack_id

      # TODO(T4): once the cascade lands, also assert that root members
      # flipped to "in_progress" and non-root members flipped to
      # "stack_pending" via a follow-up `stack_get` round-trip.
      {:ok, after_start} =
        ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})

      root_member = Enum.find(after_start.members, &(&1.id == root_task.id))
      child_member = Enum.find(after_start.members, &(&1.id == child_task.id))

      # Stage 1's stack_start is stack-level only; members are still in
      # their pre-existing status (`backlog`). When T4 wires
      # Stacks.start_stack/1 these refutes should flip to asserts.
      assert root_member.status == "backlog"
      assert child_member.status == "backlog"
    end
  end

  describe "stack_eject and stack_abandon end-to-end" do
    test "stack_eject detaches a member and returns task_id + stack_id" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-eject"), "Eject Happy")

      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Detachable"})

      {:ok, _} =
        ToolSurface.execute(
          "stack_add",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      {:ok, eject_result} =
        ToolSurface.execute(
          "stack_eject",
          %{"stack_id" => stack_id, "task_id" => task.id},
          %{}
        )

      assert eject_result.task_id == task.id
      assert eject_result.stack_id == stack_id

      # Round-trip through `stack_get`: the ejected task should no
      # longer appear among members.
      {:ok, after_eject} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      member_ids = Enum.map(after_eject.members, & &1.id)
      refute task.id in member_ids
    end

    test "stack_abandon flips status to abandoned and records reason" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-abandon"), "Abandon Me")

      {:ok, abandon_result} =
        ToolSurface.execute(
          "stack_abandon",
          %{"stack_id" => stack_id, "reason" => "pivoted scope"},
          %{}
        )

      assert abandon_result.status == "abandoned"
      assert abandon_result.id == stack_id
      assert abandon_result.description =~ "pivoted scope"

      # Round-trip: stack_get should reflect the abandoned status.
      {:ok, after_abandon} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      assert after_abandon.stack.status == "abandoned"
    end
  end

  describe "task_create with stack_id end-to-end" do
    test "persists both the task and its stack membership in one call" do
      project = create_project()

      %{stack_id: stack_id} =
        create_stack_via_tool(project.id, unique_slug("e2e-tc-stack"), "Combined")

      {:ok, result} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Created and stacked",
            "stack_id" => stack_id
          },
          %{}
        )

      assert is_binary(result.id)
      assert result.title == "Created and stacked"
      assert result.stack_id == stack_id
      assert result.stack_position == 1

      # Round-trip through stack_get: the new task is now a member.
      {:ok, get_result} = ToolSurface.execute("stack_get", %{"stack_id" => stack_id}, %{})
      member_ids = Enum.map(get_result.members, & &1.id)
      assert result.id in member_ids
    end

    test "rejects task_create cleanly when stack_id refers to a missing stack" do
      project = create_project()
      bogus_stack_id = Ecto.UUID.generate()

      {:error, error} =
        ToolSurface.execute(
          "task_create",
          %{
            "project_id" => project.id,
            "title" => "Will fail to attach",
            "stack_id" => bogus_stack_id
          },
          %{}
        )

      # The error envelope must be a stable contract for callers; the
      # add_task -> :stack_not_found leg goes through stack_add's error
      # mapper.
      assert error.error =~ "Stack not found"
      assert error.recoverable == false
    end
  end
end
