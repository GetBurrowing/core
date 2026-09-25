defmodule PlatformWeb.RouterAppSurfaceWiringTest do
  @moduledoc """
  Pins the WIRING of `PlatformWeb.Plugs.HostSurface` into the router as the
  `:require_app_surface` pipeline (task 019fcf22 stage 3), and pins the
  HOST-AGNOSTIC set that must NOT receive it.

  Two different claims are asserted with two different instruments, because
  they can disagree in both directions — a route can be correctly placed and
  still 404 from a plug, and a route can 404 for reasons that have nothing to
  do with placement:

    * ROUTE PLACEMENT — `Phoenix.Router.route_info/4`, which reports the
      `:pipe_through` list actually compiled onto each route.
    * OBSERVABLE BEHAVIOUR — a real request through `PlatformWeb.Endpoint`.

  ## Behaviour is UNCHANGED by this stage

  Enforcement is `:off` by config, so wiring the pipeline in moves nothing an
  operator or user could see. The `describe "enforcement :off"` block is that
  claim stated as tests: an authenticated internal user gets a 200 on `/tasks`
  on the app host AND on a `chat.`-prefixed host, exactly as before. Stage 4
  flips the flag; these two assertions are expected to diverge THEN, and that
  divergence is that stage's evidence, not a regression in this one.

  ## The dangerous case

  `/auth/oidc/callback` is the single most expensive thing this stage could
  get wrong. External sign-in BEGINS on the chat host and the redirect URI
  registered at the IdP is a fixed absolute URL, so fencing that route breaks
  production login with an error that reads like an IdP misconfiguration. It
  is asserted here with enforcement `:on` — i.e. under the stage-4 world — so
  the assertion bites now rather than after the flag flips. This is the case
  the stage-3 mutation (adding `:require_app_surface` to the unauthenticated
  `:browser` scope) exists to kill.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Router

  @app_host "example.com"
  @chat_host "chat.example.com"

  defp with_enforcement(value) do
    previous = Application.get_env(:platform, :host_surface_enforcement, :off)
    Application.put_env(:platform, :host_surface_enforcement, value)
    on_exit(fn -> Application.put_env(:platform, :host_surface_enforcement, previous) end)
    :ok
  end

  defp internal_user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "app-surface-#{n}@example.com",
        name: "AppSurface #{n}",
        oidc_sub: "oidc-app-surface-#{n}"
      })
      |> Repo.insert!()

    # Seeded tenant org: its slug atom is pre-registered, which TasksLive's
    # scope rail requires (`String.to_existing_atom` over active tenants).
    org = Tenancy.get_org_by_slug!("sxi")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp on_host(conn, host), do: %{conn | host: host}

  describe "route placement (route_info/4)" do
    test "the default scope's routes carry :require_app_surface" do
      for path <- ["/tasks", "/meetings", "/admin", "/chat", "/canvases/some-id"] do
        info = Phoenix.Router.route_info(Router, "GET", path, @app_host)

        assert is_map(info), "#{path} did not resolve on the app host"

        assert :require_app_surface in info.pipe_through,
               "#{path} is missing :require_app_surface — got #{inspect(info.pipe_through)}"
      end
    end

    test ":require_app_surface is LAST so an unauthenticated request still redirects to login" do
      info = Phoenix.Router.route_info(Router, "GET", "/tasks", @app_host)

      assert info.pipe_through == [
               :browser,
               :require_auth,
               :enforce_external_scope,
               :require_app_surface
             ]
    end

    test "the host-agnostic set does NOT carry :require_app_surface" do
      # Pinned exactly, per scope, as verified against the router tree. Each
      # entry is a deliberate decision documented at its scope in router.ex.
      agnostic = [
        # unauthenticated :browser scope — uptime probes and the login flow
        {"GET", "/health"},
        {"GET", "/auth/login"},
        {"GET", "/auth/oidc/callback"},
        {"GET", "/auth/logout"},
        {"GET", "/org-context"},
        {"GET", "/org-context/some/file.md"},
        # HMAC-token attachment fetch and presigned upload — no session
        {"GET", "/chat/attachments/some-id"},
        {"POST", "/chat/attachments/upload/some-token"},
        # subscribed calendar feed, fetched by a third-party server
        {"GET", "/meetings/some-id/invite.ics"},
        # machine callers; the webhook URLs live in someone else's console
        {"POST", "/api/internal/usage-events"},
        {"PATCH", "/api/messages/some-id"},
        {"GET", "/api/messages/some-id/versions"},
        {"POST", "/api/meetings/segments"},
        {"POST", "/api/webhooks/github"},
        {"POST", "/api/webhooks/livekit"},
        {"POST", "/mcp"},
        {"GET", "/mcp"},
        # peer-install descriptor and inbox, called by other installs (task 01a0d90f)
        {"GET", "/.well-known/suite-federation"},
        {"POST", "/federation/v1/inbox"}
      ]

      for {verb, path} <- agnostic do
        info = Phoenix.Router.route_info(Router, verb, path, @app_host)

        assert is_map(info), "#{verb} #{path} did not resolve at all"

        refute :require_app_surface in info.pipe_through,
               "#{verb} #{path} was fenced — got #{inspect(info.pipe_through)}"
      end
    end

    test "the host-agnostic set also resolves on a chat-prefixed host" do
      # Placement and reachability are separate claims: the routes above are
      # unfenced, but that is only useful if they still MATCH on the external
      # host, which is where the login flow and the webhooks actually land.
      for {verb, path} <- [
            {"GET", "/health"},
            {"GET", "/auth/oidc/callback"},
            {"POST", "/api/webhooks/livekit"},
            {"GET", "/.well-known/suite-federation"},
            {"POST", "/federation/v1/inbox"}
          ] do
        info = Phoenix.Router.route_info(Router, verb, path, @chat_host)

        assert is_map(info), "#{verb} #{path} did not resolve on the chat host"
        refute :require_app_surface in info.pipe_through
      end
    end
  end

  describe "enforcement :off (the default) — nothing observable moved" do
    setup %{conn: conn} do
      :ok = with_enforcement(:off)
      user = internal_user!()
      %{conn: init_test_session(conn, current_user_id: user.id)}
    end

    test "authenticated internal user still gets 200 on /tasks on the app host", %{conn: conn} do
      assert conn |> on_host(@app_host) |> get("/tasks") |> Map.fetch!(:status) == 200
    end

    test "authenticated internal user still gets 200 on /tasks on a chat host", %{conn: conn} do
      # This is the assertion that stage 4 will invert. Today the default
      # scope is match-any-host and the plug is dark, so the app is fully
      # navigable from the chat host — the habit this task exists to break.
      assert conn |> on_host(@chat_host) |> get("/tasks") |> Map.fetch!(:status) == 200
    end
  end

  describe "enforcement :on — the host-agnostic set survives the fence" do
    setup do
      :ok = with_enforcement(:on)
    end

    test "/auth/oidc/callback on the chat host reaches AuthController, not a 404", %{conn: conn} do
      # THE MUTATION TARGET. With `:require_app_surface` added to the
      # unauthenticated `:browser` scope, this 404s and external login is
      # broken in production.
      info = Phoenix.Router.route_info(Router, "GET", "/auth/oidc/callback", @chat_host)
      assert info.plug == PlatformWeb.AuthController
      assert info.plug_opts == :callback

      conn = conn |> on_host(@chat_host) |> get("/auth/oidc/callback")

      refute conn.status == 404,
             "the OIDC callback was fenced on the chat host — external sign-in is broken"

      # No-params callback takes the `invalid_state` path; the point is only
      # that the controller ran at all.
      assert conn.status in [302, 401, 403]
    end

    test "/health answers 200 on the chat host", %{conn: conn} do
      assert conn |> on_host(@chat_host) |> get("/health") |> Map.fetch!(:status) == 200
    end

    test "/auth/login is not fenced on the chat host", %{conn: conn} do
      refute conn |> on_host(@chat_host) |> get("/auth/login") |> Map.fetch!(:status) == 404
    end

    test "POSITIVE CONTROL: an authenticated internal user still gets 200 on /tasks on the app host",
         %{conn: conn} do
      # Mandatory. Without a same-run positive control on the fenced route
      # itself, a plug that halted unconditionally — or a fence that was
      # simply over-broad — would pass every assertion above.
      user = internal_user!()

      status =
        conn
        |> init_test_session(current_user_id: user.id)
        |> on_host(@app_host)
        |> get("/tasks")
        |> Map.fetch!(:status)

      assert status == 200
    end

    test "the fence DOES bite the chat host (proof the :on setup took effect)", %{conn: conn} do
      # Sibling of the control above: without this, every assertion in this
      # block would pass with enforcement stuck at :off, and the block would
      # be measuring nothing.
      user = internal_user!()

      status =
        conn
        |> init_test_session(current_user_id: user.id)
        |> on_host(@chat_host)
        |> get("/tasks")
        |> Map.fetch!(:status)

      assert status == 404
    end
  end
end
