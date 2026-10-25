defmodule Platform.Access.GlobexTargetAcceptanceTest do
  @moduledoc """
  The combined target state of task 01a14721 (stage 3): the ORG FENCE
  (stage 1) plus MODULE LOCKS (stage 2) and channel denies, end to end, for
  the shape the post-deploy data steps build for Globex.

  The world: root org R (a project with a task titled LEGACY-SECRET, two
  channels, an execution space) and sub-org S (project P with two tasks,
  seven channels). U is an INTERNAL member of S only, denied `chat.read` on
  five of S's channels, and locked out of every lockable module except
  chat, tasks and meetings. V is an unlocked, undenied member of S (U's
  control twin) and RM a root member.

  Every absence is preceded on the same fixture by its POSITIVE CONTROL:
  the row exists and an unfenced or unlocked reader sees it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, RuntimeProfiles, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.{ExternalScope, Participant, Space}
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.IconRail

  @kept ~w(chat tasks meetings)
  @profile ["task", "files" | AgentRuntime.default_tool_profile()]

  # ── fixtures ────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp member!(org, tag) do
    n = uniq()

    u =
      Repo.insert!(%User{
        email: "globex-target-#{tag}-#{n}@example.com",
        name: "Globex target #{tag} #{n}",
        oidc_sub: "globex-target-#{tag}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp project!(org, name) do
    {:ok, p} = Tasks.create_project(%{name: "#{name}-#{uniq()}", org_id: org})
    p
  end

  defp task!(project, title),
    do: Repo.insert!(%Task{project_id: project.id, title: title, status: "backlog"})

  defp space!(kind, org, metadata \\ %{}) do
    n = uniq()

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "globex-#{kind}-#{n}",
      slug: "globex-#{kind}-#{n}",
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

  defp runtime!(owner) do
    rt =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "globex-target-rt-#{uniq()}",
        owner_user_id: owner.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} =
      RuntimeProfiles.create_for_runtime(
        rt,
        @profile,
        RuntimeProfiles.translated_permissions(@profile)
      )

    rt
  end

  defp call(rt, name, args), do: ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id})

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))
  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)
  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()
  defp rail(scope), do: [scope: scope] |> IconRail.destinations() |> Enum.map(& &1.key)
  defp channels(scope), do: ids(Chat.list_spaces(kind: "channel", scope: scope))
  defp board(scope), do: ids(Tasks.list_all_tasks(access_scope: scope))

  # Everything the target state could change for a reader, in one value.
  defp surfaces(user) do
    s = scope(user)
    %{rail: rail(s), channels: channels(s), board: board(s)}
  end

  setup do
    r = acme_org_id()
    s = tenant_org_id("globex_target_#{uniq()}")
    n = uniq()

    u = member!(s, "u")
    v = member!(s, "v")
    rm = member!(r, "rm")

    pr = project!(r, "globex-pr")
    secret = task!(pr, "LEGACY-SECRET #{n}")
    r_channels = for _ <- 1..2, do: space!("channel", r)
    er = space!("execution", r, %{"task_id" => secret.id})

    p = project!(s, "globex-p")
    p_tasks = for i <- 1..2, do: task!(p, "Globex P task #{i} #{n}")
    s_channels = for _ <- 1..7, do: space!("channel", s)
    {denied, open} = Enum.split(s_channels, 5)

    dm = space!("dm", nil)
    _ = join!(dm, u)
    _ = join!(dm, v)

    %{
      r: r,
      s: s,
      u: u,
      v: v,
      rm: rm,
      pr: pr,
      secret: secret,
      r_channels: r_channels,
      er: er,
      p: p,
      p_tasks: p_tasks,
      denied: denied,
      open: open,
      dm: dm
    }
  end

  # Build U's target state: five channel denies and every lock but @kept.
  defp apply_target!(ctx) do
    for c <- ctx.denied do
      {:ok, _} = Grants.deny(%{principal: ctx.u, permission: "chat.read", resource: c})
    end

    for module <- Grant.lockable_modules() -- @kept do
      {:ok, _} =
        Grants.deny(%{
          principal: {:user, ctx.u.id},
          permission: module,
          resource: {:module, ctx.s}
        })
    end
  end

  test "U sees exactly the target state; V and a root member are unchanged", ctx do
    # ── positive controls, before the target state ──
    rm_before = surfaces(ctx.rm)
    v_before = surfaces(ctx.v)
    u_before = surfaces(ctx.u)

    assert u_before == v_before
    assert Enum.all?([:files, :context, :inbox, :agents], &(&1 in u_before.rail))
    assert MapSet.subset?(ids(ctx.denied), u_before.channels)
    assert ctx.secret.id in rm_before.board

    rt = runtime!(ctx.u)
    control_rt = runtime!(ctx.v)
    assert {:ok, _} = call(rt, "file_list", %{"project_id" => ctx.p.id})

    apply_target!(ctx)
    u_scope = scope(ctx.u)

    # ── U: fenced to S, five channels denied, locked to chat/tasks/meetings ──
    # (Voice rides the meetings module, task 01a1557a-eab7 stage 2.)
    assert Access.org_fence(u_scope) == [ctx.s]
    assert Enum.sort(rail(u_scope)) == [:chat, :meetings, :tasks, :voice]
    assert channels(u_scope) == ids(ctx.open)
    assert ctx.dm.id in ids(Chat.list_user_conversations(ctx.u.id, scope: u_scope))
    assert board(u_scope) == ids(ctx.p_tasks)

    {:ok, _view, board_html} = live(authed(ctx.u), "/tasks")
    refute board_html =~ "LEGACY-SECRET"
    for t <- ctx.p_tasks, do: assert(board_html =~ t.title)

    {:ok, detail, _} = live(authed(ctx.u), "/tasks/#{ctx.secret.id}")
    detail_html = render(detail)
    assert detail_html =~ "Task not found."
    refute detail_html =~ "LEGACY-SECRET"

    for {path, key} <- [
          {"/control", "agents"},
          {"/files", "files"},
          {"/org_memory", "context"},
          {"/inbox", "inbox"}
        ] do
      assert {:error, {:redirect, %{to: to}}} = live(authed(ctx.u), path)
      assert to == "/access-denied?module=#{key}", path
    end

    for c <- ctx.denied ++ ctx.r_channels ++ [ctx.er] do
      before = Chat.list_participants(c.id) |> Enum.map(& &1.participant_id) |> Enum.sort()
      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(authed(ctx.u), "/chat/#{c.id}")
      after_ = Chat.list_participants(c.id) |> Enum.map(& &1.participant_id) |> Enum.sort()
      assert after_ == before
    end

    # MCP from U's runtime: task_get on the R task is the random-id envelope,
    # file_list is the unknown-project envelope. V's twin runtime reads both
    # kinds of row (control).
    random = Ecto.UUID.generate()
    {:error, fenced} = call(rt, "task_get", %{"task_id" => ctx.secret.id})
    {:error, missing} = call(rt, "task_get", %{"task_id" => random})
    assert %{fenced | error: String.replace(fenced.error, ctx.secret.id, random)} == missing

    assert {:ok, _} = call(control_rt, "task_get", %{"task_id" => hd(ctx.p_tasks).id})
    assert {:ok, _} = call(control_rt, "file_list", %{"project_id" => ctx.p.id})
    assert {:error, refused} = call(rt, "file_list", %{"project_id" => ctx.p.id})
    assert {:error, unknown} = call(rt, "file_list", %{"project_id" => Ecto.UUID.generate()})
    assert refused == unknown

    # ── nobody else moved ──
    assert surfaces(ctx.v) == v_before
    assert surfaces(ctx.rm) == rm_before

    # A root member equals the unlocked, unscoped baseline.
    rm_scope = scope(ctx.rm)
    assert rm_before.rail == Enum.map(IconRail.destinations(root_user: false), & &1.key)
    assert rm_before.board == ids(Tasks.list_all_tasks())
    assert rm_before.channels == channels(ExternalScope.for_user(ctx.rm))
    assert Access.org_fence(rm_scope) == :unfenced
  end

  # Stage 4: the SLUG path. A fenced member who names a channel by slug must
  # not have one minted for them on the miss (the bug: R's channel slug missed
  # the org-scoped lookup and `bootstrap_space` created a new S channel with U
  # as admin, which the fence then admitted). A foreign slug, a never-existing
  # slug and R's execution-space slug must be refused identically and write no
  # `chat_spaces` row and no `chat_participants` row.
  defp space_count, do: Repo.aggregate(Space, :count)
  defp participant_count, do: Repo.aggregate(Participant, :count)

  test "U is refused by SLUG on a foreign, a never-existing and an execution slug, and nothing is written",
       ctx do
    apply_target!(ctx)
    assert Access.org_fence(scope(ctx.u)) == [ctx.s]

    slugs = [hd(ctx.r_channels).slug, "globex-never-#{uniq()}", ctx.er.slug]

    outcomes =
      for slug <- slugs do
        spaces_before = space_count()
        participants_before = participant_count()

        outcome = live(authed(ctx.u), "/chat/#{slug}")

        assert space_count() == spaces_before, slug
        assert participant_count() == participants_before, slug
        refute Repo.get_by(Space, slug: slug, org_id: ctx.s), slug

        outcome
      end

    assert [{:error, {:live_redirect, %{to: "/chat"}}} | _] = outcomes
    assert Enum.uniq(outcomes) |> length() == 1
  end

  test "positive control: an unfenced root member opening a never-existing slug still bootstraps it",
       ctx do
    assert Access.org_fence(scope(ctx.rm)) == :unfenced
    slug = "globex-never-#{uniq()}"
    spaces_before = space_count()
    participants_before = participant_count()

    assert {:ok, _view, _html} = live(authed(ctx.rm), "/chat/#{slug}")

    assert space_count() == spaces_before + 1
    assert participant_count() == participants_before + 1
    minted = Repo.get_by!(Space, slug: slug, org_id: ctx.r)
    assert minted.created_by == ctx.rm.id
    assert ctx.rm.id in Enum.map(Chat.list_participants(minted.id), & &1.participant_id)
  end
end
