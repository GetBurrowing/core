defmodule PlatformWeb.RouterMeetRootTest do
  @moduledoc """
  ROUTED coverage for the meet-host ROOT (task 019ffe8a stage 2).

  ## Why a routed module rather than a plug-direct one

  Stage 1 added `{:meet, []} -> conn` to `ExternalUserScope`, and its tests
  drive `call/2` directly on a `Plug.Test` conn. That shape cannot observe
  whether the path the plug ADMITS has a route on that host — `refute
  conn.halted` is compatible with a 404, the plug saying yes to a door that
  is not there. That is the defect 019f9cb7 shipped green for the index.
  This module supplies the routed proof for the root: every case goes
  through `Phoenix.ConnTest.get/2` — endpoint, router, full pipeline.

  `:host_surface_enforcement` is LEFT AT ITS PRODUCTION `:on`. Relaxing the
  fence is precisely what hid the original bug; a test that switches it off
  proves nothing about whether the route exists.

  ## The two wrong answers are different bugs

  On the meet root, **404 means the route is missing** (this stage) and
  **403 means the admission clause is missing** (stage 1). They need
  opposite fixes, so the assertion messages below name them separately
  rather than asserting a bare 302.

  ## Blast radius

  `PageController` now carries TWO root actions, `home/2` and `meet_home/2`.
  The CHAT host is the nearest neighbour to the new one — a mistake in
  `meet_home/2`, a mis-wired route or a reordered scope lands on `/` at
  `chat.` first — so the chat root is pinned here alongside the app root.

  `async: false` — `:meet_host`, `:chat_host` and the enforcement flag are
  process-global application state.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  @router PlatformWeb.Router

  @meet_host "meet.example.com"
  @app_host "localhost"
  @chat_host "chat.example.com"

  setup do
    previous_meet = Application.get_env(:platform, :meet_host)
    previous_chat = Application.get_env(:platform, :chat_host)
    previous_fence = Application.get_env(:platform, :host_surface_enforcement, :off)

    Application.put_env(:platform, :meet_host, @meet_host)
    Application.put_env(:platform, :chat_host, @chat_host)
    # Deliberately ON — the production value, and the condition under which
    # the meet root 404'd.
    Application.put_env(:platform, :host_surface_enforcement, :on)

    on_exit(fn ->
      Application.put_env(:platform, :host_surface_enforcement, previous_fence)

      if previous_meet,
        do: Application.put_env(:platform, :meet_host, previous_meet),
        else: Application.delete_env(:platform, :meet_host)

      if previous_chat,
        do: Application.put_env(:platform, :chat_host, previous_chat),
        else: Application.delete_env(:platform, :chat_host)
    end)

    :ok
  end

  defp user_with_membership!(external?) do
    n = System.unique_integer([:positive])
    kind = if external?, do: "ext", else: "int"

    user =
      Repo.insert!(%User{
        email: "#{kind}_root_#{n}@example.com",
        name: "Root Viewer #{n}",
        oidc_sub: "oidc-#{kind}-root-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member",
      external: external?
    })
    |> Repo.insert!()

    user
  end

  defp external_user!, do: user_with_membership!(true)
  defp internal_user!, do: user_with_membership!(false)

  defp as(conn, user, host) do
    %{conn | host: host}
    |> init_test_session(current_user_id: user.id)
  end

  describe "the meet-host root over a real routed request" do
    test "external member, meet host, / → 302 to /meetings", %{conn: conn} do
      conn = get(as(conn, external_user!(), @meet_host), "/")

      refute conn.status == 404,
             "404: no `/` route on the meet host — the router change is missing"

      refute conn.status == 403,
             "403: ExternalUserScope denied the root — stage 1's `{:meet, []}` " <>
               "admission clause is missing or sits below the terminal deny"

      assert conn.status == 302
      assert redirected_to(conn) == "/meetings"
    end

    test "the root resolves to PageController.meet_home on the meet host, and the " <>
           "two-segment guest ingress is unshadowed" do
      # Pins the post-change `route_info` measured before and after the edit.
      # Before: the root resolved to the match-any-host default scope, whose
      # pipeline ends in `:require_app_surface` — hence the uniform 404.
      assert %{plug: PlatformWeb.PageController, plug_opts: :meet_home, route: "/"} =
               Phoenix.Router.route_info(@router, "GET", "/", @meet_host)

      # The guest ingress is TWO segments and cannot match a zero-segment
      # path, and no bare `/:slug` is declared — so the new root shadows
      # nothing. Verified, not assumed.
      assert %{route: "/:slug/:token"} =
               Phoenix.Router.route_info(@router, "GET", "/a-slug/a-token", @meet_host)
    end

    test "/meetings on the meet host still renders 200 directly", %{conn: conn} do
      # One canonical URL must not become zero working ones: the redirect
      # target has to be reachable in its own right.
      conn = get(as(conn, external_user!(), @meet_host), "/meetings")

      assert conn.status == 200
    end
  end

  describe "the sibling roots are untouched" do
    test "app host / still serves PageController.home and redirects an internal user to /chat",
         %{conn: conn} do
      assert %{plug: PlatformWeb.PageController, plug_opts: :home} =
               Phoenix.Router.route_info(@router, "GET", "/", @app_host)

      conn = get(as(conn, internal_user!(), @app_host), "/")

      assert conn.status == 302
      assert redirected_to(conn) == "/chat"
    end

    test "chat host / still redirects to /chat", %{conn: conn} do
      # MANDATORY, not optional. The chat root is the nearest blast radius to
      # the action added this stage.
      assert %{plug: PlatformWeb.PageController, plug_opts: :home} =
               Phoenix.Router.route_info(@router, "GET", "/", @chat_host)

      conn = get(as(conn, external_user!(), @chat_host), "/")

      assert conn.status == 302
      assert redirected_to(conn) == "/chat"
    end
  end

  describe "the meet root is fail-closed without a configured meet host" do
    setup do
      Application.delete_env(:platform, :meet_host)
      :ok
    end

    # MEASURED, and it corrects the stage brief. The brief expected 403 here
    # ("not 200, not a redirect"), by analogy with the INDEX's fail-closed
    # case in `router_meet_index_routed_test.exs`. The root cannot produce a
    # 403 on an unconfigured meet host, and the reason is structural and
    # predates this stage:
    #
    #   With `:meet_host` unset, `ExternalSurface.for_conn/1` answers `:app`,
    #   not `:meet` — so the terminal `{:meet, _}` deny is never consulted.
    #   A root request has `path_info == []`, which reaches the generic
    #   `{_, []} -> fence_to_chat_host(conn) || conn` clause. That clause
    #   ADMITS or FENCES; it never denies. The index differs only because
    #   `["meetings"]` on the `:app` surface is off-surface.
    #
    # The root was a redirect BEFORE this change too (to `/chat`, via the
    # default scope's `PageController.home`), so "not a redirect" was never
    # true of it. What must be true is that the root grants no MEET-surface
    # access on an unconfigured host — so that is what is pinned, by
    # following the redirect to its destination.

    test "unconfigured :meet_host → the root opens no meet surface", %{conn: conn} do
      user = external_user!()

      conn = get(as(conn, user, @meet_host), "/")

      # Either the generic chat-host fence (when `:chat_host` is configured,
      # as in production) or this stage's redirect. Never a rendered surface.
      refute conn.status == 200

      # THE PROPERTY THAT MATTERS: the destination is not reachable either.
      # The new root is not a hole — it cannot be used to walk onto the meet
      # surface of a host that has no meet surface.
      denied = get(as(build_conn(), user, @meet_host), "/meetings")
      assert denied.status == 403
    end
  end

  # A meeting the external user holds NO invite to — same org as the viewer,
  # so only the missing invite can deny it. Mirrors the fixture in
  # `router_meet_index_routed_test.exs`.
  defp uninvited_meeting! do
    org_id = Platform.TenancyFixtures.acme_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Meet Root Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    now = DateTime.utc_now()

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Uninvited Root Session",
        scheduled_start_at: DateTime.add(now, 3600, :second),
        scheduled_end_at: DateTime.add(now, 5400, :second)
      })

    meeting
  end

  describe "the anonymous path off the meet root (task 019ffe8a stage 3)" do
    # Verified at origin/main 5d50bbe7 rather than assumed:
    # `PlatformWeb.Plugs.RequireAuth.call/2` with no `:current_user_id`
    # emits `[:platform, :auth, :access_blocked]` and does
    # `redirect(to: "/auth/login") |> halt()`. That target is HOST-RELATIVE,
    # so it names a path on whatever host the visitor arrived at.

    test "no session, meet host, / → 302 to /auth/login", %{conn: conn} do
      conn = get(%{conn | host: @meet_host}, "/")

      refute conn.status == 404,
             "404: the anonymous visitor never even reached `:require_auth` — " <>
               "the meet-host root route is missing"

      assert conn.status == 302

      # The DESTINATION, not merely that a redirect happened: a 302 to
      # nowhere useful is the failure this pins against.
      assert redirected_to(conn) == "/auth/login"
    end

    test "/auth/login is reachable on the meet host under enforcement :on", %{conn: conn} do
      # THIS IS WHAT MAKES THE TEST ABOVE NON-VACUOUS. A redirect to a path
      # that 404s on this host is still a dead end, and asserting the
      # redirect target alone cannot tell the two apart.
      #
      # `get("/auth/login", AuthController, :login)` is declared in the
      # UNAUTHENTICATED match-any-host `scope "/"`, piped only through
      # `:browser` — no `:require_app_surface`, so `HostSurface` does not
      # fence it on a non-`:app` host.
      conn = get(%{conn | host: @meet_host}, "/auth/login")

      refute conn.status == 404,
             "404: the sign-in entry point is fenced on the meet host, so the " <>
               "root's redirect is a dead end — check that the unauthenticated " <>
               "scope still omits `:require_app_surface`"

      # Pin what it actually does: hand off to the IdP (302 external) when
      # OIDC is configured, or fail loudly (500) when it is not. Either way
      # the router reached the controller, which is the property under test.
      assert conn.status in [302, 500]
    end

    # NAMED, NOT FIXED — see the comment on `get("/", PageController,
    # :meet_home)` in the router. `AuthController.callback/2` sends an
    # external full user to an ABSOLUTE chat-host URL whenever `CHAT_HOST`
    # is configured, because the OIDC redirect URI registered with the IdP
    # cannot round-trip the originating host. So a member who signs in FROM
    # the meet host completes login on the CHAT host, not back at
    # `/meetings`. This stage makes the bare meet domain work for an
    # ALREADY-signed-in member; it does not make sign-in return you there.
    # Fixing it means carrying an origin host through OIDC state, which has
    # its own open-redirect surface and deserves its own ticket.
  end

  describe "adding the root did not alter /meetings/:slug" do
    test "external user, meet host, an uninvited slug → still 403 and no name echo",
         %{conn: conn} do
      meeting = uninvited_meeting!()

      conn = get(as(conn, external_user!(), @meet_host), "/meetings/#{meeting.slug}")

      assert conn.status == 403

      # The denial is per-meeting, and it is not an existence oracle either.
      refute conn.resp_body =~ meeting.name
    end
  end
end
