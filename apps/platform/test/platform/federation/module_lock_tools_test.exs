defmodule Platform.Federation.ModuleLockToolsTest do
  @moduledoc """
  Task 01a14721 stage 2: MCP refusal under a MODULE LOCK. The runtime's
  owner U (an internal member of sub-org S) is locked out of `tasks` and
  `files`. Its control twin is owned by V, an unlocked member of the same
  org with the same tool profile.

    (a) `tools/list` over HTTP omits every tasks/files tool, and nothing
        else: the locked list is the control list minus exactly those.
    (b) Calling the HANDLER directly (`ToolSurface.execute/3`, bypassing
        `Platform.Access.Tools.authorize/2`) refuses `task_get` and
        `file_list` with the envelope an unknown id gets. This is the case
        mutation P-can (can?/check/within ignoring the lock) must turn red:
        the handlers re-check through `Platform.Access.check/3`.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, RuntimeProfiles, Scope, ToolPermissions}
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership

  @profile ["task", "files" | AgentRuntime.default_tool_profile()]
  @locked_tools ~w(task_get task_list file_list file_get_text)

  defp uniq, do: System.unique_integer([:positive])

  defp member!(org, tag) do
    n = uniq()

    u =
      Repo.insert!(%User{
        email: "locktools-#{tag}-#{n}@example.com",
        name: "Locktools #{tag} #{n}",
        oidc_sub: "locktools-#{tag}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp runtime!(owner) do
    token = AgentRuntime.generate_token()

    rt =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "locktools-rt-#{uniq()}",
        owner_user_id: owner.id,
        auth_token_hash: AgentRuntime.hash_token(token),
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} =
      RuntimeProfiles.create_for_runtime(
        rt,
        @profile,
        RuntimeProfiles.translated_permissions(@profile)
      )

    {rt, token}
  end

  defp tools_list(conn, token) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})
    |> json_response(200)
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
  end

  defp call(rt, name, args), do: ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id})

  setup do
    s = tenant_org_id("locktools_s_#{uniq()}")
    u = member!(s, "u")
    v = member!(s, "v")

    {:ok, p} = Tasks.create_project(%{name: "locktools-p-#{uniq()}", org_id: s})

    t =
      Repo.insert!(%Task{project_id: p.id, title: "locktools task #{uniq()}", status: "backlog"})

    {locked_rt, locked_token} = runtime!(u)
    {control_rt, control_token} = runtime!(v)

    for module <- ~w(tasks files) do
      {:ok, _} =
        Grants.deny(
          %{principal: {:user, u.id}, permission: module, resource: {:module, s}},
          actor: Scope.system()
        )
    end

    %{
      s: s,
      p: p,
      t: t,
      locked_rt: locked_rt,
      locked_token: locked_token,
      control_rt: control_rt,
      control_token: control_token
    }
  end

  test "(a) tools/list over HTTP omits the locked modules' tools and nothing else", ctx do
    control = tools_list(ctx.conn, ctx.control_token)
    locked = tools_list(ctx.conn, ctx.locked_token)

    # Positive control: the unlocked twin lists every tool under test.
    for name <- @locked_tools, do: assert(name in control, name)

    for name <- @locked_tools, do: refute(name in locked, name)

    locked_permission? = fn name ->
      String.starts_with?(ToolPermissions.for_tool(name) || "", ["tasks.", "files."])
    end

    assert locked == Enum.reject(control, locked_permission?)
  end

  test "(b) task_get, called on the handler directly, is the unknown-id not-found envelope",
       ctx do
    # Positive control: the unlocked twin reads the task through the handler.
    assert {:ok, %{}} = call(ctx.control_rt, "task_get", %{"task_id" => ctx.t.id})

    random = Ecto.UUID.generate()
    assert {:error, refused} = call(ctx.locked_rt, "task_get", %{"task_id" => ctx.t.id})
    assert {:error, unknown} = call(ctx.locked_rt, "task_get", %{"task_id" => random})

    assert refused.error == "Task not found: #{ctx.t.id}"
    assert Map.delete(refused, :error) == Map.delete(unknown, :error)
  end

  test "(b) file_list, called on the handler directly, is the unknown-project envelope", ctx do
    # Positive control: the unlocked twin lists the project's files.
    assert {:ok, _} = call(ctx.control_rt, "file_list", %{"project_id" => ctx.p.id})

    assert {:error, refused} = call(ctx.locked_rt, "file_list", %{"project_id" => ctx.p.id})

    assert {:error, unknown} =
             call(ctx.locked_rt, "file_list", %{"project_id" => Ecto.UUID.generate()})

    assert refused.code == :not_found
    assert refused == unknown
  end
end
