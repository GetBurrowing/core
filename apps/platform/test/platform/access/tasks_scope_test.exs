defmodule Platform.Access.TasksScopeTest do
  @moduledoc """
  Task 01a1386d-e528 stage 3: `Platform.Tasks.scope_by/3` wired into the
  task, project and stack listings through the optional `:access_scope` opt
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`).

  Every absence is preceded, on the same fixture, by its positive control:
  the row is returned before the grant or deny that hides it exists.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks, Task}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    _root = acme_org_id()
    org = tenant_org_id("sxi")
    p = project!(org)
    q = project!(org)

    %{
      org: org,
      p: p,
      q: q,
      tp: [task!(p), task!(p)],
      tq: [task!(q), task!(q)],
      sp: stack!(p),
      sq: stack!(q)
    }
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ts-#{tag}-#{n}@example.com",
      name: "TS #{tag} #{n}",
      oidc_sub: "ts-#{tag}-#{n}"
    })
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp member!(org) do
    u = user!("member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp project!(org) do
    {:ok, p} =
      Tasks.create_project(%{name: "ts-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project),
    do: Repo.insert!(%Task{project_id: project.id, title: "ts task", status: "backlog"})

  defp stack!(project) do
    seq = System.unique_integer([:positive])

    %Stack{}
    |> Stack.changeset(%{
      project_id: project.id,
      slug: "ts-stack-#{seq}",
      name: "TS Stack #{seq}",
      base_branch: "main",
      rollup_branch: "stack/ts-#{seq}"
    })
    |> Repo.insert!()
  end

  defp runtime!(owner) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "ts-agent-#{n}", name: "TS Agent #{n}", status: "active"})
      |> Repo.insert()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "ts-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active",
        allowed_bundles: AgentRuntime.default_allowed_bundles()
      })
      |> Repo.insert()

    rt
  end

  defp ok!({:ok, value}), do: value
  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  defp board_ids(columns),
    do: columns |> Map.values() |> List.flatten() |> ids()

  defp mcp_ids(name, rt, args \\ %{}) do
    {:ok, %{} = env} =
      ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id, agent_id: rt.agent_id})

    # The MCP transport JSON-encodes every result: the caller's Scope must
    # never ride along in it (it is not JSON, and it is not the caller's
    # filter to echo).
    encoded = Jason.encode!(env)
    refute encoded =~ "access_scope"
    refute encoded =~ "Platform.Access"

    key = %{"task_list" => :tasks, "project_list" => :projects, "stack_list" => :stacks}[name]
    env |> Map.fetch!(key) |> Enum.map(&(&1[:id] || &1["id"])) |> MapSet.new()
  end

  describe "a guest with an allow on project P" do
    test "sees only P's tasks, projects and stacks", ctx do
      g = guest!(ctx.org)
      all_p = ids(ctx.tp)
      all_q = ids(ctx.tq)

      # Positive control: the foreign project's rows exist and the unscoped
      # read returns them.
      assert MapSet.subset?(all_q, ids(Tasks.list_all_tasks()))
      assert ctx.q.id in ids(Tasks.list_projects_unscoped())
      assert ctx.sq.id in ids(Stacks.list_stacks())

      # A guest holds no tasks.read: before the grant it reads nothing.
      assert ids(Tasks.list_all_tasks(access_scope: scope(g))) == MapSet.new()

      ok!(Grants.grant(%{principal: g, permission: "tasks.read", resource: ctx.p}))
      s = scope(g)

      assert ids(Tasks.list_all_tasks(access_scope: s)) == all_p
      assert ids(Tasks.list_tasks(access_scope: s)) == all_p
      assert ids(Tasks.list_tasks_page([access_scope: s], limit: 50)) == all_p
      assert Tasks.count_tasks(access_scope: s) == MapSet.size(all_p)
      assert board_ids(Tasks.list_by_status(access_scope: s)) == all_p
      assert ids(Tasks.list_projects_unscoped(access_scope: s)) == MapSet.new([ctx.p.id])
      assert ids(Tasks.list_projects_for_user(g, access_scope: s)) == MapSet.new([ctx.p.id])
      assert ids(Stacks.list_stacks(%{access_scope: s})) == MapSet.new([ctx.sp.id])
      assert Stacks.count_stacks(%{access_scope: s}) == 1

      assert [{%Stack{id: sp_id}, _}] = Stacks.list_stacks_with_members(%{access_scope: s})
      assert sp_id == ctx.sp.id
    end
  end

  describe "a member with a deny on project Q" do
    test "loses only Q's rows", ctx do
      m = member!(ctx.org)
      all_p = ids(ctx.tp)
      all_q = ids(ctx.tq)

      before = ids(Tasks.list_all_tasks(access_scope: scope(m)))
      assert MapSet.subset?(all_p, before)
      assert MapSet.subset?(all_q, before), "positive control: Q's tasks are on the board first"

      ok!(Grants.deny(%{principal: m, permission: "tasks.read", resource: ctx.q}))
      s = scope(m)

      after_ids = ids(Tasks.list_all_tasks(access_scope: s))
      assert MapSet.subset?(all_p, after_ids)
      assert MapSet.disjoint?(all_q, after_ids)
      assert after_ids == MapSet.difference(before, all_q)

      board = board_ids(Tasks.list_by_status(access_scope: s))
      assert MapSet.subset?(all_p, board) and MapSet.disjoint?(all_q, board)

      # The scope-rail badge counts what the board shows, not what it hides.
      root = Platform.Tenancy.root_org_slug()
      unscoped = Tasks.count_by_scope()[root]
      assert Tasks.count_by_scope(access_scope: scope(m))[root] == unscoped - MapSet.size(all_q)
      assert Tasks.count_by_scope(access_scope: nil) == Tasks.count_by_scope()

      projects = ids(Tasks.list_projects_for_user(m, access_scope: s))
      assert ctx.p.id in projects
      refute ctx.q.id in projects

      stacks = ids(Stacks.list_stacks(%{access_scope: s}))
      assert ctx.sp.id in stacks
      refute ctx.sq.id in stacks
    end

    test "a Q member of a visible stack is dropped from that stack's members", ctx do
      m = member!(ctx.org)
      [q_task | _] = ctx.tq
      Repo.update!(Ecto.Changeset.change(q_task, stack_id: ctx.sp.id, stack_position: 1))
      [p_task | _] = ctx.tp
      Repo.update!(Ecto.Changeset.change(p_task, stack_id: ctx.sp.id, stack_position: 2))

      members = fn s ->
        %{access_scope: s}
        |> Stacks.list_stacks_with_members()
        |> Enum.find(fn {stack, _} -> stack.id == ctx.sp.id end)
        |> elem(1)
        |> Map.fetch!(:member_count)
      end

      assert members.(scope(m)) == 2

      ok!(Grants.deny(%{principal: m, permission: "tasks.read", resource: ctx.q}))
      assert members.(scope(m)) == 1
    end
  end

  describe "no grants equals base" do
    test "an internal member's scoped listings equal the unscoped ones", ctx do
      m = member!(ctx.org)
      s = scope(m)
      assert s.grants == []

      assert ids(Tasks.list_all_tasks(access_scope: s)) == ids(Tasks.list_all_tasks())
      assert ids(Tasks.list_tasks(access_scope: s)) == ids(Tasks.list_tasks([]))
      assert Tasks.count_tasks(access_scope: s) == Tasks.count_tasks([])
      assert board_ids(Tasks.list_by_status(access_scope: s)) == board_ids(Tasks.list_by_status())

      assert ids(Tasks.list_projects_for_user(m, access_scope: s)) ==
               ids(Tasks.list_projects_for_user(m))

      assert ids(Stacks.list_stacks(%{access_scope: s})) == ids(Stacks.list_stacks())
    end

    test "an absent :access_scope builds the same query as base", _ctx do
      assert inspect(Ecto.Queryable.to_query(Tasks.maybe_scope_by(Task, nil, :task))) ==
               inspect(Ecto.Queryable.to_query(Task))
    end
  end

  describe "MCP listings for an agent runtime" do
    test "zero grants: today's rows; an agent-principal deny on Q drops only Q", ctx do
      owner = member!(ctx.org)
      rt = runtime!(owner)
      all_p = ids(ctx.tp)
      all_q = ids(ctx.tq)

      before = mcp_ids("task_list", rt, %{"limit" => 100})
      assert MapSet.subset?(all_q, before), "positive control: Q's tasks are listed first"
      assert MapSet.subset?(all_p, before)
      assert ctx.q.id in mcp_ids("project_list", rt)
      assert ctx.sq.id in mcp_ids("stack_list", rt)

      ok!(
        Grants.deny(%{
          principal: {:agent, rt.agent_id},
          permission: "tasks.read",
          resource: ctx.q
        })
      )

      after_ids = mcp_ids("task_list", rt, %{"limit" => 100})
      assert MapSet.disjoint?(all_q, after_ids)
      assert MapSet.subset?(all_p, after_ids)
      refute ctx.q.id in mcp_ids("project_list", rt)
      assert ctx.p.id in mcp_ids("project_list", rt)
      refute ctx.sq.id in mcp_ids("stack_list", rt)
      assert ctx.sp.id in mcp_ids("stack_list", rt)
    end

    test "a different agent's deny does not reach this runtime", ctx do
      owner = member!(ctx.org)
      rt = runtime!(owner)
      other = runtime!(owner)

      ok!(
        Grants.deny(%{
          principal: {:agent, other.agent_id},
          permission: "tasks.read",
          resource: ctx.q
        })
      )

      assert MapSet.subset?(ids(ctx.tq), mcp_ids("task_list", rt, %{"limit" => 100}))
      assert MapSet.disjoint?(ids(ctx.tq), mcp_ids("task_list", other, %{"limit" => 100}))
    end
  end
end
