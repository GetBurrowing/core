defmodule Platform.Access.SuiteRunInnerGateTest do
  use Platform.DataCase, async: false

  import Platform.CodeModeFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.RuntimeProfiles
  alias Platform.CodeMode.Docs
  alias Platform.CodeMode.Run
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolCallRecord
  alias Platform.Repo
  alias Platform.Tasks

  test "owner-capped restriction denies direct and code-mode inner task updates" do
    agent = insert_agent!()

    {runtime, token} =
      insert_runtime!(agent, ~w(federation space context_read messaging task code_mode))

    assert {:ok, _} = RuntimeProfiles.create_for_runtime(runtime, runtime.allowed_bundles, nil)

    {:ok, project} =
      Tasks.create_project(%{
        name: "inner-gate-#{System.unique_integer([:positive])}",
        org_id: acme_org_id()
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Before"})
    allowed = "suite.task_update({task_id: '#{task.id}', title: 'Allowed'})"

    assert {:ok, %{ok: true}} = Run.execute(runtime, allowed)
    assert Repo.reload!(task).title == "Allowed"

    assert {:ok, _} = RuntimeProfiles.restrict(runtime, %{"skills.read" => "all"})
    refute "task_update" in ToolAuthorization.tool_names(runtime)
    assert {:ok, index} = Docs.describe(runtime, %{})
    refute "task_update" in index.tools

    assert mcp_call(token, "task_update", %{"task_id" => task.id, "title" => "Denied"})["error"][
             "code"
           ] == -32001

    for script <- [
          "suite.task_update({task_id: '#{task.id}', title: 'Denied'})",
          "suite.call('task_update', {task_id: '#{task.id}', title: 'Denied'})"
        ] do
      assert {:ok, %{ok: false, error: %{kind: "forbidden"}, run_id: run_id}} =
               Run.execute(runtime, script)

      assert [%ToolCallRecord{tool: "task_update", status: "denied", parent_run_id: ^run_id}] =
               inner_rows(run_id)
    end

    assert Repo.reload!(task).title == "Allowed"

    tools = mcp(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    refute "task_update" in tools
    assert "suite_run_describe" in tools
  end
end
