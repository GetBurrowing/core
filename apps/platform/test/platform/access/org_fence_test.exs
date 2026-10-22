defmodule Platform.Access.OrgFenceTest do
  @moduledoc """
  The org fence (task 01a14721 stage 1, `Platform.Access.org_fence/1`): an
  INTERNAL user whose memberships are all in non-root orgs is limited to
  those orgs at the single decision point in `Platform.Access`, and every
  listing and point read below inherits it.

  The world: a sub-org S (projects, tasks, channels) and the root org R (a
  project, a task, channels, an execution space and a system space). M is a
  member of S only. Every absence is preceded, on the same fixture, by its
  POSITIVE CONTROL: the row exists and an unfenced reader (the root member,
  or today's unscoped call) sees it. An absence without its control is not
  evidence.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ExternalScope, Participant, Space}
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "fence-#{tag}-#{n}@example.com",
      name: "Fence #{tag} #{n}",
      oidc_sub: "fence-#{tag}-#{n}"
    })
  end

  defp member!(org, tag \\ "member") do
    u = user!(tag)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp project!(org, name) do
    {:ok, p} =
      Tasks.create_project(%{name: "#{name}-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project, title),
    do: Repo.insert!(%Task{project_id: project.id, title: title, status: "backlog"})

  defp space!(kind, org, metadata \\ %{}) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "fence-#{kind}-#{n}",
      slug: "fence-#{kind}-#{n}",
      org_id: org,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp join!(space, user) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      role: "member",
      joined_at: DateTime.utc_now()
    })
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp runtime!(owner) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "fence-agent-#{n}", name: "Fence agent #{n}", status: "active"})
      |> Repo.insert()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "fence-rt-#{n}",
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

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()
  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp user_rows(space),
    do:
      space.id
      |> Chat.list_participants()
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Enum.sort()

  defp channels(scope), do: ids(Chat.list_spaces(kind: "channel", scope: scope))

  setup do
    root = acme_org_id()
    s = tenant_org_id("fence_s_#{System.unique_integer([:positive])}")
    n = System.unique_integer([:positive])

    m = member!(s, "m")
    root_member = member!(root, "root")

    ps = project!(s, "fence-ps")
    pr = project!(root, "fence-pr")
    ts = task!(ps, "Fence S task #{n}")
    tr = task!(pr, "Fence R task #{n}")

    cs = space!("channel", s)
    cs_unjoined = space!("channel", s)

    cr =
      "channel"
      |> space!(root)
      |> Ecto.Changeset.change(name: "Root Lounge #{n}")
      |> Repo.update!()

    er = space!("execution", root, %{"task_id" => tr.id})
    sr = space!("system", nil)
    dm = space!("dm", nil)

    _ = join!(cs, m)
    m_dm = join!(dm, m)
    _ = join!(dm, root_member)
    rm_cr = join!(cr, root_member)
    _ = post!(cr, rm_cr, "fencepost root secret #{n}")
    _ = post!(dm, m_dm, "fencepost direct note #{n}")

    %{
      root: root,
      s: s,
      n: n,
      m: m,
      root_member: root_member,
      ps: ps,
      pr: pr,
      ts: ts,
      tr: tr,
      cs: cs,
      cs_unjoined: cs_unjoined,
      cr: cr,
      er: er,
      sr: sr,
      dm: dm
    }
  end

  # ── org_fence/1 ─────────────────────────────────────────────────────────

  describe "org_fence/1" do
    test "a sub-org-only member is fenced to exactly their orgs", ctx do
      assert Access.org_fence(scope(ctx.m)) == [ctx.s]

      other = tenant_org_id("fence_o_#{ctx.n}")

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: ctx.m.id, org_id: other, role: "member"})
      |> Repo.insert!()

      assert Access.org_fence(scope(ctx.m)) == Enum.sort([ctx.s, other])
    end

    test "root members, guests, zero-membership, system and a runtime's own side are unfenced",
         ctx do
      assert Access.org_fence(scope(ctx.root_member)) == :unfenced
      assert Access.org_fence(scope(guest!(ctx.s))) == :unfenced
      assert Access.org_fence(scope(user!("zero"))) == :unfenced
      assert Access.org_fence(Scope.system()) == :unfenced
      assert Access.org_fence(Scope.for_runtime(runtime!(ctx.m))) == :unfenced
    end

    test "a root membership beside a sub-org one unfences (no partial fence)", ctx do
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: ctx.m.id, org_id: ctx.root, role: "member"})
      |> Repo.insert!()

      assert Access.org_fence(scope(ctx.m)) == :unfenced
    end
  end

  # ── tasks ───────────────────────────────────────────────────────────────

  describe "tasks" do
    test "list_all_tasks(access_scope:) is S only for M; a root member's equals today's", ctx do
      all = ids(Tasks.list_all_tasks())
      assert ctx.tr.id in all and ctx.ts.id in all

      fenced = Tasks.list_all_tasks(access_scope: scope(ctx.m))
      assert ctx.ts.id in ids(fenced)
      refute ctx.tr.id in ids(fenced)
      assert Enum.all?(fenced, &(&1.project.org_id == ctx.s))

      assert ids(Tasks.list_all_tasks(access_scope: scope(ctx.root_member))) == all
    end

    test "point decisions: can?/3, check/3, within?/4 and permitted/3", ctx do
      s = scope(ctx.m)

      assert Access.can?(s, "tasks.read", {:task, ctx.ts.id})
      refute Access.can?(s, "tasks.read", {:task, ctx.tr.id})
      refute Access.can?(s, "tasks.read", {:project, ctx.pr.id})
      assert Access.can?(s, "tasks.read", nil), "nil (anywhere) is not fenced"

      # check/3: the grant-less :ok short-circuit does not skip the fence.
      refute Scope.has_grants?(s)
      assert Access.check(s, "tasks.read", {:task, ctx.ts.id}) == :ok
      assert Access.check(s, "tasks.read", {:task, ctx.tr.id}) == {:error, :denied}

      assert Access.within?(s, "tasks.read", {:task, ctx.ts.id}, true)
      refute Access.within?(s, "tasks.read", {:task, ctx.tr.id}, true)

      allow = Access.permitted(s, "tasks.read", :task).allow
      assert ctx.ts.id in allow
      refute ctx.tr.id in allow

      root = scope(ctx.root_member)
      assert Access.can?(root, "tasks.read", {:task, ctx.tr.id})
      assert Access.check(root, "tasks.read", {:task, ctx.tr.id}) == :ok
    end

    test "an explicit allow on a foreign project does not widen past the fence", ctx do
      {:ok, _} = Grants.grant(%{principal: ctx.m, permission: "tasks.read", resource: ctx.pr})
      s = scope(ctx.m)

      refute Access.can?(s, "tasks.read", {:task, ctx.tr.id})
      refute ctx.tr.id in ids(Tasks.list_all_tasks(access_scope: s))
      refute ctx.tr.id in Access.granted(s, "tasks.read", :task).allow
    end

    test "the /tasks board renders S's task and not R's for M; a root member sees both", ctx do
      {:ok, _view, html} = live(authed(ctx.m), "/tasks")
      assert html =~ ctx.ts.title
      refute html =~ ctx.tr.title

      {:ok, _view, root_html} = live(authed(ctx.root_member), "/tasks")
      assert root_html =~ ctx.ts.title
      assert root_html =~ ctx.tr.title
    end

    test "/tasks/<R task id> is \"Task not found.\" for M, identical to a random id", ctx do
      {:ok, own, _} = live(authed(ctx.m), "/tasks/#{ctx.ts.id}")
      assert assigns(own).selected_task.id == ctx.ts.id

      {:ok, view, _} = live(authed(ctx.m), "/tasks/#{ctx.tr.id}")
      html = render(view)
      assert html =~ "Task not found."
      refute html =~ ctx.tr.title
      assert assigns(view).selected_task == nil

      {:ok, missing, _} = live(authed(ctx.m), "/tasks/#{Ecto.UUID.generate()}")
      assert render(missing) =~ "Task not found."

      {:ok, root_view, _} = live(authed(ctx.root_member), "/tasks/#{ctx.tr.id}")
      assert assigns(root_view).selected_task.id == ctx.tr.id
    end

    test "MCP task_get for an R task from M's runtime is the random-id not-found envelope", ctx do
      rt = runtime!(ctx.m)

      assert {:ok, own} = call(rt, "task_get", %{"task_id" => ctx.ts.id})
      assert (Map.get(own, :id) || Map.get(own, "id")) == ctx.ts.id

      random = Ecto.UUID.generate()
      {:error, fenced} = call(rt, "task_get", %{"task_id" => ctx.tr.id})
      {:error, missing} = call(rt, "task_get", %{"task_id" => random})

      assert %{fenced | error: String.replace(fenced.error, ctx.tr.id, random)} == missing

      # Positive control: a root member's runtime reads the R task.
      assert {:ok, _} = call(runtime!(ctx.root_member), "task_get", %{"task_id" => ctx.tr.id})
    end
  end

  # ── chat ────────────────────────────────────────────────────────────────

  describe "chat" do
    test "list_spaces(scope:) is S's channels plus M's DMs; a root member's equals today's",
         ctx do
      s = scope(ctx.m)
      listed = channels(s)

      assert ctx.cs.id in listed and ctx.cs_unjoined.id in listed
      refute ctx.cr.id in listed

      assert ctx.dm.id in ids(Chat.list_user_conversations(ctx.m.id, scope: s))

      exec = ids(Chat.list_spaces(kind: "execution", include_execution: true, scope: s))
      refute ctx.er.id in exec
      refute ctx.sr.id in ids(Chat.list_spaces(kind: "system", scope: s))

      root = ctx.root_member
      assert channels(scope(root)) == channels(ExternalScope.for_user(root))
      assert ctx.cr.id in channels(scope(root))
    end

    test "search_messages over an R space is empty for M; a root member finds the message", ctx do
      q = "fencepost"
      assert [_ | _] = Chat.search_messages(ctx.cr.id, q, scope: scope(ctx.root_member))
      assert Chat.search_messages(ctx.cr.id, q, scope: scope(ctx.m)) == []

      # M's own DM survives the fence.
      assert [_ | _] = Chat.search_messages(ctx.dm.id, q, scope: scope(ctx.m))
    end

    test "search_messages_in_spaces and last_message_excerpts drop an R space for M", ctx do
      q = "fencepost"
      ids = [ctx.cr.id, ctx.dm.id]

      # Positive control: a root member gets the R channel from both reads.
      root = scope(ctx.root_member)

      assert ctx.cr.id in Enum.map(
               Chat.search_messages_in_spaces(ids, q, scope: root),
               & &1.space_id
             )

      assert Map.has_key?(Chat.last_message_excerpts(ids, scope: root), ctx.cr.id)

      m = scope(ctx.m)
      hits = Chat.search_messages_in_spaces(ids, q, scope: m)
      refute ctx.cr.id in Enum.map(hits, & &1.space_id)
      assert ctx.dm.id in Enum.map(hits, & &1.space_id)

      excerpts = Chat.last_message_excerpts(ids, scope: m)
      refute Map.has_key?(excerpts, ctx.cr.id)
      assert Map.has_key?(excerpts, ctx.dm.id)
    end

    test "M is refused /chat/<R channel> by slug and by id, and no participant row is written",
         ctx do
      before = user_rows(ctx.cr)

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(authed(ctx.m), "/chat/#{ctx.cr.id}")

      # By slug: the slug lookup is scoped to M's active org and misses R's
      # channel. What happens next (ChatLive mints an empty S channel with
      # that slug) is pre-existing and out of scope; what matters is that
      # nothing of R's channel reaches the render.
      html =
        case live(authed(ctx.m), "/chat/#{ctx.cr.slug}") do
          {:ok, view, html} ->
            refute assigns(view).active_space.id == ctx.cr.id
            html <> render(view)

          {:error, _redirect} ->
            ""
        end

      refute html =~ "fencepost root secret"
      refute html =~ ctx.cr.name
      refute html =~ ctx.root_member.name

      assert user_rows(ctx.cr) == before
      refute ctx.m.id in user_rows(ctx.cr)

      # Positive control: a root member who never joined the R channel opens it.
      {:ok, _view, _} = live(authed(member!(ctx.root)), "/chat/#{ctx.cr.id}")
    end

    test "M is refused /chat/<R execution space>", ctx do
      before = user_rows(ctx.er)

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(authed(ctx.m), "/chat/#{ctx.er.id}")

      assert user_rows(ctx.er) == before
    end

    # RECORDED BEHAVIOUR CHANGE, not a requirement this file invents: a
    # sponsor's task pin (`Platform.Tasks.ChatPins`, PR #548) used to let a
    # cross-org bystander open the pinned execution space with no
    # participant row. The fence admits a space by org or participant row
    # only, so a fenced bystander is refused it. Flagged in the stage report.
    test "a task pin alone does not admit M to a foreign org's execution space", ctx do
      {:ok, %{space: space}} =
        Platform.Tasks.ChatPins.pin(ctx.tr.id, %{kind: "user", id: ctx.m.email}, "sponsor@x")

      assert space.id == ctx.er.id

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(authed(ctx.m), "/chat/#{ctx.er.id}")
    end

    test "positive control: M opens an unjoined S channel by URL", ctx do
      refute ctx.m.id in user_rows(ctx.cs_unjoined)
      {:ok, view, _} = live(authed(ctx.m), "/chat/#{ctx.cs_unjoined.id}")
      assert assigns(view).active_space.id == ctx.cs_unjoined.id
    end

    test "the ChatLive rail lists S channels and never R's for M", ctx do
      {:ok, view, _} = live(authed(ctx.m), "/chat/#{ctx.cs.id}")
      rail = ids(assigns(view).channels)

      assert ctx.cs.id in rail
      refute ctx.cr.id in rail

      {:ok, root_view, _} = live(authed(ctx.root_member), "/chat/#{ctx.cr.id}")
      assert ctx.cr.id in ids(assigns(root_view).channels)
    end
  end

  # ── a space chat.read deny on an S channel ──────────────────────────────

  describe "a chat.read deny on an S channel" do
    test "hides it from list_spaces, the rail, search and URL open", ctx do
      target = space!("channel", ctx.s)
      p = join!(target, ctx.m)
      _ = post!(target, p, "fencepost denied room #{ctx.n}")

      # Positive control, before the deny.
      assert target.id in channels(scope(ctx.m))
      assert [_ | _] = Chat.search_messages(target.id, "fencepost", scope: scope(ctx.m))
      {:ok, _, _} = live(authed(ctx.m), "/chat/#{target.id}")

      {:ok, _} = Grants.deny(%{principal: ctx.m, permission: "chat.read", resource: target})
      s = scope(ctx.m)

      refute target.id in channels(s)
      assert Chat.search_messages(target.id, "fencepost", scope: s) == []

      {:ok, view, _} = live(authed(ctx.m), "/chat/#{ctx.cs.id}")
      refute target.id in ids(assigns(view).channels)

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(authed(ctx.m), "/chat/#{target.id}")
    end
  end

  # ── unfenced rows are unchanged ─────────────────────────────────────────

  describe "unfenced rows read exactly what they read today" do
    test "a guest", ctx do
      g = guest!(ctx.s)
      _ = join!(ctx.cs, g)

      assert channels(scope(g)) == channels(ExternalScope.for_user(g))
      assert ids(Tasks.list_all_tasks(access_scope: scope(g))) == MapSet.new()
    end

    test "a zero-membership user", ctx do
      z = user!("zero")

      assert channels(scope(z)) == channels(ExternalScope.for_user(z))
      assert ids(Tasks.list_all_tasks(access_scope: scope(z))) == ids(Tasks.list_all_tasks())
      assert ctx.cr.id in channels(scope(z))
    end
  end
end
