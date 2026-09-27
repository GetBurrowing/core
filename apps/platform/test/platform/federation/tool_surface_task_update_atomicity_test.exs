defmodule Platform.Federation.ToolSurfaceTaskUpdateAtomicityTest do
  @moduledoc """
  MCP `task_update` is one pre-validated write (task 01a0a4aa stage 2).

  Before this, the tool ran up to four statements. A status the transition
  table refused still left the plain fields committed and `updated_at` moved,
  so the caller's own retry with the same base came back as a false
  `stale_base`. A base guarded only the plain-field statement, so a
  status-only, phase_assignees-only or flat-assignee-only call with a stale
  base was applied without comparing anything.

  Every refusal is asserted as a refusal by re-reading the row. No
  `Process.sleep`: every concurrency case is composed against ONE captured
  `updated_at`.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransitions

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Atomicity Project #{System.unique_integer([:positive])}"})

    %{project: project, agent: insert_agent()}
  end

  defp insert_agent do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "atom-#{n}", name: "Atom #{n}", status: "active"}).id
  end

  defp create_task(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Original", description: "original", priority: "low"},
          attrs
        )
      )

    task
  end

  defp blocked_task(project) do
    {:ok, task} = project |> create_task() |> Tasks.transition_task_status("blocked")
    task
  end

  defp advance(task) do
    {:ok, moved} = Tasks.update_task(task, %{description: "moved"})
    assert DateTime.compare(moved.updated_at, task.updated_at) == :gt
    moved
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp call_task_update(args, context \\ %{}),
    do: ToolSurface.execute("task_update", args, context)

  describe "anti-vacuity 1: a refused transition writes nothing" do
    test "illegal edge plus a plain field: error says so, title unchanged, updated_at unmoved",
         %{project: project} do
      task = blocked_task(project)
      before = Tasks.get_task_record(task.id)

      assert {:error, env} =
               call_task_update(%{"task_id" => task.id, "status" => "done", "title" => "MUTATED"})

      assert env.error =~ "Invalid status transition"
      assert env.error =~ "Nothing was written"

      reread = Tasks.get_task_record(task.id)
      assert reread.status == "blocked"
      assert reread.title == "Original"
      assert reread.updated_at == before.updated_at
    end
  end

  describe "anti-vacuity 2: a supplied base guards a status-only call" do
    test "a stale base is refused and the status is unchanged", %{project: project} do
      task = blocked_task(project)
      stale = iso(task.updated_at)
      moved = advance(task)

      assert {:error, env} =
               call_task_update(%{
                 "task_id" => task.id,
                 "status" => "backlog",
                 "base_updated_at" => stale
               })

      assert env.error =~ "stale_base"
      assert env.error =~ iso(moved.updated_at)

      reread = Tasks.get_task_record(task.id)
      assert reread.status == "blocked"
      assert reread.updated_at == moved.updated_at
    end

    test "positive control: the same call with no base succeeds", %{project: project} do
      task = blocked_task(project)
      _moved = advance(task)

      assert {:ok, result} = call_task_update(%{"task_id" => task.id, "status" => "backlog"})
      assert result.status == "backlog"
    end
  end

  describe "a supplied base guards assignee-only calls" do
    test "phase_assignees-only with a stale base is refused", %{project: project, agent: agent} do
      task = create_task(project)
      stale = iso(task.updated_at)
      moved = advance(task)

      assert {:error, env} =
               call_task_update(%{
                 "task_id" => task.id,
                 "phase_assignees" => %{
                   "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
                 },
                 "base_updated_at" => stale
               })

      assert env.error =~ "stale_base"
      reread = Tasks.get_task_record(task.id)
      assert reread.phase_assignees == moved.phase_assignees
      assert reread.updated_at == moved.updated_at
    end

    test "phase_assignees-only with no base succeeds", %{project: project, agent: agent} do
      task = create_task(project)
      _moved = advance(task)

      assert {:ok, _} =
               call_task_update(%{
                 "task_id" => task.id,
                 "phase_assignees" => %{
                   "execution" => %{"assignee_id" => agent, "assignee_type" => "agent"}
                 }
               })

      assert Tasks.get_task_record(task.id).phase_assignees["execution"]["assignee_id"] == agent
    end

    test "flat assignee-only with a stale base is refused", %{project: project, agent: agent} do
      task = create_task(project)
      stale = iso(task.updated_at)
      moved = advance(task)

      assert {:error, env} =
               call_task_update(%{
                 "task_id" => task.id,
                 "assignee_id" => agent,
                 "assignee_type" => "agent",
                 "base_updated_at" => stale
               })

      assert env.error =~ "stale_base"
      reread = Tasks.get_task_record(task.id)
      assert reread.assignee_id == moved.assignee_id
      assert reread.phase_assignees == moved.phase_assignees
      assert reread.updated_at == moved.updated_at
    end

    test "flat assignee-only with no base succeeds", %{project: project, agent: agent} do
      task = create_task(project)
      _moved = advance(task)

      assert {:ok, _} =
               call_task_update(%{
                 "task_id" => task.id,
                 "assignee_id" => agent,
                 "assignee_type" => "agent"
               })

      assert Tasks.get_task_record(task.id).assignee_id == agent
    end
  end

  describe "false-concurrency chain" do
    test "a refused call does not turn the caller's own retry into a stale_base",
         %{project: project} do
      task = blocked_task(project)
      base = iso(task.updated_at)

      assert {:error, env} =
               call_task_update(%{
                 "task_id" => task.id,
                 "status" => "done",
                 "priority" => "high",
                 "base_updated_at" => base
               })

      assert env.error =~ "Invalid status transition"

      assert {:ok, result} =
               call_task_update(%{
                 "task_id" => task.id,
                 "title" => "X",
                 "base_updated_at" => base
               })

      assert result.title == "X"
      assert result.priority == "low"
      assert result.previous_updated_at == task.updated_at
    end
  end

  describe "a legal combined call" do
    test "status and a plain field land together with one transition row via mcp_task_update",
         %{project: project, agent: agent} do
      task = create_task(project)

      assert {:ok, result} =
               call_task_update(
                 %{
                   "task_id" => task.id,
                   "status" => "planning",
                   "title" => "Both",
                   "base_updated_at" => iso(task.updated_at)
                 },
                 %{agent_id: agent}
               )

      assert result.status == "planning"
      assert result.title == "Both"

      assert [row] =
               task.id
               |> PhaseTransitions.list_for_task()
               |> Enum.filter(&(&1.to_status == "planning"))

      assert row.via == "mcp_task_update"
      assert row.actor_kind == "agent"
      assert row.actor_id == agent
    end
  end

  describe "contract prose (stage 3)" do
    defp tool(name), do: Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))

    test "task_update limitations no longer describe the partial guard and say a refusal writes nothing" do
      limitations = tool("task_update").limitations

      refute limitations =~ "SUCCEEDS WITHOUT COMPARING ANYTHING"
      refute limitations =~ "LIVE ONLY IF THE CALL CARRIES AT LEAST ONE PLAIN FIELD"
      assert limitations =~ "writes nothing"
      assert limitations =~ "updated_at unmoved"
      # An omitted base stays last-write-wins; the prose must not claim a
      # status write requires one.
      assert limitations =~ "LAST-WRITE-WINS"
      refute limitations =~ ~r/status (writes|changes) require/i
    end

    test "task_complete no longer claims a stronger guarantee than task_update's base" do
      refute tool("task_complete").limitations =~ "stronger guarantee than task_update"
    end
  end
end
