defmodule Platform.Access.ResourceGrantsAcceptanceTest do
  @moduledoc """
  The acceptance suite for resource-scoped grants with inheritance and deny
  (task 01a1386d-e528 stage 5, RBAC stack member 3;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`).

  One describe block per acceptance line of the task, plus the grant-free
  equalities stage 4 left open. Every absence is preceded, in the same test
  and on the same fixture, by its POSITIVE CONTROL: the row is returned
  before the grant or deny that hides it exists. An absence without its
  control is not evidence.

  Permission names follow the registry and ADR § Precedence (a grant or deny
  applies to its own permission only): `tasks.read` for tasks, projects and
  stacks, `chat.read` for spaces, `canvas.read` for canvases and
  `memory.read` for org memory.

  ## Two premises this suite records rather than asserts away

    * **An agent-principal ALLOW adds nothing in this member.** A runtime's
      listings go through `Platform.Access.Query.where_readable/5`, which for
      an agent is `restrict/5` with no base: only a deny narrows. So "MCP
      `task_list` for an agent with a project-only allow shows only that
      project" is not true until stack member 5 (agent capping). Line 1
      tests the agent DENY path instead, and pins the allow premise so the
      member that changes it has to change this test too.
    * **A guest's project allow does not mint a canvas read level.**
      `CanvasAccess.fetch_for_viewer/3` closes the org-reach paths to
      external users, and an allow adds nothing there (stage 3), so a guest
      who is not a participant of the canvas's space is `:forbidden` even
      with `chat.read` and `canvas.read` on the project. The fetch cases
      below use a participant guest, and the premise is pinned.

  The ExternalScope switch hazard guard (a guest's ChatLive mount holds zero
  archived channels) lives in
  `test/platform_web/live/chat_live_access_scope_guest_test.exs` and runs in
  this stage's targeted set.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Canvas, CanvasAccess, ExternalScope, Participant, Space}
  alias Platform.Federation.ToolSurface
  alias Platform.MemoryFeedback
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath}
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachments, Task}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    _root = acme_org_id()
    %{org: tenant_org_id("rga")}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "rga-#{tag}-#{n}@example.com",
      name: "RGA #{tag} #{n}",
      oidc_sub: "rga-#{tag}-#{n}"
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

  defp project!(org, name \\ "rga") do
    {:ok, p} =
      Tasks.create_project(%{name: "#{name}-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project, title \\ "rga task"),
    do: Repo.insert!(%Task{project_id: project.id, title: title, status: "backlog"})

  defp space!(kind, org, metadata) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "rga-#{kind}-#{n}",
      slug: "rga-#{kind}-#{n}",
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

  defp agent!(prefix, historian? \\ false) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "#{prefix}-#{n}", name: "RGA #{prefix} #{n}", status: "active"})
      |> Repo.insert()

    if historian?, do: {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    agent
  end

  defp runtime!(owner, space \\ nil) do
    agent = agent!("rga-agent")
    if space, do: join!(space, "agent", agent.id)
    n = System.unique_integer([:positive])

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "rga-rt-#{n}",
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
        Platform.Access.RuntimeProfiles.translated_permissions(
          AgentRuntime.default_tool_profile()
        )
      )

    rt
  end

  defp call(rt, name, args),
    do: ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id, agent_id: rt.agent_id})

  defp ok!({:ok, value}), do: value
  defp ids(rows), do: rows |> Enum.map(&(Map.get(&1, :id) || Map.get(&1, "id"))) |> MapSet.new()

  defp mcp_task_ids(rt) do
    {:ok, %{tasks: rows}} = call(rt, "task_list", %{"limit" => 200})
    ids(rows)
  end

  defp exec_spaces(scope),
    do: ids(Chat.list_spaces(kind: "execution", include_execution: true, scope: scope))

  # ── 1. project-only access shows only that project's tasks ─────────────

  describe "1. project-only access shows only that project's tasks" do
    setup %{org: org} do
      p = project!(org, "rga-p")
      q = project!(org, "rga-q")
      n = System.unique_integer([:positive])

      %{
        p: p,
        q: q,
        tp: for(i <- 1..3, do: task!(p, "RGA P task #{n}-#{i}")),
        tq: for(i <- 1..3, do: task!(q, "RGA Q task #{n}-#{i}"))
      }
    end

    test "a guest with tasks.read on P reads only P's tasks and project", ctx do
      g = guest!(ctx.org)

      # Positive control: Q's rows exist and the unscoped reads return them.
      assert MapSet.subset?(ids(ctx.tq), ids(Tasks.list_all_tasks()))
      assert ctx.q.id in ids(Tasks.list_projects_unscoped())
      assert ids(Tasks.list_all_tasks(access_scope: scope(g))) == MapSet.new()

      ok!(Grants.grant(%{principal: g, permission: "tasks.read", resource: ctx.p}))
      s = scope(g)

      assert ids(Tasks.list_all_tasks(access_scope: s)) == ids(ctx.tp)
      assert ids(Tasks.list_projects_for_user(g, access_scope: s)) == MapSet.new([ctx.p.id])
    end

    # Substitution for "MCP task_list for an agent with a project-only
    # allow" (see the moduledoc): the agent DENY path, review case 7007
    # step 5.
    test "agent A denied on Q: task_list shows none of Q's ids and all of P's", ctx do
      rt = runtime!(member!(ctx.org))

      before = mcp_task_ids(rt)
      assert MapSet.subset?(ids(ctx.tq), before), "positive control: Q's tasks are listed"
      assert MapSet.subset?(ids(ctx.tp), before)

      ok!(
        Grants.deny(%{
          principal: {:agent, rt.agent_id},
          permission: "tasks.read",
          resource: ctx.q
        })
      )

      after_deny = mcp_task_ids(rt)
      assert MapSet.disjoint?(ids(ctx.tq), after_deny)
      assert MapSet.subset?(ids(ctx.tp), after_deny)
      assert after_deny == MapSet.difference(before, ids(ctx.tq))
    end

    # PREMISE PIN, not a requirement: stack member 5 (agent capping) is
    # expected to change this answer, and must change this test with it.
    test "premise: an agent-principal allow on P alone does not narrow task_list", ctx do
      rt = runtime!(member!(ctx.org))

      ok!(
        Grants.grant(%{
          principal: {:agent, rt.agent_id},
          permission: "tasks.read",
          resource: ctx.p
        })
      )

      listed = mcp_task_ids(rt)
      assert MapSet.subset?(ids(ctx.tp), listed)
      assert MapSet.subset?(ids(ctx.tq), listed)
    end

    test "a member's deny on Q drops Q's titles from the /tasks board; P's stay",
         %{conn: conn} = ctx do
      m = member!(ctx.org)
      conn = init_test_session(conn, %{"current_user_id" => m.id})

      {:ok, _view, html} = live(conn, "/tasks")
      for t <- ctx.tp ++ ctx.tq, do: assert(html =~ t.title, "positive control: #{t.title}")

      ok!(Grants.deny(%{principal: m, permission: "tasks.read", resource: ctx.q}))

      {:ok, _view, html} = live(conn, "/tasks")
      for t <- ctx.tp, do: assert(html =~ t.title)
      for t <- ctx.tq, do: refute(html =~ t.title)
    end
  end

  # ── 2. an inherited execution space is readable ────────────────────────

  describe "2. an inherited execution space is readable" do
    test "a guest with chat.read and canvas.read on P reads and lists a P task's execution space and its attached canvas",
         %{org: org} do
      g = guest!(org)
      p = project!(org)
      t = task!(p)
      c = exec_space!(t, org)
      k = canvas!(c, "rga attached canvas")

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, t.id, k.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      # Positive control: before the grant the guest sees none of it.
      refute ExternalScope.visible_space_id?(c.id, scope(g))
      refute c.id in exec_spaces(scope(g))
      assert Chat.list_canvases(c.id, scope: scope(g)) == []
      refute Access.can?(scope(g), "canvas.read", {:canvas, k.id})

      ok!(Grants.grant(%{principal: g, permission: "chat.read", resource: p}))
      ok!(Grants.grant(%{principal: g, permission: "canvas.read", resource: p}))
      s = scope(g)

      assert ExternalScope.visible_space_id?(c.id, s)
      assert c.id in exec_spaces(s)
      assert ids(Chat.list_canvases(c.id, scope: s)) == MapSet.new([k.id])
      assert Access.can?(s, "canvas.read", {:canvas, k.id})
    end

    test "nothing flows upward: a direct grant on R's execution space shows no R task",
         %{org: org} do
      g = guest!(org)
      r = project!(org)
      tr = task!(r)
      er = exec_space!(tr, org)

      assert tr.id in ids(Tasks.list_all_tasks()), "positive control: the R task exists"

      for perm <- ["chat.read", "tasks.read"] do
        ok!(Grants.grant(%{principal: g, permission: perm, resource: {:space, er.id}}))
      end

      s = scope(g)
      assert ExternalScope.visible_space_id?(er.id, s), "control: the space grant applies"
      refute tr.id in ids(Tasks.list_all_tasks(access_scope: s))
      refute r.id in ids(Tasks.list_projects_for_user(g, access_scope: s))
    end

    # PREMISE PIN (see the moduledoc): a project allow mints no canvas read
    # level for a guest who is not a participant of the space.
    test "premise: a non-participant guest's project allow does not make fetch_for_viewer/3 succeed",
         %{org: org} do
      g = guest!(org)
      p = project!(org)
      c = exec_space!(task!(p), org)
      k = canvas!(c, "rga premise canvas")

      for perm <- ["chat.read", "canvas.read"],
          do: ok!(Grants.grant(%{principal: g, permission: perm, resource: p}))

      assert {:error, :forbidden} =
               CanvasAccess.fetch_for_viewer(k.id, {:user, g.id}, access_scope: scope(g))

      join!(c, "user", g.id)

      assert {:ok, %Canvas{}, :member} =
               CanvasAccess.fetch_for_viewer(k.id, {:user, g.id}, access_scope: scope(g))
    end
  end

  # ── 3. a deny on one canvas hides it even with project access ──────────

  describe "3. a deny on one canvas hides it even with project access" do
    setup %{org: org} do
      g = guest!(org)
      p = project!(org)
      t = task!(p)
      c = exec_space!(t, org)
      join!(c, "user", g.id)
      k1 = canvas!(c, "rga K1")
      k2 = canvas!(c, "rga K2")

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, t.id, k1.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      for perm <- ["chat.read", "canvas.read"],
          do: ok!(Grants.grant(%{principal: g, permission: perm, resource: p}))

      %{g: g, p: p, t: t, c: c, k1: k1, k2: k2}
    end

    test "list_canvases/2 and fetch_for_viewer/3 for guest G", ctx do
      viewer = {:user, ctx.g.id}
      both = MapSet.new([ctx.k1.id, ctx.k2.id])

      assert ids(Chat.list_canvases(ctx.c.id, access_scope: scope(ctx.g))) == both

      assert {:ok, _, _} =
               CanvasAccess.fetch_for_viewer(ctx.k1.id, viewer, access_scope: scope(ctx.g))

      ok!(Grants.deny(%{principal: ctx.g, permission: "canvas.read", resource: ctx.k1}))
      s = scope(ctx.g)

      assert ids(Chat.list_canvases(ctx.c.id, access_scope: s)) == MapSet.new([ctx.k2.id])

      assert CanvasAccess.fetch_for_viewer(ctx.k1.id, viewer, access_scope: s) ==
               CanvasAccess.fetch_for_viewer(Ecto.UUID.generate(), viewer, access_scope: s)

      assert {:error, :not_found} =
               CanvasAccess.fetch_for_viewer(ctx.k1.id, viewer, access_scope: s)

      assert {:ok, _, _} = CanvasAccess.fetch_for_viewer(ctx.k2.id, viewer, access_scope: s)
    end

    test "MCP canvas_list and canvas_get for agent A: K1 answers like a nonexistent id", ctx do
      rt = runtime!(member!(ctx.org), ctx.c)

      listed = fn ->
        {:ok, %{canvases: rows}} = call(rt, "canvas_list", %{"space_id" => ctx.c.id})
        ids(rows)
      end

      get = fn id -> call(rt, "canvas_get", %{"canvas_id" => id}) end

      # Positive control: K1 is listed AND fetchable before the deny.
      assert listed.() == MapSet.new([ctx.k1.id, ctx.k2.id])
      assert {:ok, %{id: k1_id, title: "rga K1"}} = get.(ctx.k1.id)
      assert k1_id == ctx.k1.id

      ok!(
        Grants.deny(%{
          principal: {:agent, rt.agent_id},
          permission: "canvas.read",
          resource: ctx.k1
        })
      )

      assert listed.() == MapSet.new([ctx.k2.id])

      random = Ecto.UUID.generate()
      assert {:error, denied} = get.(ctx.k1.id)
      assert {:error, missing} = get.(random)

      # The same envelope, key for key and byte for byte, once the caller's
      # own id (echoed in `canvas_id` and in the error text) is swapped.
      assert Jason.encode!(denied) ==
               missing |> Jason.encode!() |> String.replace(random, ctx.k1.id)

      refute Jason.encode!(denied) =~ "rga K1"

      assert {:ok, %{id: k2_id}} = get.(ctx.k2.id)
      assert k2_id == ctx.k2.id
    end

    test "the canvas explorer's On this task group drops a denied attachment", %{conn: conn} do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{email: "rga-ex-#{n}@example.com", name: "Ex", oidc_sub: "rga-ex-#{n}"})

      {:ok, project} = Tasks.create_project(%{name: "rga explorer #{n}"})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "rga ex #{n}", status: "backlog"})

      {:ok, space} =
        Chat.create_space(%{
          name: "RGA Exec #{n}",
          slug: "rga-ex-#{n}",
          kind: "execution",
          metadata: %{"task_id" => task.id}
        })

      {:ok, author} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "RGA Bot",
          joined_at: DateTime.utc_now()
        })

      [k1, k2] =
        for title <- ["RGA attached one #{n}", "RGA attached two #{n}"] do
          {:ok, c} =
            Chat.create_canvas(%{
              "space_id" => space.id,
              "created_by" => author.id,
              "title" => title
            })

          {:ok, _} =
            CanvasAttachments.attach_canvas(:system, task.id, c.id,
              attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
            )

          c
        end

      conn = init_test_session(conn, current_user_id: user.id)

      open = fn ->
        {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}", on_error: :warn)
        render_click(view, "canvas_panel_toggle", %{})
        render(view)
      end

      html = open.()
      assert task_group_titles(html) == [k1.title, k2.title], "positive control"

      ok!(Grants.deny(%{principal: user, permission: "canvas.read", resource: k1}))

      html = open.()
      assert task_group_titles(html) == [k2.title]
      refute html =~ k1.title
    end
  end

  defp task_group_titles(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-group-key="task"] [data-role="canvas-explorer-row-title"]))
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  # ── 4. a memory subtree grant survives memory_rename ───────────────────

  describe "4. a memory subtree grant survives memory_rename" do
    setup do
      Repo.delete_all(NodePath)
      Repo.delete_all(Node)
      Repo.delete_all(WikiPage)
      prev = Application.get_env(:platform, :memory_service, [])
      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      :ok
    end

    test "a guest-role allow on org/page/eng/ and a child deny move with MCP memory_rename",
         %{org: org} do
      g = guest!(org)
      g2 = guest!(org)
      historian = agent!("rga-historian", true)
      {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "x"})
      {:ok, _} = Wiki.upsert_page("org/page/eng/secret/plan.md", %{content: "plan"})
      {:ok, _} = Wiki.upsert_page("org/page/top.md", %{content: "top"})

      listed = fn u ->
        u |> scope() |> then(&Wiki.list_pages(access_scope: &1)) |> Enum.map(& &1.file_key)
      end

      can = fn u, path -> Access.can?(scope(u), "memory.read", {:memory, path}) end

      # Positive control: with no memory grant the guest's listing is today's.
      assert "org/page/top.md" in listed.(g)

      ok!(
        Grants.grant(%{
          principal: {:role, "guest"},
          permission: "memory.read",
          resource: {:memory, "org/page/eng/"},
          org_id: org
        })
      )

      assert Enum.sort(listed.(g)) == ["org/page/eng/secret/plan.md", "org/page/eng/x.md"],
             "control: the allow covers the whole subtree before the deny"

      ok!(
        Grants.deny(%{
          principal: {:role, "guest"},
          permission: "memory.read",
          resource: {:memory, "org/page/eng/secret/plan.md"},
          org_id: org
        })
      )

      for u <- [g, g2], do: assert(listed.(u) == ["org/page/eng/x.md"])

      grants_before = Repo.all(from(x in Grant, order_by: x.id, select: {x.id, x.resource_id}))

      assert {:ok, %{count: 2}} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/eng/", "new_path" => "org/page/engineering/"},
                 %{agent_id: historian.id}
               )

      assert listed.(g) == ["org/page/engineering/x.md"]
      assert can.(g, "org/page/engineering/x.md")
      refute can.(g, "org/page/engineering/secret/plan.md")
      assert Wiki.get_page("org/page/engineering/secret/plan.md"), "the page itself moved"

      {:ok, _} = Wiki.upsert_page("org/page/eng/y.md", %{content: "fresh"})
      refute can.(g, "org/page/eng/y.md")
      refute "org/page/eng/y.md" in listed.(g)

      assert Repo.all(from(x in Grant, order_by: x.id, select: {x.id, x.resource_id})) ==
               grants_before
    end
  end

  # ── grant-free equalities stage 4 left open ────────────────────────────

  describe "no grants means today's answer" do
    setup do
      prev = Application.get_env(:platform, :memory_service, [])
      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      :ok
    end

    test "MemoryFeedback.list_recent/1 and Wiki.get_page/2 equal their unscoped answers",
         %{org: org} do
      path = "org/page/rga-eq-#{System.unique_integer([:positive])}.md"
      {:ok, _} = Wiki.upsert_page(path, %{content: "eq"})

      {:ok, _} =
        MemoryFeedback.record_edit(%{
          original_content: "before",
          edited_content: "after",
          path: path,
          namespace: "org_context"
        })

      unscoped_rows = MemoryFeedback.list_recent(feedback_kind: "edit", limit: 50)
      assert path in Enum.map(unscoped_rows, & &1.path), "control: the row exists"
      assert %WikiPage{} = unscoped_page = Wiki.get_page(path)

      scopes = [
        scope(member!(org)),
        scope(guest!(org)),
        Scope.for_runtime(runtime!(member!(org)))
      ]

      for s <- scopes do
        assert s.grants == []

        assert MemoryFeedback.list_recent(feedback_kind: "edit", limit: 50, access_scope: s) ==
                 unscoped_rows

        assert Wiki.get_page(path, access_scope: s) == unscoped_page
        assert Wiki.get_page("org/page/rga-absent.md", access_scope: s) == nil
      end
    end
  end
end
