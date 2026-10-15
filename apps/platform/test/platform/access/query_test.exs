defmodule Platform.Access.QueryTest do
  @moduledoc """
  Task 01a1386d-e528 stage 2: `Platform.Access.Query.where_permitted/5`
  returns EXACTLY the id set `Platform.Access.can?/3` permits, for every
  resource type, over one seeded fixture and several scopes
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`: "Member
  3's set-equality test is what keeps the three from drifting").

  The comparison is over the WHOLE table on both sides, so a query that is
  too wide is caught as surely as one that is too narrow. Each scope is also
  checked to make its set differ from the unscoped table or from the empty
  set, so a vacuous pass (everything or nothing on both sides) is visible.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Query, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat.{Canvas, Space}
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath}
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachment, Project, Stack, Task}
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @schemas %{
    project: Project,
    task: Task,
    stack: Stack,
    space: Space,
    canvas: Canvas
  }

  setup do
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    _root = acme_org_id()
    org = tenant_org_id("sxi")
    author = member!(org)

    p = project!(org)
    q = project!(org)
    [tp1, tp2] = [task!(p), task!(p)]
    tq = task!(q)
    sp = exec_space!(tp1, org)
    sq = exec_space!(tq, org)
    channel = space!("channel", org)
    group = space!("group", org)
    kp = canvas!(sp, author)
    kp2 = canvas!(sp, author)
    kq = canvas!(sq, author)
    kc = canvas!(channel, author)
    kg = canvas!(group, author)
    attach!(tp2, kc)
    stack_p = stack!(p)
    stack_q = stack!(q)

    for key <- ~w(org/page/eng/x.md org/page/eng/secret/plan.md org/page/ops/y.md org/page/top.md) do
      {:ok, _} = Wiki.upsert_page(key, %{content: key})
    end

    %{
      org: org,
      p: p,
      q: q,
      tp1: tp1,
      tq: tq,
      sp: sp,
      sq: sq,
      channel: channel,
      group: group,
      kp: kp,
      kp2: kp2,
      kq: kq,
      kc: kc,
      kg: kg,
      stack_p: stack_p,
      stack_q: stack_q
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "q-#{tag}-#{n}@example.com",
      name: "Q #{tag} #{n}",
      oidc_sub: "q-#{tag}-#{n}"
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
      Tasks.create_project(%{name: "q-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp task!(project), do: Repo.insert!(%Task{project_id: project.id, title: "q task"})

  defp stack!(project) do
    seq = System.unique_integer([:positive])

    %Stack{}
    |> Stack.changeset(%{
      project_id: project.id,
      slug: "q-stack-#{seq}",
      name: "Q Stack",
      base_branch: "main",
      rollup_branch: "stack/q-#{seq}"
    })
    |> Repo.insert!()
  end

  defp space!(kind, org, metadata \\ %{}) do
    n = System.unique_integer([:positive])

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "q-#{kind}-#{n}",
      slug: "q-#{kind}-#{n}",
      org_id: org,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp exec_space!(task, org), do: space!("execution", org, %{"task_id" => task.id})

  defp canvas!(space, author),
    do: Repo.insert!(%Canvas{space_id: space.id, created_by: author.id, title: "q canvas"})

  defp attach!(task, canvas),
    do: Repo.insert!(%CanvasAttachment{task_id: task.id, canvas_id: canvas.id})

  defp ok!({:ok, value}), do: value

  # ── the comparison ─────────────────────────────────────────────────────

  defp via_query(scope, permission, type) do
    from(r in Map.fetch!(@schemas, type), select: r.id)
    |> Query.where_permitted(scope, permission, type, %{id: :id})
    |> Repo.all()
    |> Enum.sort()
  end

  defp via_can(scope, permission, type) do
    from(r in Map.fetch!(@schemas, type), select: r.id)
    |> Repo.all()
    |> Enum.filter(&Access.can?(scope, permission, {type, &1}))
    |> Enum.sort()
  end

  defp all_ids(type),
    do: from(r in Map.fetch!(@schemas, type), select: r.id) |> Repo.all() |> Enum.sort()

  defp assert_same(scope, permission, type) do
    by_query = via_query(scope, permission, type)
    by_can = via_can(scope, permission, type)

    assert by_query == by_can,
           "#{permission} over #{type}: query-only #{inspect(by_query -- by_can)}, " <>
             "can?-only #{inspect(by_can -- by_query)}"

    by_query
  end

  defp assert_page_sets(scope, mapping, at \\ nil) do
    by_query =
      from(w in WikiPage, select: w.file_key)
      |> Query.where_permitted(scope, "memory.read", :memory_page, mapping)
      |> Repo.all()
      |> Enum.sort()

    by_can =
      from(w in WikiPage, select: w.file_key)
      |> Repo.all()
      |> Enum.filter(&Access.can?(scope, "memory.read", {:memory, &1, at}))
      |> Enum.sort()

    assert by_query == by_can
    by_query
  end

  # ── cases ───────────────────────────────────────────────────────────────

  test "a guest allowed on project P: every type agrees, and only P's subtree is in", ctx do
    g = guest!(ctx.org)

    for perm <- ~w(tasks.read chat.read canvas.read) do
      ok!(Grants.grant(%{principal: g, permission: perm, resource: ctx.p}))
    end

    s = scope(g)

    assert assert_same(s, "tasks.read", :project) == [ctx.p.id]
    assert ctx.tq.id not in assert_same(s, "tasks.read", :task)
    assert ctx.tp1.id in assert_same(s, "tasks.read", :task)
    assert assert_same(s, "tasks.read", :stack) == [ctx.stack_p.id]

    spaces = assert_same(s, "chat.read", :space)
    assert ctx.sp.id in spaces
    refute ctx.sq.id in spaces

    canvases = assert_same(s, "canvas.read", :canvas)
    assert Enum.sort([ctx.kp.id, ctx.kp2.id, ctx.kc.id]) == canvases
  end

  test "a member denied on project Q: :all minus Q's subtree, every type agrees", ctx do
    m = member!(ctx.org)

    for perm <- ~w(tasks.read chat.read canvas.read) do
      ok!(Grants.deny(%{principal: m, permission: perm, resource: ctx.q}))
    end

    s = scope(m)

    for {type, perm} <- [
          project: "tasks.read",
          task: "tasks.read",
          stack: "tasks.read",
          space: "chat.read",
          canvas: "canvas.read"
        ] do
      ids = assert_same(s, perm, type)
      assert ids != [] and ids != all_ids(type) or type == :space, "#{type} set is vacuous"
    end

    refute ctx.q.id in via_query(s, "tasks.read", :project)
    refute ctx.sq.id in via_query(s, "chat.read", :space)
    refute ctx.kq.id in via_query(s, "canvas.read", :canvas)
    assert ctx.kp.id in via_query(s, "canvas.read", :canvas)
    assert ctx.channel.id in via_query(s, "chat.read", :space)
    refute ctx.group.id in via_query(s, "chat.read", :space)
  end

  test "a canvas deny under a project allow, a role grant, and a space allow", ctx do
    g = guest!(ctx.org)
    other = guest!(ctx.org)
    ok!(Grants.grant(%{principal: {:role, "guest"}, permission: "canvas.read", resource: ctx.p}))
    ok!(Grants.deny(%{principal: g, permission: "canvas.read", resource: {:canvas, ctx.kp.id}}))
    ok!(Grants.grant(%{principal: g, permission: "chat.read", resource: {:space, ctx.group.id}}))

    canvases = assert_same(scope(g), "canvas.read", :canvas)
    refute ctx.kp.id in canvases
    assert ctx.kp2.id in canvases

    assert ctx.kp.id in assert_same(scope(other), "canvas.read", :canvas)

    spaces = assert_same(scope(g), "chat.read", :space)
    assert ctx.group.id in spaces
  end

  test "no grants: the query keeps member 2's role-rule rows", ctx do
    for user <- [member!(ctx.org), guest!(ctx.org)], s = scope(user) do
      assert s.grants == []

      for {type, perm} <- [
            project: "tasks.read",
            task: "tasks.read",
            stack: "tasks.read",
            space: "chat.read",
            canvas: "canvas.read"
          ],
          do: assert_same(s, perm, type)
    end
  end

  test "memory pages: allow on a prefix, deny on a page, current and historical", ctx do
    g = guest!(ctx.org)
    m = member!(ctx.org)

    ok!(Grants.grant(%{principal: g, permission: "memory.read", resource: {:memory, "org/page/eng/"}}))

    for u <- [g, m] do
      ok!(
        Grants.deny(%{
          principal: u,
          permission: "memory.read",
          resource: {:memory, "org/page/eng/secret/plan.md"}
        })
      )
    end

    before = DateTime.utc_now()
    Process.sleep(2)

    assert assert_page_sets(scope(g), %{path: :file_key}) == ["org/page/eng/x.md"]

    assert assert_page_sets(scope(g), %{path: :file_key, workspace_id: :workspace_id}) ==
             ["org/page/eng/x.md"]

    member_pages = assert_page_sets(scope(m), %{path: :file_key})
    assert "org/page/top.md" in member_pages
    refute "org/page/eng/secret/plan.md" in member_pages

    assert {:ok, _} = Wiki.rename_prefix("org/page/eng/", "org/page/engineering/")

    assert assert_page_sets(scope(g), %{path: :file_key}) == ["org/page/engineering/x.md"]
    refute "org/page/engineering/secret/plan.md" in assert_page_sets(scope(m), %{path: :file_key})

    # A page recreated at the OLD location: the allow no longer covers it
    # now, but did at `before` (historical mode reads the interval).
    {:ok, _} = Wiki.upsert_page("org/page/eng/x.md", %{content: "recreated"})
    assert assert_page_sets(scope(g), %{path: :file_key}) == ["org/page/engineering/x.md"]

    assert assert_page_sets(scope(g), %{path: :file_key, at: before}, before) ==
             ["org/page/eng/x.md"]
  end

  test "Access.permitted/3 for :system is unrestricted and unknown types raise", _ctx do
    assert %Access.Permitted{allow: :all, deny: []} =
             Access.permitted(Scope.system(), "tasks.read", :task)

    assert_raise ArgumentError, fn ->
      Access.permitted(Scope.for_user(nil), "tasks.read", :nope)
    end
  end
end
