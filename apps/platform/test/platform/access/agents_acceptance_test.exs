defmodule Platform.Access.AgentsAcceptanceTest do
  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Grants
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.RuntimeProfileFixtures
  alias Platform.Tasks
  alias Platform.Tenancy

  @guest_chat_tools ~w(send_media react space_list space_get_context space_get_messages space_search_messages)

  describe "a member's agent cannot call a tool the member lacks" do
    test "a guest-owned agent gains and loses task_list with the owner's project grant" do
      guest = World.create_user!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: acme_org_id()})
      {project_p, task_p} = project_and_task!("guest-p")
      {_project_q, task_q} = project_and_task!("guest-q")
      {_runtime, token} = runtime_token!(guest.id, ~w(federation space context_read messaging task))

      assert Enum.sort(listed_names(token)) == Enum.sort(@guest_chat_tools)
      assert get_in(call(token, "task_list", %{"limit" => 200}), ["error", "code"]) == -32001

      {:ok, grant} =
        Grants.grant(%{principal: guest, permission: "tasks.read", resource: project_p})

      assert "task_list" in listed_names(token)
      ids = task_ids(token)
      assert task_p.id in ids
      refute task_q.id in ids

      assert {:ok, _} = Grants.revoke(grant)
      refute "task_list" in listed_names(token)
      assert get_in(call(token, "task_list", %{"limit" => 200}), ["error", "code"]) == -32001
    end

    test "an internal owner's deny removes only that project's tasks from its agent" do
      owner = World.create_user!()
      World.plain_member!(owner, Tenancy.get_org_by_slug!("sxi"))
      {_project_p, task_p} = project_and_task!("member-p")
      {project_q, task_q} = project_and_task!("member-q")
      {_runtime, token} = runtime_token!(owner.id, ["task"])

      before = task_ids(token)
      assert task_p.id in before
      assert task_q.id in before

      assert {:ok, _} =
               Grants.deny(%{
                 principal: owner,
                 permission: "tasks.read",
                 resource: project_q
               })

      after_deny = task_ids(token)
      assert task_p.id in after_deny
      refute task_q.id in after_deny
    end
  end

  defp runtime_token!(owner_id, modules) do
    token = AgentRuntime.generate_token()

    runtime =
      RuntimeProfileFixtures.runtime!(
        owner_id,
        modules,
        %{status: "active", auth_token_hash: AgentRuntime.hash_token(token)},
        nil
      )

    {runtime, token}
  end

  defp project_and_task!(tag) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "agent-acceptance-#{tag}-#{System.unique_integer([:positive])}",
        org_id: acme_org_id()
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Agent #{tag}"})
    {project, task}
  end

  defp listed_names(token) do
    rpc(token, "tools/list", %{})
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
  end

  defp task_ids(token) do
    %{"result" => %{"content" => [%{"text" => json} | _]}} =
      call(token, "task_list", %{"limit" => 200})

    json |> Jason.decode!() |> Map.fetch!("tasks") |> Enum.map(& &1["id"])
  end

  defp call(token, name, arguments),
    do: rpc(token, "tools/call", %{"name" => name, "arguments" => arguments})

  defp rpc(token, method, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end
end
