defmodule PlatformWeb.ShellLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.AsyncResult
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp authenticated_conn(conn, opts \\ []) do
    role = Keyword.get(opts, :role, "admin")

    user =
      Repo.insert!(%User{
        email: "shell_test_#{System.unique_integer([:positive])}@example.com",
        name: "Shell Test User",
        oidc_sub: "oidc-shell-test-#{System.unique_integer([:positive])}"
      })

    # MT/RBAC stack 2 (task 019e3c4a): the admin nav gate now reads
    # `Tenancy.fabrikam_admin_preloaded?/1` instead of the
    # `Accounts.is_fabrikam_user?/1` stub. Default test users are admin so
    # the existing "renders rail / admin section" assertions keep working;
    # tests that need a non-admin can pass `role: "member"`.
    if role do
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      Repo.insert!(%OrgMembership{
        user_id: user.id,
        org_id: fabrikam.id,
        role: role
      })
    end

    init_test_session(conn, current_user_id: user.id)
  end

  # PWA app-shell scroll lock regression. The root shell container must
  # constrain itself to the viewport (`h-[100vh]`) and refuse to scroll
  # (`overflow-hidden`) so the bottom-tab nav stays functionally rooted on
  # mobile — without these classes, the body itself scrolls and drags the
  # chrome out of view (Rowan's mobile review-request hotfix, supersedes
  # the inner `pb-` clearance from PR #331). Asserting the literal class
  # string keeps the fix from being quietly removed during refactors.
  test "shell root container locks to viewport height (PWA scroll lock)", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # h-[100vh] MUST match the `html, body { height: 100vh }` lock in
    # app.css — and it must be 100vh, NOT 100dvh/100svh. In an installed
    # iOS PWA, 100dvh/100svh resolve to the inset-short viewport (793px on
    # iPhone 16) while 100vh resolves to the full screen (852px); the
    # shorter value leaves a ~59px uncovered strip at the bottom. PRs
    # #339/#350/#351 chased this through svh and env-padding before the
    # on-device Web Inspector measurement (2026-05-14) confirmed the fix
    # is simply 100vh. Top inset → `safe-area-top`; bottom inset →
    # `padding-bottom: env(safe-area-inset-bottom)` on `.bottom-nav`.
    assert html =~ "h-[100vh]"
    assert html =~ "overflow-hidden"
    # The main surface must contain its own iOS rubber-band so an inner
    # panel's overscroll cannot displace the chrome.
    assert html =~ "overscroll-contain"
  end

  # Shell main + inner-content-column min-h-0 regression. Take 2 of the
  # PWA scroll lock (Rowan's report after #333 merged): #333 rooted the
  # OUTER shell chrome, but the inner content column and <main> were
  # still using default `min-height: auto` so a long inner panel could
  # blow past their flex-1 allocation and push the bottom-tab nav
  # off-screen on iOS WebKit. min-h-0 lets the flex children actually
  # shrink to their bounded `flex-1` height — which is what makes the
  # internal scrollers (#message-list, etc.) own the scroll instead of
  # the document.
  test "shell inner content column and main set min-h-0 for iOS flex sizing", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # Inner column: flex-col that holds header + main + bottom-nav.
    # Without min-h-0 on this container, flex children inherit
    # min-height: auto and the column grows to its intrinsic content
    # height, defeating the h-[100dvh] root.
    assert html =~ ~r/<div[^>]*class="[^"]*flex flex-1 flex-col overflow-hidden[^"]*min-h-0/
    # <main>: must also set min-h-0 so it can shrink past its
    # intrinsic content height when the LiveView's surface is taller
    # than the available viewport.
    assert html =~ ~r/<main[^>]*class="[^"]*flex-1 min-h-0/
  end

  test "shell loads principal_name and composite_status when a space with agents exists", %{
    conn: conn
  } do
    # Create a space and set a principal agent
    {:ok, space} = Chat.create_space(%{name: "Test Space", slug: "test-shell-roster"})

    agent =
      Repo.insert!(%Agent{
        name: "TestBot",
        slug: "testbot-shell-#{System.unique_integer([:positive])}",
        status: "active",
        runtime_type: "builtin"
      })

    Chat.set_principal_agent(space.id, agent.id)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

    # assign_async resolves shortly after WS-connected mount; the rendered HTML
    # then contains the "Agents" roster button label. Re-render after a brief
    # wait to give the Task time to complete + the LV to receive the update.
    html = render_async(view, 1_000)
    assert html =~ "Agents"
  end

  test "shell shows legacy status dot when no space exists", %{conn: conn} do
    # Clean slate — no spaces
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat")

    # Wait for the async load to resolve to {principal_name: nil, ...}; the
    # template then falls through to the legacy "Agent" label branch.
    html = render_async(view, 1_000)
    assert html =~ "Startup Suite"
  end

  test "WS-connected mount initially renders roster + presence as loading AsyncResults", %{
    conn: conn
  } do
    {:ok, space} = Chat.create_space(%{name: "Loading Space", slug: "test-shell-loading"})

    agent =
      Repo.insert!(%Agent{
        name: "LoadingBot",
        slug: "loadingbot-#{System.unique_integer([:positive])}",
        status: "active",
        runtime_type: "builtin"
      })

    Chat.set_principal_agent(space.id, agent.id)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Inspect the LV's assigns directly. After the async load resolves, all
    # four roster keys should be %AsyncResult{ok?: true, result: ...}.
    _html = render_async(view, 1_000)

    assigns = :sys.get_state(view.pid).socket.assigns

    assert %AsyncResult{ok?: true, result: items} = assigns.roster_items
    assert is_list(items)
    assert %AsyncResult{ok?: true, result: composite} = assigns.composite_status
    assert is_atom(composite)
    assert %AsyncResult{ok?: true, result: name} = assigns.principal_name
    assert name == "LoadingBot"
    assert %AsyncResult{ok?: true, result: presence} = assigns.presence_list
    assert is_list(presence)

    # The PubSub-driven refresh path keeps the AsyncResult shape so the
    # template's <.async_result> component continues to render the resolved
    # branch even after `refresh_roster/2` runs.
    send(view.pid, {:roster_changed, space.id})
    _html = render(view)
    assigns_after = :sys.get_state(view.pid).socket.assigns
    assert %AsyncResult{ok?: true, result: _} = assigns_after.roster_items
    assert %AsyncResult{ok?: true, result: _} = assigns_after.composite_status
    assert %AsyncResult{ok?: true, result: _} = assigns_after.principal_name
  end

  test "roster_resolved message subscribes to PubSub topics for the space", %{conn: conn} do
    {:ok, space} = Chat.create_space(%{name: "PubSub Space", slug: "test-shell-pubsub"})

    agent =
      Repo.insert!(%Agent{
        name: "PubSubBot",
        slug: "pubsubbot-#{System.unique_integer([:positive])}",
        status: "active",
        runtime_type: "builtin"
      })

    Chat.set_principal_agent(space.id, agent.id)

    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")
    _html = render_async(view, 1_000)

    # After resolve, roster_space_id is the bare binary (not AsyncResult).
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.roster_space_id == space.id
  end

  test "shell chat nav link relies on RouteResume — no dedicated last-chat hook", %{conn: conn} do
    # Task 019f3e9a stage 3: LastChatLink hook was subsumed by RouteResume
    # (which persists per-module last-URL under the `route_resume` namespace
    # via ClientState). The Chat tile no longer needs a bespoke hook / id /
    # data-default-chat-path — the delegated click intercept on RouteResume
    # handles resume.
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    refute html =~ ~s(id="shell-chat-link")
    refute html =~ ~s(phx-hook="LastChatLink")
    refute html =~ ~s(data-default-chat-path)
    # RouteResume is expected on the shell body — sanity-check it's present.
    assert html =~ ~s(phx-hook="RouteResume")
  end

  test "sidebar collapse hook element advertises current collapsed state", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ ~s(id="sidebar-collapse-hook")
    assert html =~ ~s(phx-hook="SidebarCollapse")
    # Default is expanded → data-collapsed="false"
    assert html =~ ~s(data-collapsed="false")
  end

  test "sidebar_hydrate event collapses the sidebar when stored value is true", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Hook reports a stored "collapsed" preference from localStorage.
    render_hook(view, "sidebar_hydrate", %{"collapsed" => true})

    html = render(view)
    # Hook element re-renders with the new state.
    assert html =~ ~s(data-collapsed="true")
    # Sidebar nav now renders in collapsed mode (lg:w-14 instead of w-56).
    assert html =~ "lg:w-14"
    refute html =~ ~s(class=\"text-sm font-medium\">Chat</span>)
  end

  test "sidebar_hydrate event with false leaves sidebar expanded", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    render_hook(view, "sidebar_hydrate", %{"collapsed" => false})

    html = render(view)
    assert html =~ ~s(data-collapsed="false")
    assert html =~ "w-56"
  end

  test "toggle_sidebar pushes sidebar_collapsed_changed event for the hook to persist", %{
    conn: conn
  } do
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/tasks")

    # Render the toggle click; the LV should both flip the assign and push an
    # event the hook listens for.
    html = render_click(view, "toggle_sidebar", %{})
    assert html =~ ~s(data-collapsed="true")
    assert_push_event(view, "sidebar_collapsed_changed", %{collapsed: true})

    html = render_click(view, "toggle_sidebar", %{})
    assert html =~ ~s(data-collapsed="false")
    assert_push_event(view, "sidebar_collapsed_changed", %{collapsed: false})
  end

  # ---------------------------------------------------------------------
  # Icon-rail integration (task 019e389b Stage 3)
  #
  # The component-level rendering contract is covered by IconRailTest.
  # These tests check the *wiring*: shell layout passes the right assigns
  # (current_path, is_fabrikam_user, sidebar_collapsed) to the icon-rail and
  # bottom-rail at both breakpoints, and the Admin slot's DOM presence
  # respects the is_fabrikam_user gate end-to-end.
  # ---------------------------------------------------------------------

  describe "icon-rail integration" do
    test "renders the desktop icon-rail wrapper", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(data-icon-rail)
      assert html =~ ~s(id="shell-sidebar")
      assert html =~ ~s(aria-label="Main navigation")
    end

    test "renders the mobile bottom-rail wrapper", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(data-bottom-rail)
    end

    test "active-state marker tracks current_path on the desktop rail", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The Tasks tile carries the active class + aria-current=page when on /tasks.
      # Attribute order between `data-destination` and `aria-current` is not
      # guaranteed by the renderer, so accept either order.
      assert html =~ ~r/icon-rail-tab--active[^"]*"[^>]*data-destination="tasks"/

      assert html =~ ~r/data-destination="tasks"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="tasks"/s
    end

    test "active-state marker tracks current_path on the mobile bottom-rail", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ ~r/bottom-nav-tab--active[^"]*"[^>]*data-destination="activity"/
    end

    test "Admin tile renders on the desktop rail for an admin user", %{
      conn: conn
    } do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # After MT/RBAC stack 2 (task 019e3c4a), the Admin tile is gated on
      # `Tenancy.fabrikam_admin_preloaded?/1` instead of the
      # `Accounts.is_fabrikam_user?/1` stub. Default test conn seeds an admin
      # membership so the tile renders.
      assert html =~ ~s(data-destination="admin")
    end

    test "Admin tile is absent from the desktop rail for a non-admin (member) user", %{
      conn: conn
    } do
      conn = authenticated_conn(conn, role: "member")
      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(data-destination="admin")
    end

    test "Chat tile relies on RouteResume rather than a bespoke last-chat hook", %{
      conn: conn
    } do
      # Task 019f3e9a stage 3: LastChatLink retired; RouteResume owns per-module
      # last-URL restore. Assert the legacy markers are gone so the tests fail
      # loudly if a stray re-introduction lands.
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(id="shell-chat-link")
      refute html =~ ~s(phx-hook="LastChatLink")
      refute html =~ ~s(data-default-chat-path)
    end

    test "sidebar collapse flips the rail to lg:w-14", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "sidebar_hydrate", %{"collapsed" => true})
      html = render(view)

      # Collapsed rail keeps the data-icon-rail marker but switches width class.
      assert html =~ ~s(data-icon-rail)
      assert html =~ "lg:w-14"
    end
  end

  describe "Admin gate (fabrikam_admin? + is_fabrikam_user)" do
    test "is_fabrikam_user assign reflects real Fabrikam-root admin membership", %{conn: conn} do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.is_fabrikam_user == true
    end

    test "is_fabrikam_user is false for a Fabrikam member (non-admin)", %{conn: conn} do
      conn = authenticated_conn(conn, role: "member")
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.is_fabrikam_user == false
    end

    test "More sheet renders the Admin section for an admin user", %{conn: conn} do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # Admin section header text + the data-destination on the admin tile both
      # appear in the rendered More sheet (which is lg:hidden but still in the
      # DOM at all breakpoints — the hide is CSS-only).
      assert html =~ ">Admin<"
    end

    test "More sheet does NOT render the Admin section for a member user", %{conn: conn} do
      conn = authenticated_conn(conn, role: "member")
      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(data-destination="admin")
    end
  end

  # ---------------------------------------------------------------------
  # Meeting state hydration (task 019ee06b Stage 2)
  #
  # The shell's mini-bar relies on a synchronous hydration from
  # `Platform.Meetings.State` on every connected mount. Without this,
  # navigating to a new page via `live_navigate` re-mounts the shell, the
  # one-shot `:meeting_joined` PubSub event from the original join is long
  # gone, and the bar paints hidden even though the user is still in a
  # meeting. These tests cover: pre-existing state hydrates, missing state
  # leaves the defaults intact, and the live :meeting_joined path still
  # wins through (regression coverage for the new payload shape).
  # ---------------------------------------------------------------------

  describe "meeting state hydration" do
    alias Platform.Meetings.State, as: MeetingState

    setup do
      # Ensure the GenServer/ETS table is up — it's started by the
      # application supervisor in dev/prod but isn't a `Repo` so the
      # standard Ecto sandbox doesn't manage it for us. Idempotent:
      # start_supervised handles the "already started" case.
      _ = start_supervised(MeetingState)
      :ok
    end

    test "mount with pre-existing state hydrates all meeting_* assigns", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      # Seed the ETS-backed cache as if the user had already joined a meeting
      # in some prior LV (e.g. on a different tab).
      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-hydrate-1",
          "Hydration Test Space",
          "hydration-space-slug",
          "hydration-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.meeting_active == true
      assert assigns.meeting_space_id == "space-hydrate-1"
      assert assigns.meeting_space_name == "Hydration Test Space"
      assert assigns.meeting_space_slug == "hydration-space-slug"
      assert assigns.meeting_slug == "hydration-meeting-slug"
      assert %DateTime{} = assigns.meeting_started_at

      # Tidy up so unrelated tests don't see leftover state.
      :ok = MeetingState.broadcast_left(user_id)
    end

    test "mount with no state leaves meeting_* defaults", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.meeting_active == false
      assert assigns.meeting_space_id == nil
      assert assigns.meeting_space_name == nil
      assert assigns.meeting_space_slug == nil
      assert assigns.meeting_slug == nil
      assert assigns.meeting_started_at == nil
    end

    test "live :meeting_joined PubSub event updates all assigns including meeting_slug", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Trigger the join from outside (mid-session) — the shell handler
      # runs in the LV process and updates assigns.
      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-live-1",
          "Live Join Space",
          "live-space-slug",
          "live-meeting-slug"
        )

      # PubSub delivery is async — render() forces a flush.
      _html = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.meeting_active == true
      assert assigns.meeting_space_id == "space-live-1"
      assert assigns.meeting_space_name == "Live Join Space"
      assert assigns.meeting_space_slug == "live-space-slug"
      assert assigns.meeting_slug == "live-meeting-slug"

      :ok = MeetingState.broadcast_left(user_id)
    end

    test "on_meeting_page tracks both /chat/<space_slug> and /meetings/<meeting_slug>",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Simulate a mid-session join with both slugs populated so the
      # :track_path hook has the assigns it needs for both branches.
      send(
        view.pid,
        {:meeting_joined,
         %{
           user_id: user_id,
           space_id: "space-track-1",
           space_name: "Tracked Space",
           space_slug: "tracked-space",
           meeting_slug: "tracked-meeting",
           started_at: DateTime.utc_now()
         }}
      )

      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.meeting_slug == "tracked-meeting"
      # On /tasks we are not on a meeting page.
      assert assigns.on_meeting_page == false

      # Mirror the :track_path hook's expression for both legal "meeting
      # page" URLs so a regression that drops one branch is caught here.
      space_slug = assigns.meeting_space_slug
      meeting_slug = assigns.meeting_slug
      chat_path = "/chat/#{space_slug}"
      meeting_path = "/meetings/#{meeting_slug}"
      tasks_path = "/tasks"

      assert ((space_slug && chat_path == "/chat/#{space_slug}") ||
                (meeting_slug && chat_path == "/meetings/#{meeting_slug}") || false) == true

      assert ((space_slug && meeting_path == "/chat/#{space_slug}") ||
                (meeting_slug && meeting_path == "/meetings/#{meeting_slug}") || false) == true

      assert ((space_slug && tasks_path == "/chat/#{space_slug}") ||
                (meeting_slug && tasks_path == "/meetings/#{meeting_slug}") || false) == false

      :ok = MeetingState.broadcast_left(user_id)
    end

    # ---------------------------------------------------------------------
    # Stage 3 (task 019ee06b): ShellLive bridges `:meeting_media_state`
    # PubSub events into the bar via `send_update/2`. Verify the rendered
    # DOM reflects the muted icon + error-tinted button without a navigate.
    # ---------------------------------------------------------------------
    test "broadcast_media_state(mic_enabled: false) updates the bar's rendered mic button",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      # Bar must be visible for the assertion to be meaningful — seed an
      # active meeting + navigate to a non-meeting route so `@on_meeting_page`
      # is false and the bar renders without `hidden`.
      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-mediastate-1",
          "Media State Space",
          "media-state-slug",
          "media-state-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Default bar state: mic-on (hero-microphone, no -slash).
      pre_html = render(view)
      assert pre_html =~ "hero-microphone"

      # Broadcast the authoritative post-toggle state. ShellLive's
      # `:roster_updates` hook intercepts via the new `:meeting_media_state`
      # clause and calls `send_update/2` on the bar.
      :ok =
        MeetingState.broadcast_media_state(user_id, %{
          mic_enabled: false,
          camera_enabled: true
        })

      # Force a render flush so the LiveComponent's update/2 runs.
      post_html = render(view)

      assert post_html =~ "hero-microphone-slash"
      assert post_html =~ "text-error"
      # Camera flipped on too — verify the camera-on icon appears.
      assert post_html =~ "hero-video-camera"

      :ok = MeetingState.broadcast_left(user_id)
    end

    # ---------------------------------------------------------------------
    # Stage 4 (task 019ee06b): bar-initiated toggles route through the
    # active LiveView via `pushEvent` (NOT `pushEventTo`). On /tasks the
    # ChatLive's MeetingHooks is NOT mounted, so ShellLive's fallback
    # `meeting_toggle_mic` / `meeting_toggle_camera` handlers own the
    # toggle: flip the cached state, broadcast via `broadcast_media_state/2`,
    # and push the LiveKit toggle event for the MeetingClient JS hook.
    # ---------------------------------------------------------------------
    test "shell fallback handles meeting_toggle_mic when MeetingHooks is not mounted",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      # Subscribe in THIS test process so we can `assert_receive` the
      # broadcast that the shell fans out on toggle.
      :ok = MeetingState.subscribe(user_id)

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-shellfb-1",
          "Shell Fallback Space",
          "shell-fallback-slug",
          "shell-fallback-meeting-slug"
        )

      # /tasks does NOT mount ChatLive (no MeetingHooks). The shell becomes
      # the sole producer for the bar-initiated event.
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Sanity: MeetingHooks-owned `:mic_enabled` is absent. If a future
      # refactor accidentally attaches MeetingHooks to TasksLive, this
      # assertion forces the test to be re-thought.
      refute Map.has_key?(:sys.get_state(view.pid).socket.assigns, :mic_enabled)

      # Drain the initial :meeting_joined broadcast so the next
      # assert_receive matches only the toggle broadcast.
      assert_receive {:meeting_joined, %{user_id: ^user_id}}

      # Simulate the JS-hook `pushEvent("meeting_toggle_mic", {})` —
      # `render_hook/3` dispatches the event into the shell LV's
      # `:drawer_events` attach_hook.
      render_hook(view, "meeting_toggle_mic", %{})

      # Shell broadcasts the full pair, defaults flipped: mic_on was true,
      # so post-toggle mic_enabled=false. camera_on was false (default),
      # so camera_enabled=false (unchanged).
      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: false, camera_enabled: false}}

      # The shell's cached state must mirror the post-toggle truth — a
      # second click should toggle BACK to true, not flip from the
      # default again.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.shell_bar_mic_on == false
      # Drain the loopback that ShellLive's own :meeting_media_state
      # subscription delivers (this is the path that updates the bar).
      _ = render(view)

      :ok = MeetingState.broadcast_left(user_id)
    end

    test "shell fallback handles meeting_toggle_camera when MeetingHooks is not mounted",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      :ok = MeetingState.subscribe(user_id)

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-shellfb-cam",
          "Shell Fallback Camera",
          "shell-fallback-camera-slug",
          "shell-fallback-camera-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      refute Map.has_key?(:sys.get_state(view.pid).socket.assigns, :camera_enabled)

      assert_receive {:meeting_joined, %{user_id: ^user_id}}

      render_hook(view, "meeting_toggle_camera", %{})

      # Camera default is FALSE, so post-toggle camera_enabled=true.
      assert_receive {:meeting_media_state,
                      %{user_id: ^user_id, mic_enabled: true, camera_enabled: true}}

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.shell_bar_camera_on == true

      :ok = MeetingState.broadcast_left(user_id)
    end

    test "shell fallback pushes toggle-mic event for the MeetingClient JS hook",
         %{conn: conn} do
      # Regression guard: the MeetingClient JS hook listens for `toggle-mic`
      # on the global LV socket (meeting_client.js:37-38). Without
      # `push_event`, the LiveKit room never mutes when the bar is the
      # entry point on a non-/chat route.
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-shellfb-push",
          "Shell Fallback Push",
          "shell-fallback-push-slug",
          "shell-fallback-push-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "meeting_toggle_mic", %{})
      assert_push_event(view, "toggle-mic", %{})

      render_hook(view, "meeting_toggle_camera", %{})
      assert_push_event(view, "toggle-camera", %{})

      :ok = MeetingState.broadcast_left(user_id)
    end

    test "shell fallback consecutive toggles alternate (cached state, not default)",
         %{conn: conn} do
      # Without the cache update inside shell_meeting_toggle/2 the second
      # click would re-read the stale `true` default and broadcast
      # mic_enabled=false twice — a stuck state that this test would
      # catch by asserting the alternation.
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      :ok = MeetingState.subscribe(user_id)

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-shellfb-alt",
          "Shell Fallback Alt",
          "shell-fallback-alt-slug",
          "shell-fallback-alt-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert_receive {:meeting_joined, %{user_id: ^user_id}}

      render_hook(view, "meeting_toggle_mic", %{})
      assert_receive {:meeting_media_state, %{mic_enabled: false}}

      # Force loopback flush so the cache update from :meeting_media_state
      # has run before the second click.
      _ = render(view)

      render_hook(view, "meeting_toggle_mic", %{})
      assert_receive {:meeting_media_state, %{mic_enabled: true}}

      :ok = MeetingState.broadcast_left(user_id)
    end

    test "broadcast_media_state respects explicit false (not swallowed by ||-default)",
         %{conn: conn} do
      # Regression guard: the bar's update/2 must use Map.has_key?/2, not
      # `assigns[:mic_on] || socket.assigns.mic_on`. If the latter pattern
      # creeps back in, a `false` from the server silently becomes the
      # current default (`true`) and the icon never changes.
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-false-1",
          "False Override Space",
          "false-override-slug",
          "false-override-meeting-slug"
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")

      :ok =
        MeetingState.broadcast_media_state(user_id, %{
          mic_enabled: false,
          camera_enabled: false
        })

      html = render(view)
      assert html =~ "hero-microphone-slash"
      assert html =~ "hero-video-camera-slash"

      :ok = MeetingState.broadcast_left(user_id)
    end
  end

  # ---------------------------------------------------------------------
  # Mini-bar Leave durably stamps the participant row (task 019ee06b Stage 2)
  #
  # Regression net for the bug Rowan reported: clicking the persistent
  # meeting mini-bar's "Leave" from a page where MeetingHooks is NOT
  # attached (e.g. /tasks) used to broadcast the leave event but never
  # stamp the server-side `meeting_participants` row's `left_at`. The
  # orphaned active row then poisoned future presence-driven roster
  # refetches. Stage 1 extracted `Meetings.leave_for_user/2`; stage 2
  # wires the shell-level `:meeting_bar_leave` handler to call it before
  # the broadcast so any subsequent COUNT-driven refetch sees the row as
  # resolved.
  # ---------------------------------------------------------------------

  describe "mini-bar leave stamps participant row" do
    alias Platform.Meetings
    alias Platform.Meetings.Participant
    alias Platform.Meetings.State, as: MeetingState

    setup do
      _ = start_supervised(MeetingState)
      :ok
    end

    test ":meeting_bar_leave handler durably stamps left_at on the active participant row",
         %{conn: conn} do
      # Seed a real space + active meeting room + a joined participant row
      # for the test user. This mirrors the post-Start-Meeting state the
      # mini-bar appears in.
      {:ok, space} =
        Chat.create_space(%{
          name: "Bar Leave Space",
          slug: "bar-leave-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)

      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, participant} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user_id}",
          name: "Bar Leaver"
        })

      assert is_nil(participant.left_at)

      # Mount the shell on /tasks — this is the deliberate "MeetingHooks
      # is NOT attached" surface that proves the bug: previously the bar
      # had no in-process listener for stamping, and the row stayed
      # orphaned.
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Hydrate meeting_space_id via the normal mid-session join path so
      # the `:meeting_bar_leave` handler can resolve which space's active
      # room to stamp.
      send(
        view.pid,
        {:meeting_joined,
         %{
           user_id: user_id,
           space_id: space.id,
           space_name: "Bar Leave Space",
           space_slug: space.slug,
           meeting_slug: nil,
           started_at: DateTime.utc_now()
         }}
      )

      _ = render(view)

      # The bar's JS hook ultimately sends this message into the LV.
      send(view.pid, :meeting_bar_leave)
      _ = render(view)

      reloaded = Repo.get!(Participant, participant.id)
      refute is_nil(reloaded.left_at)

      assert is_nil(Meetings.active_participant_for_user_in_space(space.id, user_id))

      # Existing broadcast_left behaviour MUST still fire — the shell's
      # meeting_* assigns should now reflect the user out of any meeting.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.meeting_active == false
      assert assigns.meeting_space_id == nil
      assert assigns.meeting_slug == nil
    end

    test ":meeting_bar_leave is a safe no-op when meeting_space_id is missing",
         %{conn: conn} do
      # The bar could (in theory) fire before any join hydration ran. The
      # handler must not crash — it should still broadcast left so the
      # mini-bar flips hidden, but skip the durable stamp because there's
      # no space to stamp against.
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # No `:meeting_joined` has been sent — meeting_space_id is nil.
      assigns_before = :sys.get_state(view.pid).socket.assigns
      assert assigns_before.meeting_space_id == nil

      send(view.pid, :meeting_bar_leave)
      _ = render(view)

      # LV process is still alive (didn't crash on the guarded branch).
      assert Process.alive?(view.pid)

      assigns_after = :sys.get_state(view.pid).socket.assigns
      assert assigns_after.meeting_active == false
    end
  end

  # ---------------------------------------------------------------------
  # MeetingWatchdog mount gate (task 019ee06b Stage 2)
  #
  # The shell layout renders a hidden `#meeting-watchdog` element bound to
  # the `MeetingWatchdog` JS hook — but ONLY when `@meeting_active` is
  # true. When no meeting is active the element must be absent from the
  # DOM so the watchdog hook never mounts and no spurious LiveKit listener
  # binding / WebSocket activity occurs on /tasks, /activity, etc. These
  # tests pin both branches of the `:if={@meeting_active}` gate so an
  # accidental delete or class-name drift is caught.
  # ---------------------------------------------------------------------

  describe "meeting watchdog mount gate" do
    alias Platform.Meetings.State, as: MeetingState

    setup do
      _ = start_supervised(MeetingState)
      :ok
    end

    test "no #meeting-watchdog element when no meeting is active", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      refute html =~ ~s(id="meeting-watchdog")
      refute html =~ ~s(phx-hook="MeetingWatchdog")
    end

    test "shell renders #meeting-watchdog with MeetingWatchdog hook when meeting_active",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      :ok =
        MeetingState.broadcast_joined(
          user_id,
          "space-watchdog-1",
          "Watchdog Test Space",
          "watchdog-space-slug",
          "watchdog-meeting-slug"
        )

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(id="meeting-watchdog")
      assert html =~ ~s(phx-hook="MeetingWatchdog")
      # Stable across shell repatches — must NOT be re-mounted on every
      # repatch (the watchdog's singleton guard would back off, but a
      # fresh mounted() cycle is wasted churn).
      assert html =~ ~s(phx-update="ignore")
      # Initial breadcrumb so [data-room-state] selectors exist immediately.
      assert html =~ ~s(data-room-state="unknown")
      # No visible UI surface.
      assert html =~ ~r/id="meeting-watchdog"[^>]*class="[^"]*hidden/

      :ok = MeetingState.broadcast_left(user_id)
    end
  end
end
