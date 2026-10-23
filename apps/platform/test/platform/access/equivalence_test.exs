defmodule Platform.Access.EquivalenceTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 4: the before/after equivalence table for RBAC v2
  member 2, per
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Today's state mapped onto built-in roles (no behaviour change)`.

  One row per actor class. For each row every quantity is computed TWICE:
  once through today's code path, and once from `%Platform.Access.Scope{}`
  alone. Each test is one quantity over every row it applies to. It collects
  every row whose two answers differ and fails with the whole list, so a
  mutation shows exactly which rows and quantities it moved.

    1. visible spaces;
    2. visible tasks (and the `/tasks` HTTP outcome);
    3. visible projects and org visibility;
    4. admin routes, every route of the `:admin` and `:admin_sign_in`
       live_sessions read from `Phoenix.Router.routes/1`, each sent through
       the full endpoint;
    5. MCP `tools/list` per runtime: names, the HTTP body hash, and the
       callable set the Scope's grants imply over the whole catalogue;
    6. `Tenancy.org_admin?/2` for every (actor, org) pair;
    7. the rail, NARROWED: today's rail is ungated and rail gating is stack
       position 4, so the claim is (a) the Scope's rail is a subset of the
       rendered rail and (b) every rendered tile the Scope does not declare
       is refused through the endpoint.

  Rows added by the stack owner's decisions after the first red run (task
  01a1386d-cb5c stage 4): agent runtimes read chat through their roster, a
  zero-membership user gets the no-membership baseline, and a mixed user
  with an internal admin row stays an org admin of that org.

  Quantity 8 (today's in-memory org fences, which the Scope does not replace)
  is `Platform.Access.OrgFencesTest`, a separate file so it can run unchanged
  on the base commit as well as on this branch.

  "Through `%Scope{}`" never calls today's predicate. Where the Scope's set
  form is only a lower bound (`implicit_or_participant`), the Scope side asks
  `Scope.can?/3` per resource, never `permitted_ids/2` alone.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Registry, Scope}
  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.{ToolAuthorization, ToolSurface}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.IconRail

  @router PlatformWeb.Router
  @admin_sessions [:admin, :admin_sign_in]

  # ── The world ───────────────────────────────────────────────────────────

  setup do
    w = World.external_world()
    root = acme_org_id()
    org_a = w.org_a.id
    org_b = w.org_b.id
    foreign = tenant_org_id("vandelay_ind")

    root_admin = human!(fn u -> member!(u, root, "admin") end)
    root_member = human!(fn u -> member!(u, root, "member") end)
    sub_admin = human!(fn u -> member!(u, org_a, "admin") end)
    ext_admin = human!(fn u -> external!(u, org_a, "admin") end)
    ext_root = human!(fn u -> external!(u, root, "member") end)
    ext_root_admin = human!(fn u -> external!(u, root, "admin") end)

    mixed =
      human!(fn u ->
        external!(u, org_a, "member")
        member!(u, org_b, "member")
      end)

    zero = human!(fn _u -> :ok end)

    # Mixed with an INTERNAL admin row: org admin of B today
    # (`Tenancy.org_admin?/2` is per membership).
    mixed_admin =
      human!(fn u ->
        external!(u, org_a, "member")
        member!(u, org_b, "admin")
      end)

    # Spaces beyond the world's channels a (ext + int) and b (other): a DM
    # for ext with the allowlisted m, a group for mixed, an execution space,
    # and a channel in org B that mixed and ext_root participate in.
    dm_ext = space!("dm", org_a, [w.ext, w.m])
    group = space!("group", org_b, [mixed, root_member])
    exec = space!("execution", org_b, [sub_admin])
    c = space!("channel", org_b, [mixed, ext_root, ext_admin])
    dm_admin = space!("dm", root, [root_admin, sub_admin])
    # A channel in each external row's OWN org, so each guest has a chat page
    # the ExternalUserScope plug admits (its slug lookup is org-scoped).
    chan_a = space!("channel", org_a, [ext_admin, mixed_admin])
    chan_root = space!("channel", root, [ext_root, ext_root_admin])
    # A mixed user resolves a slug against `Tenancy.load_membership/1`'s pick,
    # the first row of an UNORDERED membership preload, so a page in only one
    # of their orgs loads or 403s by row order. One channel per org keeps the
    # rail measurement independent of that pick.
    _ = World.add_user!(c.id, mixed_admin.id)
    _ = World.add_user!(w.a.id, mixed.id)

    # Projects and tasks in four orgs, including a foreign tenant no row is a
    # member of.
    projects =
      for org <- [root, org_a, org_b, foreign] do
        {:ok, p} =
          Tasks.create_project(%{
            name: "Equivalence #{System.unique_integer([:positive])}",
            repo_url: "git@github.com:test/equivalence.git",
            org_id: org
          })

        {:ok, _} =
          Tasks.create_task(%{
            project_id: p.id,
            title: "Equivalence task #{p.name}",
            status: "backlog",
            priority: "medium"
          })

        p
      end

    # Runtimes: default bundles (internal owner), narrowed bundles (internal
    # owner), default bundles owned by an external user, and the whole
    # catalogue (the wire-format oracle for quantity 5).
    rt_default = runtime!(root_member, AgentRuntime.default_tool_profile(), [w.a])
    rt_narrow = runtime!(w.int, ["task", "messaging"], [w.b])
    rt_ext = runtime!(w.ext, AgentRuntime.default_tool_profile(), [w.a, dm_ext])
    rt_full = runtime!(root_member, ToolSurface.all_bundles(), [])

    humans = [
      root_admin: root_admin,
      root_member: root_member,
      sub_admin: sub_admin,
      sub_member: w.int,
      ext_member: w.ext,
      ext_admin: ext_admin,
      ext_root_member: ext_root,
      ext_root_admin: ext_root_admin,
      mixed: mixed,
      mixed_internal_admin: mixed_admin,
      zero_membership: zero
    ]

    %{
      w: w,
      orgs: [root, org_a, org_b, foreign],
      humans: humans,
      runtimes: [default: rt_default, narrowed: rt_narrow, external_owned: rt_ext],
      rt_full: rt_full,
      spaces: [w.a, w.b, dm_ext, group, exec, c, dm_admin, chan_a, chan_root],
      projects: projects
    }
  end

  # ── 1. Visible spaces ───────────────────────────────────────────────────

  describe "quantity 1: visible spaces" do
    test "every human row lists the same spaces through ExternalScope and through Scope", ctx do
      # Named deliberate exception: sub-org-only internal members are fenced to their orgs, ticket 01a14721; prod had 0 such users on 2026-10-16.
      fenced_rows =
        for {row, user} <- ctx.humans,
            Platform.Access.org_fence(Scope.for_user(loaded(user))) != :unfenced,
            do: row

      assert fenced_rows == [:sub_admin, :sub_member]

      diffs =
        for {row, user} <- ctx.humans,
            today = listed_spaces(user, ExternalScope.for_user(user)),
            today = if(row in fenced_rows, do: in_fence_or_participant(today, user), else: today),
            via_scope = listed_spaces(user, Scope.for_user(loaded(user))),
            today != via_scope,
            do: {row, today: today, scope: via_scope}

      assert diffs == []
    end

    test "every listed space is one Scope.can?/3 admits for chat.read", ctx do
      diffs =
        for {row, user} <- ctx.humans,
            scope = Scope.for_user(loaded(user)),
            space <- spaces_of(listed_spaces(user, ExternalScope.for_user(user)), ctx),
            not Scope.can?(scope, "chat.read", space),
            do: {row, space.kind, space.id}

      assert diffs == []
    end

    test "a guest row's Scope admits exactly the spaces ExternalScope makes visible", ctx do
      diffs =
        for {row, user} <- ctx.humans,
            Tenancy.external_user?(user),
            scope = Scope.for_user(loaded(user)),
            space <- ctx.spaces,
            # Booleans travel in a tuple: a bare `false` binding in a
            # comprehension is a filter and would drop the row.
            {today} = {ExternalScope.visible_space_id?(space.id, ExternalScope.for_user(user))},
            Scope.can?(scope, "chat.read", space) != today,
            do: {row, space.kind, space.id, today: today}

      assert diffs == []
    end

    test "every runtime row: the agent's roster spaces vs the spaces its Scope admits", ctx do
      diffs =
        for {row, rt} <- ctx.runtimes,
            today = rt.agent_id |> Chat.list_spaces_for_agent() |> ids(),
            scope = Scope.for_runtime(rt),
            admitted = for(s <- ctx.spaces, Scope.can?(scope, "chat.read", s), do: s.id),
            via_scope = {Enum.sort(admitted), Scope.permitted_ids(scope, "chat.read")},
            {today, today} != via_scope,
            do: {row, today: today, scope: via_scope}

      assert Enum.all?(ctx.runtimes, fn {_, rt} ->
               Chat.list_spaces_for_agent(rt.agent_id) != []
             end)

      assert diffs == []
    end

    # MEASURED, not an equivalence: no code path passes a runtime Scope to a
    # Chat read today, so there is no "today" to compare with. Pinned so the
    # member that first does (resource scoping or agent capping) meets it.
    # `ExternalScope.from_scope/1` matches any actor carrying a binary `:id`,
    # and an `%AgentRuntime{}` carries one: a guest-marked runtime Scope is
    # filtered to `chat_participants` rows of `participant_type: "user"` whose
    # id is the RUNTIME's id, which is none. It does not pass through.
    test "a runtime Scope through the ExternalScope bridge (pinned, no today path)", ctx do
      system = Chat.list_spaces(kind: "channel", scope: ExternalScope.for_user(nil)) |> ids()

      # Named deliberate exception: sub-org-only internal members are fenced to their orgs, ticket 01a14721; prod had 0 such users on 2026-10-16.
      # Runtimes owned by fenced users inherit the fence (owner_cap).
      fenced_rows =
        for row <- [:default, :narrowed],
            owner = Accounts.get_user(ctx.runtimes[row].owner_user_id),
            Platform.Access.org_fence(Scope.for_user(owner)) != :unfenced,
            do: row

      assert fenced_rows == [:narrowed]

      for row <- [:default, :narrowed] do
        rt = ctx.runtimes[row]
        scope = Scope.for_runtime(rt)
        refute Scope.guest?(scope)

        expected =
          if row in fenced_rows,
            do: in_fence_or_participant(system, Accounts.get_user(rt.owner_user_id)),
            else: system

        assert Chat.list_spaces(kind: "channel", scope: scope) |> ids() == expected
      end

      rt = ctx.runtimes[:external_owned]
      scope = Scope.for_runtime(rt)
      assert Scope.guest?(scope)
      assert ExternalScope.from_scope(scope) == %ExternalScope{user_id: rt.id, external?: true}
      assert Chat.list_spaces(kind: "channel", scope: scope) == []
    end
  end

  # ── 2. Visible tasks ────────────────────────────────────────────────────

  describe "quantity 2: visible tasks" do
    test "the /tasks HTTP outcome and the board's task set, today vs Scope", ctx do
      all_tasks = Tasks.list_all_tasks()

      diffs =
        for {row, user} <- ctx.humans,
            scope = Scope.for_user(loaded(user)),
            status = authed(user) |> get("/tasks") |> Map.fetch!(:status),
            today_tasks = if(status == 200, do: ids(all_tasks), else: []),
            scope_status = predict_board(scope),
            scope_tasks =
              all_tasks |> Enum.filter(&Scope.can?(scope, "tasks.read", &1.id)) |> ids(),
            {status, today_tasks} != {scope_status, scope_tasks},
            do:
              {row,
               today: {status, length(today_tasks)}, scope: {scope_status, length(scope_tasks)}}

      assert length(all_tasks) >= 4
      assert diffs == []
    end
  end

  # ── 3. Visible projects / org visibility ────────────────────────────────

  describe "quantity 3: projects and org visibility" do
    @tag quantity: 3
    test "list_projects_for_user/2 and visibility/1 vs Scope's orgs.read", ctx do
      all_projects = Repo.all(Tasks.Project)

      diffs =
        for {row, user} <- ctx.humans,
            scope = Scope.for_user(loaded(user)),
            today = {visibility(user), Tasks.list_projects_for_user(user) |> ids()},
            via_scope = {scope_visibility(scope), scope_projects(scope, all_projects)},
            today != via_scope,
            do: {row, today: today, scope: via_scope}

      assert diffs == []
    end
  end

  # ── 4. Admin routes ─────────────────────────────────────────────────────

  describe "quantity 4: admin routes" do
    test "every :admin / :admin_sign_in route, through the full endpoint, vs Scope", ctx do
      routes = admin_routes()
      paths = Enum.map(routes, &elem(&1, 1))
      assert "/admin" in paths and "/admin/sign-in-users" in paths, inspect(routes)

      rows = Enum.map(ctx.humans, fn {row, user} -> {row, user} end) ++ [meeting_invitee: nil]

      diffs =
        for {row, user} <- rows,
            scope =
              if(user, do: Scope.for_user(loaded(user)), else: Scope.for_meeting_invitee(nil)),
            {session, path} <- routes,
            today = request_outcome(user, path),
            via_scope = predict_admin(scope, session, user),
            today != via_scope,
            do: {row, path, today: today, scope: via_scope}

      assert diffs == []
    end
  end

  # ── 5. MCP tools/list ───────────────────────────────────────────────────

  describe "quantity 5: MCP tools/list per runtime" do
    test "ToolAuthorization names, HTTP names and HTTP body hash vs Scope.tool_names/1", ctx do
      catalogue = wire_catalogue(ctx.rt_full)

      diffs =
        for {row, rt} <- ctx.runtimes,
            {names_http, body} = tools_list(rt),
            scope_names = Scope.tool_names(Scope.for_runtime(rt)),
            today = %{
              authorization: Enum.sort(ToolAuthorization.tool_names(rt)),
              http: Enum.sort(names_http),
              body_hash: canonical_hash(body)
            },
            via_scope = %{
              authorization: Enum.sort(scope_names),
              http: Enum.sort(scope_names),
              body_hash: canonical_hash(scope_body(body, scope_names, catalogue))
            },
            today != via_scope,
            do: {row, today: today, scope: via_scope}

      assert diffs == []
    end

    test "the callable set the Scope's grants imply over the whole catalogue", ctx do
      diffs =
        for {row, rt} <- ctx.runtimes,
            scope = Scope.for_runtime(rt),
            today = rt |> ToolAuthorization.tool_names() |> Enum.sort(),
            via_scope = granted_tools(scope),
            today != via_scope,
            do: {row, missing: today -- via_scope, extra: via_scope -- today}

      assert diffs == []
    end
  end

  # ── 6. Org admin ────────────────────────────────────────────────────────

  describe "quantity 6: org_admin?/2" do
    test "every (actor, org) pair", ctx do
      diffs =
        for {row, user} <- ctx.humans,
            scope = Scope.for_user(loaded(user)),
            org <- ctx.orgs,
            {today, via_scope} = {Tenancy.org_admin?(user, org), scope_org_admin?(scope, org)},
            today != via_scope,
            do: {row, org, today: today, scope: via_scope}

      assert diffs == []
    end
  end

  # ── 7. Rail ─────────────────────────────────────────────────────────────

  describe "quantity 7: rail" do
    # Today's rail is ungated: it renders tiles an actor cannot open. Rail
    # gating is stack position 4, so the Scope does not reproduce today's
    # tiles. The claim is narrowed to two checkable halves: (a) every tile the
    # Scope declares is on today's rendered rail, and (b) every tile on
    # today's rail that the Scope does not declare opens to a refusal for
    # that actor, through the full endpoint.
    test "(a) the Scope's rail is a subset of today's rendered rail", ctx do
      diffs =
        for {row, user} <- ctx.humans,
            today = rendered_rail(user, ctx),
            via_scope = scope_rail(user),
            via_scope -- today != [],
            do: {row, not_rendered_today: via_scope -- today}

      assert diffs == []
    end

    test "(b) every tile today renders but the Scope does not declare is refused", ctx do
      paths = Map.new(IconRail.destinations(root_user: true), &{&1.key, &1.path})

      diffs =
        for {row, user} <- ctx.humans,
            key <- rendered_rail(user, ctx) -- scope_rail(user),
            outcome = request_outcome(user, Map.fetch!(paths, key)),
            outcome not in [:forbidden, :denied_admin, {:redirect, "/"}, :login],
            do: {row, key, Map.fetch!(paths, key), outcome}

      assert diffs == []
    end

    # The rail rule is "carries", not "resolves non-empty": the zero-membership
    # user carries `files.read` through a `membership_org` rule that resolves
    # to no org. Measured, not assumed: today's /files page lists no project
    # for them, and does list projects for a positive control.
    test "zero-membership: /files is declared and today's page lists no project", ctx do
      zero = ctx.humans[:zero_membership]
      scope = Scope.for_user(loaded(zero))

      assert :files in Scope.declared_rail(scope)
      refute Scope.can?(scope, "files.read")
      assert Scope.permitted_ids(scope, "files.read") == []
      assert files_page_projects(zero) == []
      assert files_page_projects(ctx.humans[:root_member]) != []
    end
  end

  # ── Today's side ────────────────────────────────────────────────────────

  defp listed_spaces(user, scope) do
    (Chat.list_spaces(kind: "channel", scope: scope) ++
       Chat.list_user_conversations(user.id, scope: scope))
    |> ids()
  end

  defp visibility(user) do
    case Tenancy.visibility(user) do
      :root_all -> :all
      {:orgs, ids} -> ids
      :none -> :none
    end
  end

  defp request_outcome(user, path) do
    conn = if user, do: authed(user), else: build_conn()

    # A plug that raises a `plug_status` exception (RequireSignInAdmin's 404)
    # is rendered by the endpoint's error view in production; ConnTest
    # re-raises it, so read its status the way `Plug.Exception` does.
    conn =
      try do
        get(conn, path)
      rescue
        e -> %Plug.Conn{status: Plug.Exception.status(e)}
      end

    case conn.status do
      200 -> :admitted
      403 -> :forbidden
      404 -> :not_found
      302 -> classify_redirect(redirected_to(conn), conn)
      other -> {:status, other}
    end
  end

  defp classify_redirect("/auth/login", _conn), do: :login

  # Quantity 4 still compares the denial class. Stage 3 gives that denial a
  # dedicated destination and its message on the 403 page instead of a flash.
  defp classify_redirect("/access-denied?module=admin", _conn), do: :denied_admin

  defp classify_redirect("/", _conn), do: {:redirect, "/"}

  # The page passed every gate and then redirected for its own reasons (an
  # unknown `:slug` placeholder, for example).
  defp classify_redirect(_to, _conn), do: :admitted

  defp tools_list(rt) do
    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> rt.__token__)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})
      |> response(200)
      |> Jason.decode!()

    {Enum.map(body["result"]["tools"], & &1["name"]), body}
  end

  # Today's rail as rendered on the first page this actor can actually load:
  # `/tasks` for an internal user; for a guest, each of their chat spaces in
  # turn (the plug's slug lookup is org-scoped, so not every participant
  # space loads), then `/chat`. A row with no loadable page fails the test
  # rather than reading as an empty rail.
  defp rendered_rail(user, ctx) do
    candidates =
      if Tenancy.external_user?(user) do
        spaces = listed_spaces(user, ExternalScope.for_user(user)) |> spaces_of(ctx)
        Enum.uniq(Enum.map(spaces, &"/chat/#{&1.slug}") ++ ["/chat"])
      else
        ["/tasks"]
      end

    {html, tried} =
      Enum.reduce_while(candidates, {nil, []}, fn path, {nil, tried} ->
        conn = authed(user) |> get(path)

        case conn.status do
          200 -> {:halt, {html_response(conn, 200), tried}}
          status -> {:cont, {nil, [{path, status, get_resp_header(conn, "location")} | tried]}}
        end
      end)

    assert html, "no page loads for #{user.id}: #{inspect(Enum.reverse(tried))}"

    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-icon-rail] .icon-rail-tab:not(.icon-rail-tab--child)")
    |> LazyHTML.attribute("data-destination")
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.sort()
  end

  # The Files browser (task 01a1557a-b5f9 stage 2) keeps the viewer's
  # projects in its `@tree`, the source every project id is checked against.
  defp files_page_projects(user) do
    {:ok, view, _html} = live(authed(user), "/files")
    tree = :sys.get_state(view.pid).socket.assigns.tree
    (Enum.flat_map(tree.orgs, & &1.projects) ++ tree.other.projects) |> ids()
  end

  # ── The Scope's side ────────────────────────────────────────────────────

  defp scope_rail(user) do
    # The desktop rail's tiles only: a More-sheet-only (`:sheet`) destination
    # such as Changelog is never on the rendered rail (task 01a1557a-807f).
    installed =
      IconRail.destinations(root_user: true)
      |> Enum.filter(&(&1.cluster in IconRail.desktop_clusters()))
      |> Enum.map(& &1.key)

    user
    |> loaded()
    |> Scope.for_user()
    |> Scope.declared_rail()
    |> Enum.filter(&(&1 in installed))
    |> Enum.sort()
  end

  defp predict_board(scope) do
    cond do
      Scope.can?(scope, "tasks.read") -> 200
      Scope.guest?(scope) -> 403
      true -> :no_tasks_permission
    end
  end

  defp scope_visibility(scope) do
    case Scope.permitted_ids(scope, "orgs.read") do
      :all -> :all
      [] -> :none
      ids -> ids
    end
  end

  defp scope_projects(scope, projects) do
    case Scope.permitted_ids(scope, "orgs.read") do
      :all -> ids(projects)
      org_ids -> projects |> Enum.filter(&(&1.org_id in org_ids)) |> ids()
    end
  end

  # `/admin/sign-in-users` 404s for everyone while the feature is off: that
  # gate is a deployment switch, not access, and runs before authentication.
  defp predict_admin(scope, session, user) do
    cond do
      session == :admin_sign_in and not Platform.SignInAdmin.Config.enabled?() -> :not_found
      user == nil -> :login
      Scope.can?(scope, "install.admin") -> :admitted
      Scope.guest?(scope) -> :forbidden
      true -> :denied_admin
    end
  end

  # The four admin-only permissions are each `membership_org`; the Scope
  # calls a user an org admin of `org` when it holds all of them there.
  defp scope_org_admin?(scope, org) do
    Enum.all?(
      ~w(access.manage mail.manage prototypes.publish tasks.promote),
      &Scope.can?(scope, &1, org)
    )
  end

  # Every catalogue tool whose bundle permission the Scope holds, through the
  # same external reduction. Order-insensitive: this is the CALLABLE set.
  defp granted_tools(scope) do
    ToolSurface.all_bundles()
    |> Enum.filter(fn bundle ->
      case Registry.bundle_permission(bundle) do
        nil -> false
        permission -> Scope.can?(scope, permission)
      end
    end)
    |> ToolSurface.list_tools()
    |> ToolSurface.scope_for_external(Scope.guest?(scope))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The body the Scope's tool list renders to: today's envelope, its tools
  # replaced by the Scope's names, in the Scope's order, each in its wire form
  # from the full-catalogue listing.
  defp scope_body(body, names, catalogue) do
    put_in(body, ["result", "tools"], Enum.map(names, &Map.fetch!(catalogue, &1)))
  end

  defp wire_catalogue(rt_full) do
    {_names, body} = tools_list(rt_full)
    Map.new(body["result"]["tools"], &{&1["name"], &1})
  end

  defp canonical_hash(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  # ── Routes ──────────────────────────────────────────────────────────────

  defp admin_routes do
    for route <- Phoenix.Router.routes(@router),
        route.verb == :get,
        {_view, _action, _opts, %{name: session}} <-
          [route.metadata[:phoenix_live_view]],
        session in @admin_sessions do
      {session, fill_params(route.path)}
    end
    |> Enum.uniq()
  end

  defp fill_params(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "equivalence-probe"
      "*" <> _ -> "equivalence-probe"
      seg -> seg
    end)
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp human!(fun) do
    user = World.create_user!()
    fun.(user)
    user
  end

  defp member!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  defp external!(user, org_id, role) do
    {:ok, m} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id, role: role})
    m
  end

  defp space!(kind, org_id, users) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Eq #{kind} #{n}",
        slug: "eq-#{kind}-#{n}",
        kind: kind,
        org_id: org_id,
        is_direct: kind == "dm"
      })

    for u <- users, do: World.add_user!(space.id, u.id)
    space
  end

  defp runtime!(owner, bundles, spaces) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "eq-agent-#{n}", name: "Eq Agent #{n}", status: "active"})
      |> Repo.insert()

    for s <- spaces, do: World.add_agent!(s.id, agent.id)

    token = AgentRuntime.generate_token()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "eq-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(token),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        rt,
        bundles,
        Platform.Access.RuntimeProfiles.translated_permissions(bundles)
      )

    Map.put(rt, :__token__, token)
  end

  defp authed(user), do: World.login(build_conn(), user.id)

  defp loaded(user), do: Accounts.get_user(user.id)

  defp spaces_of(ids, ctx) do
    known = Map.new(ctx.spaces, &{&1.id, &1})
    ids |> Enum.map(&(Map.get(known, &1) || Chat.get_space(&1))) |> Enum.reject(&is_nil/1)
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()

  # The org fence's expected set (ticket 01a14721), computed from the rows,
  # never from `Platform.Access`: the space's org is one of the user's
  # membership orgs, or the user holds a `chat_participants` row for it.
  defp in_fence_or_participant(space_ids, user) do
    orgs = Enum.map(Tenancy.list_user_memberships(user), & &1.org_id)

    Enum.filter(space_ids, fn id ->
      space = Chat.get_space(id)
      space.org_id in orgs or Chat.participant?(id, user.id)
    end)
  end
end
