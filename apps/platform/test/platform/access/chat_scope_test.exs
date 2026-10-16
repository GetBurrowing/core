defmodule Platform.Access.ChatScopeTest do
  @moduledoc """
  Task 01a1386d-e528 stage 3: explicit grants composed into the Chat reads
  (`Chat.scope_by/3`, `ExternalScope`'s `%Platform.Access.Scope{}` clauses,
  `CanvasAccess.fetch_for_viewer/3`, MCP `canvas_list`), per
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`.

  Every absence is preceded, on the same fixture, by its positive control.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Canvas, CanvasAccess, ExternalScope, Participant, Space}
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    _root = acme_org_id()
    %{org: tenant_org_id("sxi")}
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "cs-#{tag}-#{n}@example.com",
      name: "CS #{tag} #{n}",
      oidc_sub: "cs-#{tag}-#{n}"
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
      Tasks.create_project(%{name: "cs-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project), do: Repo.insert!(%Task{project_id: project.id, title: "cs task"})

  defp space!(kind, org, metadata \\ %{}) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "cs-#{kind}-#{n}",
      slug: "cs-#{kind}-#{n}",
      org_id: org,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp exec_space!(task, org), do: space!("execution", org, %{"task_id" => task.id})

  defp join!(space, type, id) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: type,
      participant_id: id,
      role: "member",
      joined_at: DateTime.utc_now()
    })
  end

  defp canvas!(space, title) do
    author = join!(space, "user", Ecto.UUID.generate())
    Repo.insert!(%Canvas{space_id: space.id, created_by: author.id, title: title})
  end

  defp runtime!(owner, space) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "cs-agent-#{n}", name: "CS Agent #{n}", status: "active"})
      |> Repo.insert()

    join!(space, "agent", agent.id)

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "cs-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        rt,
        AgentRuntime.default_tool_profile(),
        Platform.Access.RuntimeProfiles.translated_permissions(AgentRuntime.default_tool_profile())
      )

    rt
  end

  defp ok!({:ok, value}), do: value
  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  defp exec_spaces(scope),
    do: ids(Chat.list_spaces(kind: "execution", include_execution: true, scope: scope))

  describe "an inherited execution space is readable" do
    test "a guest with chat.read on project P reads and lists a P task's execution space",
         %{org: org} do
      g = guest!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)
      k = canvas!(c, "exec canvas")
      other = exec_space!(task!(project!(org)), org)

      # Positive control: absent before the grant.
      refute ExternalScope.visible_space_id?(c.id, scope(g))
      refute c.id in exec_spaces(scope(g))
      assert Chat.list_canvases(c.id, scope: scope(g)) == []

      ok!(Grants.grant(%{principal: g, permission: "chat.read", resource: p}))
      s = scope(g)

      assert ExternalScope.visible_space_id?(c.id, s)
      assert c.id in exec_spaces(s)
      assert ids(Chat.list_canvases(c.id, scope: s)) == MapSet.new([k.id])

      # The grant covers P's execution spaces and nothing else.
      refute ExternalScope.visible_space_id?(other.id, s)
      refute other.id in exec_spaces(s)
    end

    test "the guest's participant spaces stay visible beside the grant", %{org: org} do
      g = guest!(org)
      mine = space!("channel", org)
      join!(mine, "user", g.id)
      p = project!(org)
      _c = exec_space!(task!(p), org)

      ok!(Grants.grant(%{principal: g, permission: "chat.read", resource: p}))
      assert ExternalScope.visible_space_id?(mine.id, scope(g))
      assert mine.id in ids(Chat.list_spaces(kind: "channel", scope: scope(g)))
    end
  end

  describe "example (a): a deny on P beats a direct grant on C" do
    test "C is hidden", %{org: org} do
      g = guest!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)

      ok!(Grants.grant(%{principal: g, permission: "chat.read", resource: c}))
      assert ExternalScope.visible_space_id?(c.id, scope(g)), "positive control"
      assert c.id in exec_spaces(scope(g))

      ok!(Grants.deny(%{principal: g, permission: "chat.read", resource: p}))
      refute ExternalScope.visible_space_id?(c.id, scope(g))
      refute c.id in exec_spaces(scope(g))
    end
  end

  describe "a deny on one canvas" do
    setup %{org: org} do
      m = member!(org)
      space = space!("channel", org)
      join!(space, "user", m.id)
      k = canvas!(space, "denied canvas")
      sibling = canvas!(space, "sibling canvas")
      %{m: m, space: space, k: k, sibling: sibling}
    end

    test "hides it from list_canvases/2 and list_canvas_groups/2; siblings stay", ctx do
      both = MapSet.new([ctx.k.id, ctx.sibling.id])
      assert ids(Chat.list_canvases(ctx.space.id, access_scope: scope(ctx.m))) == both

      [group] = Chat.list_canvas_groups([ctx.space.id], access_scope: scope(ctx.m))
      assert group.total_count == 2

      ok!(Grants.deny(%{principal: ctx.m, permission: "canvas.read", resource: ctx.k}))
      s = scope(ctx.m)

      assert ids(Chat.list_canvases(ctx.space.id, access_scope: s)) ==
               MapSet.new([ctx.sibling.id])

      assert ids(Chat.list_canvases(ctx.space.id, scope: s)) == MapSet.new([ctx.sibling.id])

      [group] = Chat.list_canvas_groups([ctx.space.id], access_scope: s)
      assert group.total_count == 1
      assert ids(group.rows) == MapSet.new([ctx.sibling.id])

      # No scope: unchanged.
      assert ids(Chat.list_canvases(ctx.space.id)) == both
    end

    test "fetch_for_viewer/3 answers a denied canvas exactly like a missing one", ctx do
      viewer = {:user, ctx.m.id}

      assert {:ok, %Canvas{}, :member} =
               CanvasAccess.fetch_for_viewer(ctx.k.id, viewer, access_scope: scope(ctx.m))

      ok!(Grants.deny(%{principal: ctx.m, permission: "canvas.read", resource: ctx.k}))
      s = scope(ctx.m)

      assert CanvasAccess.fetch_for_viewer(ctx.k.id, viewer, access_scope: s) ==
               CanvasAccess.fetch_for_viewer(Ecto.UUID.generate(), viewer, access_scope: s)

      assert {:error, :not_found} =
               CanvasAccess.fetch_for_viewer(ctx.k.id, viewer, access_scope: s)

      assert {:ok, %Canvas{}, :member} =
               CanvasAccess.fetch_for_viewer(ctx.sibling.id, viewer, access_scope: s)

      # Without the opt the existing grant path still answers (writer and
      # other callers are unchanged).
      assert {:ok, %Canvas{}, :member} = CanvasAccess.fetch_for_viewer(ctx.k.id, viewer)
    end

    test "a deny on the project above an execution space covers its canvases", %{org: org} do
      m = member!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)
      join!(c, "user", m.id)
      k = canvas!(c, "exec canvas")

      assert ids(Chat.list_canvases(c.id, access_scope: scope(m))) == MapSet.new([k.id])
      ok!(Grants.deny(%{principal: m, permission: "canvas.read", resource: p}))
      assert Chat.list_canvases(c.id, access_scope: scope(m)) == []
    end

    test "MCP canvas_list drops a canvas an agent-principal deny covers", ctx do
      rt = runtime!(ctx.m, ctx.space)
      context = %{runtime_id: rt.runtime_id, agent_id: rt.agent_id}

      list = fn ->
        {:ok, %{canvases: rows}} =
          ToolSurface.execute("canvas_list", %{"space_id" => ctx.space.id}, context)

        ids(rows)
      end

      assert list.() == MapSet.new([ctx.k.id, ctx.sibling.id])

      ok!(
        Grants.deny(%{
          principal: {:agent, rt.agent_id},
          permission: "canvas.read",
          resource: ctx.k
        })
      )

      assert list.() == MapSet.new([ctx.sibling.id])
    end
  end

  describe "no grants equals base" do
    test "Scope-scoped chat reads equal the ExternalScope reads", %{org: org} do
      m = member!(org)
      g = guest!(org)
      ch = space!("channel", org)
      join!(ch, "user", g.id)
      _other = space!("channel", org)
      k = canvas!(ch, "k")

      for u <- [m, g] do
        s = scope(u)
        ext = ExternalScope.for_user(u.id)
        assert s.grants == []

        assert ids(Chat.list_spaces(kind: "channel", scope: s)) ==
                 ids(Chat.list_spaces(kind: "channel", scope: ext))

        assert ids(Chat.list_canvases(ch.id, scope: s)) ==
                 ids(Chat.list_canvases(ch.id, scope: ext))

        assert ExternalScope.visible_space_id?(ch.id, s) ==
                 ExternalScope.visible_space_id?(ch.id, ext)
      end

      assert k.id in ids(Chat.list_canvases(ch.id, scope: scope(g)))
    end
  end
end
