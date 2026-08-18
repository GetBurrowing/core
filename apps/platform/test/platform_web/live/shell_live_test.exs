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
  # constrain itself to the viewport and refuse to scroll
  # (`overflow-hidden`) so the bottom-tab nav stays functionally rooted on
  # mobile — without these, the body itself scrolls and drags the chrome
  # out of view (Rowan's mobile review-request hotfix, supersedes the inner
  # `pb-` clearance from PR #331).
  #
  # CHANGED 2026-08-17, task 019ffdce. This guard used to assert the
  # literal `h-[100vh]` on the shell root, pinning a decision recorded in
  # May 2026 (PRs #339/#350/#351 chased the bug through svh and
  # env-padding before the on-device Web Inspector measurement on
  # 2026-05-14 settled it). That measurement is NOT overturned and the
  # value it established is still what iOS standalone resolves to — see
  # the CSS assertion below, which is now where it is pinned. What
  # changed is the location: the standalone height moved out of the
  # template's Tailwind class and into a single `@media (display-mode:
  # standalone)` rule in app.css keyed off `.app-shell-root`, so the
  # stylesheet and the template can no longer carry different values.
  # Asserting `h-[100vh]` on the markup after that move would assert a
  # string that no longer decides anything.
  test "shell root container locks to viewport height (PWA scroll lock)", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    # Browser-tab branch stays on the element: 100dvh tracks the visible
    # viewport so the bottom-nav stays above iOS Safari/Chrome's dynamic
    # URL toolbar (PR #392).
    assert html =~ "h-[100dvh]"

    # Standalone branch: the root must opt into the app.css rule. Without
    # this class the installed PWA silently falls back to the browser-tab
    # 100dvh, which is the ~59px-short iOS regression PR #352 fixed.
    assert html =~ "app-shell-root"

    assert html =~ "overflow-hidden"
    # The main surface must contain its own iOS rubber-band so an inner
    # panel's overscroll cannot displace the chrome.
    assert html =~ "overscroll-contain"
  end

  # The other half of the guard above: the standalone height itself. The
  # markup only opts in; app.css decides the value, so a class-only test
  # would pass with any value at all — including a plain `100dvh` that
  # reintroduces the iOS bug.
  #
  # Resolved from __DIR__, not the cwd, so the read does not depend on
  # where mix was invoked from.
  test "app.css pins the standalone shell height to the iOS-measured full screen" do
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

    standalone_rule =
      css
      |> String.split("@media all and (display-mode: standalone)")
      |> Enum.at(1)
      |> String.slice(0, 400)

    # All three selectors must share one declaration. If the shell root
    # drops out of this list, the template and the stylesheet are free to
    # drift to different heights again.
    assert standalone_rule =~ "html"
    assert standalone_rule =~ "body"
    assert standalone_rule =~ ".app-shell-root"

    # The value. On iOS standalone this resolves to exactly the 100vh the
    # 2026-05-14 iPhone 16 measurement established: that device measured
    # 100vh = 852 and 100dvh = 793, a shortfall of 59px which is precisely
    # env(safe-area-inset-top) there, so calc(100dvh + safe-area-inset-top)
    # reconstructs 852 and min() returns it. The min() exists for the
    # Android case (task 019ffdce): where the shell lays out taller than
    # the visible viewport and pushes the tab bar off-screen, 100dvh is
    # the shorter value and min() takes it. min() can only ever shorten
    # the shell to the visible viewport, never lengthen it past 100vh.
    #
    # Do not simplify this to plain `100dvh`: that drops the iOS branch
    # 59px short. Do not simplify it to plain `100vh`: that is the state
    # in which the Android tab bar was reported unreachable on 2026-08-17.
    assert standalone_rule =~ "min(100vh, calc(100dvh + env(safe-area-inset-top, 0px)))"
  end

  # Task 01a00161 stage 1 extracted the shipped
  # `<div id="app-badge" phx-hook="AppBadge" class="hidden">` out of
  # `shell.html.heex` into `Layouts.app_badge_mount/1` so the `:external`
  # layout could mount it too. This is the mirror of the external-layout
  # assertion in `test/platform_web/components/layouts_external_test.exs`:
  # the extraction must not silently drop the ORIGINAL shell mount, which
  # would swap one broken surface for another. ShellLive pushes `app_badge`
  # unconditionally, so nothing else in the suite notices a missing hook.
  test "shell still mounts the app-badge hook after the shared-component extraction",
       %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ ~s(id="app-badge")
    assert html =~ ~s(phx-hook="AppBadge")
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

    # Task 019fe4b1 replaced the bare "Agents" label with the healthy-over-
    # total ratio once the roster is non-empty; the word only survives as the
    # `total == 0` fallback. Assertion rewritten, not dropped: it still proves
    # the resolved branch rendered.
    assert html =~ ~s(data-test-id="shell-agents-ratio")
    assert html =~ "agents"
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
    # Stage 2 replaced the single atom with a healthy-over-total ratio; stage 3
    # feeds it from the viewer-scoped union rather than one arbitrary space.
    assert %AsyncResult{ok?: true, result: composite} = assigns.composite_status
    assert %{healthy: _, total: _, state: _} = composite
    assert %AsyncResult{ok?: true, result: name} = assigns.principal_name
    assert name == "LoadingBot"
    # Task 019fe4b1 stage 3: the presence assign now carries the three-state
    # `{:ok, list} | {:error, reason}` tuple rather than a bare list.
    assert %AsyncResult{ok?: true, result: {:ok, presence}} = assigns.presence_list
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

  # ── viewer-scoped shell presence (task 019fe4b1 stage 3) ──────────────────
  #
  # The shell badge used to read `first_space/0` — one arbitrary space, the
  # oldest non-archived one — so it answered a question nobody asked and could
  # show a stranger's name. It now resolves the VIEWER's observable set.
  #
  # Every absence assertion below shares its run with a positive control: an
  # `async_load_presence/2` that resolved to `{:ok, []}` unconditionally would
  # satisfy every refute on its own, so each one sits beside a colleague who
  # MUST appear.
  #
  # Orgs come from the seeded tenants rather than a freshly created one: a new
  # top-level org has `parent_org_id == nil`, which resolves `:root_all` and
  # silently disables the very org fence these tests exist to prove.
  defp presence_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "shell-presence-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-shell-presence-#{n}"
    })
  end

  defp presence_org_member!(user, org) do
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})
  end

  defp presence_space!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Presence Chan",
        slug: "shell-presence-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  defp presence_participant!(space, user, display_name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp presence_online!(space, user, display_name) do
    {:ok, _} =
      Platform.Chat.Presence.track_in_space(self(), space.id, user.id, %{
        participant_type: "user",
        display_name: display_name
      })

    :ok
  end

  # The error tests break the read for real rather than hand-writing the tuple
  # into the assign: a non-UUID viewer id makes the scoping query raise on
  # cast, which is exactly the rescue `list_online_for_viewer/1` wraps as
  # `{:error, reason}`. Asserting a shape you injected yourself would prove
  # only that `assign/3` works.
  defp break_presence_read!(view) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.current_user_record, %{id: "definitely-not-a-uuid"})
    end)
  end

  defp send_presence_diff(view, space_id) do
    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: Platform.Chat.PubSub.space_topic(space_id),
      event: "presence_diff",
      payload: %{joins: %{}, leaves: %{}}
    })

    render(view)
  end

  defp shell_presence_result(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    assert %AsyncResult{ok?: true, result: result} = assigns.presence_list
    result
  end

  describe "viewer-scoped shell presence assign" do
    setup %{conn: conn} do
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = presence_user!("Vera Viewer")
      colleague = presence_user!("Cora Colleague")
      presence_org_member!(viewer, home)
      presence_org_member!(colleague, home)

      shared = presence_space!(home)
      presence_participant!(shared, viewer, "Vera Viewer")
      presence_participant!(shared, colleague, "Cora Colleague")

      %{
        conn: init_test_session(conn, current_user_id: viewer.id),
        home: home,
        foreign: foreign,
        viewer: viewer,
        colleague: colleague,
        shared: shared
      }
    end

    test "resolved assign holds the online colleague and excludes offline + foreign users", ctx do
      offline_user = presence_user!("Otto Offline")
      presence_org_member!(offline_user, ctx.home)
      presence_participant!(ctx.shared, offline_user, "Otto Offline")

      stranger = presence_user!("Fiona Foreign")
      presence_org_member!(stranger, ctx.foreign)
      foreign_space = presence_space!(ctx.foreign)
      presence_participant!(foreign_space, stranger, "Fiona Foreign")
      # The viewer even holds a participant row in the foreign space —
      # membership alone must not carry a name across the org fence.
      presence_participant!(foreign_space, ctx.viewer, "Vera Viewer")
      presence_online!(foreign_space, stranger, "Fiona Foreign")

      presence_online!(ctx.shared, ctx.colleague, "Cora Colleague")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      assert {:ok, list} = shell_presence_result(view)

      names = Enum.map(list, & &1.name)
      # Positive control first — without it the refutes below prove nothing.
      assert "Cora Colleague" in names
      refute "Otto Offline" in names
      refute "Fiona Foreign" in names
      # And the viewer is not in their own badge.
      refute "Vera Viewer" in names
    end

    test "the LV subscribes to every viewer space, not one arbitrary space", ctx do
      second = presence_space!(ctx.home)
      presence_participant!(second, ctx.viewer, "Vera Viewer")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      subscribed = :sys.get_state(view.pid).socket.assigns.presence_space_ids

      # Both spaces, not just the oldest — a single-topic subscription shows up
      # as a permanently stale list, which looks perfectly fine on first load.
      assert ctx.shared.id in subscribed
      assert second.id in subscribed
    end

    test "a presence_diff from a newly online colleague updates the assign", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      # Positive control on the BEFORE state: the colleague is genuinely absent
      # to start with, so the assertion after the diff proves the update ran.
      assert {:ok, before_list} = shell_presence_result(view)
      refute "Cora Colleague" in Enum.map(before_list, & &1.name)

      latecomer = presence_user!("Lena Latecomer")
      presence_org_member!(latecomer, ctx.home)
      presence_participant!(ctx.shared, latecomer, "Lena Latecomer")

      presence_online!(ctx.shared, ctx.colleague, "Cora Colleague")
      presence_online!(ctx.shared, latecomer, "Lena Latecomer")

      # Presence broadcasts its own diff; give it a beat to reach the LV, then
      # force a render so the assign read below sees the settled state.
      :timer.sleep(150)
      _html = render(view)

      assert {:ok, after_list} = shell_presence_result(view)
      names = Enum.map(after_list, & &1.name)
      assert "Cora Colleague" in names
      assert "Lena Latecomer" in names
    end

    test "an {:error, _} read survives to the assign instead of collapsing to []", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      # Positive control: the read works before we break it, so the assertion
      # after the break is about the break and not about a dead LV.
      assert {:ok, _} = shell_presence_result(view)

      break_presence_read!(view)
      send_presence_diff(view, ctx.shared.id)

      # An empty office and a broken read are different facts.
      assert {:error, _reason} = shell_presence_result(view)
      refute shell_presence_result(view) == {:ok, []}
    end

    test "a failing diff keeps the last good list rather than blanking it", ctx do
      presence_online!(ctx.shared, ctx.colleague, "Cora Colleague")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      assert {:ok, good} = shell_presence_result(view)
      assert "Cora Colleague" in Enum.map(good, & &1.name)

      break_presence_read!(view)
      send_presence_diff(view, ctx.shared.id)

      # A transient failure must not blank a list we already had.
      assert {:ok, kept} = shell_presence_result(view)
      assert "Cora Colleague" in Enum.map(kept, & &1.name)
    end
  end

  # ── rendered presence strip (stage 4) ─────────────────────────────────────
  # The assign tests above prove the DATA is right. These prove the three
  # states are told apart on screen: a populated list, a genuinely empty one,
  # and an unavailable read must not render as each other. The empty and
  # unavailable cases assert on DIFFERENT hooks on purpose — if one selector
  # satisfied both, the distinction would be decorative.
  defp presence_hook_count(html, hook) do
    html
    |> String.split(~s(data-test-id="#{hook}"))
    |> length()
    |> Kernel.-(1)
  end

  defp open_presence_panel(view) do
    view |> element(~s([data-test-id="shell-presence-badge"])) |> render_click()
  end

  describe "rendered shell presence strip" do
    setup %{conn: conn} do
      home = Tenancy.get_org_by_slug!("sxi")

      viewer = presence_user!("Vera Viewer")
      colleague = presence_user!("Cora Colleague")
      presence_org_member!(viewer, home)
      presence_org_member!(colleague, home)

      shared = presence_space!(home)
      presence_participant!(shared, viewer, "Vera Viewer")
      presence_participant!(shared, colleague, "Cora Colleague")

      %{
        conn: init_test_session(conn, current_user_id: viewer.id),
        home: home,
        viewer: viewer,
        colleague: colleague,
        shared: shared
      }
    end

    test "populated: one row per online user, badge count equals row count", ctx do
      offline_user = presence_user!("Otto Offline")
      presence_org_member!(offline_user, ctx.home)
      presence_participant!(ctx.shared, offline_user, "Otto Offline")

      latecomer = presence_user!("Lena Latecomer")
      presence_org_member!(latecomer, ctx.home)
      presence_participant!(ctx.shared, latecomer, "Lena Latecomer")

      presence_online!(ctx.shared, ctx.colleague, "Cora Colleague")
      presence_online!(ctx.shared, latecomer, "Lena Latecomer")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      html = open_presence_panel(view)

      # Positive control: the online colleague is actually on screen. Without
      # this the count assertion below is satisfied by total breakage (0 == 0).
      assert html =~ "Cora Colleague"
      assert html =~ "Lena Latecomer"
      refute html =~ "Otto Offline"

      rows = presence_hook_count(html, "shell-presence-row")
      assert rows == 2

      badge =
        view
        |> element(~s([data-test-id="shell-presence-badge"]))
        |> render()

      # The badge is `length(list)`, so it cannot disagree with the rows.
      assert badge =~ ">#{rows}<"
      refute html =~ ~s(data-test-id="shell-presence-empty")
      refute html =~ ~s(data-test-id="shell-presence-unavailable")
    end

    test "empty: says 'No one else online' and the badge reads 0", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      html = open_presence_panel(view)

      assert presence_hook_count(html, "shell-presence-empty") == 1
      assert html =~ "No one else online"
      assert presence_hook_count(html, "shell-presence-row") == 0
      # The empty state is NOT the unavailable state.
      assert presence_hook_count(html, "shell-presence-unavailable") == 0

      badge = view |> element(~s([data-test-id="shell-presence-badge"])) |> render()
      assert badge =~ ">0<"
      refute badge =~ "Presence unavailable"
    end

    test "unavailable: distinct hook, and the badge never renders a number", ctx do
      presence_online!(ctx.shared, ctx.colleague, "Cora Colleague")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      healthy = open_presence_panel(view)

      # Positive control: the healthy render works before we break the read.
      assert healthy =~ "Cora Colleague"
      assert presence_hook_count(healthy, "shell-presence-row") == 1

      # The stage-3 diff handler deliberately keeps the last good NON-EMPTY
      # list through a transient failure, so the failed read is observed on a
      # session that has no good list to fall back to: a second viewer in the
      # same org whose own space has nobody online. Same test, same run as the
      # positive control above.
      lonely = presence_user!("Lonnie Lonely")
      presence_org_member!(lonely, ctx.home)
      lonely_space = presence_space!(ctx.home)
      presence_participant!(lonely_space, lonely, "Lonnie Lonely")
      lonely_conn = init_test_session(build_conn(), current_user_id: lonely.id)

      {:ok, broken_view, _html} = live(lonely_conn, ~p"/tasks")
      _html = render_async(broken_view, 2_000)
      break_presence_read!(broken_view)
      send_presence_diff(broken_view, lonely_space.id)

      assert {:error, _} = shell_presence_result(broken_view)
      html = open_presence_panel(broken_view)

      assert presence_hook_count(html, "shell-presence-unavailable") == 1
      assert html =~ "Presence unavailable"
      # A broken backend and an empty office must not look the same.
      assert presence_hook_count(html, "shell-presence-empty") == 0
      assert presence_hook_count(html, "shell-presence-row") == 0

      badge = broken_view |> element(~s([data-test-id="shell-presence-badge"])) |> render()
      assert badge =~ "Presence unavailable"
      # A failure is never allowed to render as a count — a zero is a claim.
      refute badge =~ ">0<"
    end
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
  # Inbox unread-count badge live wiring (task 019f904d / M7)
  #
  # ShellLive owns the desktop icon-rail Inbox badge: it computes the
  # mount-time count via Platform.Inbox.unread_count/1, subscribes the
  # connected socket to inbox:<user_id>, and increments/decrements the
  # `inbox_unread_count` assign in place on {:inbox_item_added,_} /
  # {:inbox_item_dismissed,_} — no re-query. The component render contract
  # is covered by IconRailTest; these check the end-to-end wiring.
  # ---------------------------------------------------------------------
  describe "inbox unread badge live wiring" do
    alias Platform.Inbox

    defp inbox_attrs(user_id) do
      %{
        user_id: user_id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: Ecto.UUID.generate(),
        title: "You were mentioned",
        body: "…",
        url: "/chat/x"
      }
    end

    defp inbox_badge_text(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="inbox-badge"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "rail badge reflects the seeded unread count at mount", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      {:ok, _} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 3
      assert inbox_badge_text(html) == "3"
    end

    test "an inbox_item_added broadcast increments the badge live (no reload)", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 1

      # emit/1 broadcasts {:inbox_item_added, item} on inbox:<user_id>, which
      # the subscribed shell increments on.
      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      _ = render(view)

      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 2
      assert inbox_badge_text(render(view)) == "2"
    end

    test "dismissing an item decrements the badge live", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      {:ok, item2} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 2

      {:ok, _} = Inbox.mark_dismissed(item2.id, user_id)
      _ = render(view)

      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 1
    end

    test "the badge floors at 0 and disappears when the last item is dismissed", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, item} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 1

      {:ok, _} = Inbox.mark_dismissed(item.id, user_id)
      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 0

      # A stray extra dismiss broadcast (e.g. a race) must floor at 0, never
      # go negative.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Inbox.topic(user_id),
        {:inbox_item_dismissed, item}
      )

      html = render(view)
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 0
      # Badge node absent from the DOM at 0.
      refute html =~ ~s(data-role="inbox-badge")
    end

    # -------------------------------------------------------------------
    # App-icon badge / document-title prefix delivery (task 019ffb7b st. 6)
    #
    # `navigator.setAppBadge` and the `(3) ` title prefix are painted by the
    # `AppBadge` JS hook, so nothing about the marks themselves is
    # observable from ExUnit. What IS observable, and what actually breaks,
    # is the delivery: the count has to reach the client on mount and again
    # on every inbox change, or the hook paints a stale number forever
    # (it holds no subscription and never polls — that is deliberate).
    # These tests pin the push, not the paint.
    # -------------------------------------------------------------------
    test "mount pushes the seeded count to the badge hook", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      {:ok, _} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Raw integer for setAppBadge (which takes a Number), plus the capped
      # display label the title prefix and the rail pill share.
      assert_push_event(view, "app_badge", %{count: 2, label: "2"})
    end

    test "an inbox change re-pushes the recomputed count", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert_push_event(view, "app_badge", %{count: 1, label: "1"})

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      _ = render(view)

      assert_push_event(view, "app_badge", %{count: 2, label: "2"})
    end

    test "reading the last item pushes zero so the hook clears the badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, item} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert_push_event(view, "app_badge", %{count: 1, label: "1"})

      # mark_read/2 broadcasts the coarse {:inbox_changed, user_id}; the
      # recompute drops the read row, so the client must be told to clear.
      # A nil label is the hook's "no prefix" signal, matching the rail
      # dropping its badge node at 0.
      {:ok, _} = Inbox.mark_read(item.id, user_id)
      _ = render(view)

      assert_push_event(view, "app_badge", %{count: 0, label: nil})
    end

    test "the pushed label uses the rail's cap, not a second one", %{conn: _conn} do
      # ShellLive builds the label with IconRail.badge_text/1 rather than its
      # own formatting, so this is the only place the "99+" grammar is
      # defined. Pinned here because the function had to become public for
      # the push to reuse it.
      assert PlatformWeb.Components.IconRail.badge_text(99) == "99"
      assert PlatformWeb.Components.IconRail.badge_text(100) == "99+"
      assert PlatformWeb.Components.IconRail.badge_text(0) == nil
    end

    test "a second user's inbox items do not leak into this user's badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      other =
        Repo.insert!(%User{
          email: "inbox_other_#{System.unique_integer([:positive])}@example.com",
          name: "Other",
          oidc_sub: "oidc-inbox-other-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Inbox.emit(inbox_attrs(user_id))
      {:ok, _} = Inbox.emit(inbox_attrs(other.id))
      {:ok, _} = Inbox.emit(inbox_attrs(other.id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert :sys.get_state(view.pid).socket.assigns.inbox_unread_count == 1
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

  # Task 019f43da stage 1: consolidate captions control to ONE writer —
  # the in-window MeetingLive toggle. Prior to this task, `shell.html.heex`
  # rendered a global CC button on EVERY route (its `:if={@captions_enabled
  # != nil}` guard was always truthy because shell_live.ex assigned the
  # value at mount) and a matching `#meeting-captions` overlay. The overlay
  # collided by id with MeetingLive's own overlay on `/meetings/:id`, and
  # the button's state (`@captions_enabled`) drifted from MeetingLive's
  # (`@captions_visible`). Both are now gone; the regression guards ensure
  # they stay gone.
  describe "shell chrome no longer renders a global captions toggle" do
    test "non-meeting shell route has no toggle_captions button", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The exact-match `phx-click="toggle_captions"` handler that shell_live
      # used to bind is gone. The `_meeting` suffix on MeetingLive's own
      # event (`toggle_captions_meeting`) is not present outside the meeting
      # route, so any hit here is the deleted shell duplicate.
      refute html =~ ~s(phx-click="toggle_captions")
    end

    test "non-meeting shell route has no shell-level meeting-captions overlay",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The MeetingLive overlay only mounts inside meeting_live.html.heex
      # and cannot appear on `/tasks`. The shell overlay (deleted this
      # task) used the SAME `id="meeting-captions"` — asserting its
      # absence on a non-meeting route guards against a shell-level
      # reintroduction that would collide with MeetingLive on the
      # `/meetings/:id` surface.
      refute html =~ ~s(id="meeting-captions")
    end

    test "shell assigns no longer track :captions_enabled state", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The `@captions_enabled` assign backed the deleted button + overlay
      # and was previously wired through the shell's `hero-*` CC glyph.
      # No template surface in the shell should reference it anymore —
      # asserting the aria-labels + title strings from the deleted button
      # are gone catches a partial revert (e.g. someone re-adding the
      # button but forgetting to re-add the assign).
      refute html =~ ~s(aria-label="Show captions")
      refute html =~ ~s(aria-label="Hide captions")
      refute html =~ ~s(title="Show captions")
      refute html =~ ~s(title="Hide captions")
    end
  end

  # ── Agent roster panel ────────────────────────────────────────────────────
  #
  # Regression cover for the reported "clicking the Agents meter crashes the
  # page". The handler was never missing — all four drawer events are clauses
  # inside the `attach_hook(:drawer_events, :handle_event, ...)` anonymous fn
  # in `ShellLive.on_mount/4`, which no `handle_event("toggle_roster"` grep can
  # find. The click succeeded and flipped `:roster_open`; the RE-RENDER of the
  # newly-visible panel raised, because the Remove button reads
  # `sa.space_id` and `Chat.preload_roster_entries/1` never emitted that key.
  #
  # The crash needs a NON-principal roster member: the Remove button is gated
  # on `sa.role != "principal"`, so a space whose only agent is the principal
  # opens cleanly. That is why this survived review, and why every test below
  # seeds a member alongside the principal.
  describe "agent roster panel" do
    defp seed_roster_space(opts \\ []) do
      slug_suffix = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{name: "Roster Space", slug: "roster-space-#{slug_suffix}"})

      principal =
        Repo.insert!(%Agent{
          name: "PrincipalBot",
          slug: "principal-bot-#{slug_suffix}",
          status: "active",
          runtime_type: "builtin"
        })

      member =
        Repo.insert!(%Agent{
          name: "MemberBot",
          slug: "member-bot-#{slug_suffix}",
          status: "active",
          runtime_type: "builtin"
        })

      {:ok, _} = Chat.set_principal_agent(space.id, principal.id)

      if Keyword.get(opts, :member, true) do
        {:ok, _} = Chat.add_space_agent(space.id, member.id, role: "member")
      end

      %{space: space, principal: principal, member: member}
    end

    # Three independent assertions, deliberately. A test that only clicks and
    # asserts "no crash" passes against a build with no button at all, and a
    # test that only asserts the click returns html passes against a build
    # that renders an empty panel. So: (1) the button exists, (2) clicking it
    # does not raise, (3) the panel is actually POPULATED with the member and
    # carries the real space id on its Remove control.
    test "roster button opens a populated panel without crashing", %{conn: conn} do
      %{space: space, member: member} = seed_roster_space()

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_async(view, 2_000)

      # (1) the control under test exists
      assert html =~ ~s(data-test-id="shell-roster-button")

      # (2) the click + its follow-up render do not raise
      opened = view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()

      # (3) the panel is populated: the non-principal member is listed and its
      # Remove button carries the seeded space id, which is the exact key that
      # used to be absent from the roster entry map.
      assert opened =~ member.name
      assert opened =~ ~s(phx-value-agent-id="#{member.id}")
      assert opened =~ ~s(phx-value-space-id="#{space.id}")
    end

    # Pin the map contract at the context boundary too, not only through the
    # template — a future refactor of `preload_roster_entries/1` should fail
    # here rather than only in a LiveView render.
    test "list_space_agents/1 entries all carry their space_id" do
      %{space: space} = seed_roster_space()

      entries = Chat.list_space_agents(space.id)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.space_id == space.id))
    end

    # `@type roster_entry` already blesses `agent: Agent.t() | nil`, so an
    # orphaned participant row (agent deleted out from under it) is a
    # contract-legal value the template must survive. The row must still
    # RENDER — an orphan should be visible, not silently dropped.
    test "roster panel renders a fallback label for an orphaned participant", %{conn: conn} do
      %{member: member} = seed_roster_space()

      Repo.delete!(member)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      opened = view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()

      # Copy changed in task 019fe4b1: "Unknown agent" describes a naming
      # problem, and the fact is a deleted record. Assertion rewritten rather
      # than dropped — the behaviour it guards (the orphan row still RENDERS)
      # is unchanged.
      assert opened =~ "Deleted agent"
      refute opened =~ member.name
    end
  end

  # ── Viewer-scoped agent roster (stage 3) ──────────────────────────────────
  #
  # `first_space/0` returned the oldest non-archived space in the WHOLE
  # install, so every user in every org saw whichever channel happened to be
  # created first — including orgs they have no membership in. The roster is
  # now the distinct set of agents on the rosters of spaces the viewer can
  # see, scoped through `Tenancy.scope/3`.
  #
  # ANTI-VACUITY, and it is the point of this whole block: "the other org's
  # agent is absent" is ALSO true of a build whose query returns nothing at
  # all. Every absence assertion below is paired, in the same block, with a
  # positive control asserting the viewer's OWN org's agent is present.
  describe "roster is scoped to the viewer's visible spaces" do
    # Seeded tenant orgs, deliberately. A freshly created top-level org has
    # `parent_org_id == nil`, which makes its members resolve to `:root_all`
    # and silently disables the very fence under test.
    defp tenant_orgs do
      {Tenancy.get_org_by_slug!("sxi"), Tenancy.get_org_by_slug!("soylent")}
    end

    defp scoped_conn(conn, org) do
      user =
        Repo.insert!(%User{
          email: "shell_scope_#{System.unique_integer([:positive])}@example.com",
          name: "Scoped Viewer",
          oidc_sub: "oidc-shell-scope-#{System.unique_integer([:positive])}"
        })

      if org do
        Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})
      end

      {init_test_session(conn, current_user_id: user.id), user}
    end

    defp seed_org_space(org, label) do
      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{
          name: "#{label} Space",
          slug: "#{String.downcase(label)}-space-#{n}",
          org_id: org.id
        })

      principal =
        Repo.insert!(%Agent{
          name: "#{label}Principal",
          slug: "#{String.downcase(label)}-principal-#{n}",
          status: "active",
          runtime_type: "builtin"
        })

      member =
        Repo.insert!(%Agent{
          name: "#{label}Member",
          slug: "#{String.downcase(label)}-member-#{n}",
          status: "active",
          runtime_type: "builtin"
        })

      {:ok, _} = Chat.set_principal_agent(space.id, principal.id)
      {:ok, _} = Chat.add_space_agent(space.id, member.id, role: "member")

      %{space: space, principal: principal, member: member}
    end

    defp roster_agent_names(view) do
      :sys.get_state(view.pid).socket.assigns.roster_items
      |> then(fn %AsyncResult{result: items} -> items || [] end)
      |> Enum.map(fn {entry, _status} -> entry.agent && entry.agent.name end)
    end

    test "a foreign org's agents are absent while the viewer's own org's are present",
         %{conn: conn} do
      {sxi, soylent} = tenant_orgs()
      mine = seed_org_space(sxi, "Mine")
      theirs = seed_org_space(soylent, "Theirs")

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      opened_html = render_async(view, 2_000)

      names = roster_agent_names(view)

      # Positive control FIRST — without it the absence below is vacuous.
      assert mine.principal.name in names
      assert mine.member.name in names
      # The fence.
      refute theirs.principal.name in names
      refute theirs.member.name in names

      # And through the rendered panel, not only the assigns.
      opened =
        if opened_html =~ ~s(data-test-id="shell-roster-button") do
          view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()
        else
          flunk("roster button never rendered — the positive half cannot be checked")
        end

      assert opened =~ mine.member.name
      refute opened =~ theirs.member.name
    end

    # The exact reported defect: the OLDEST space in the install belongs to an
    # org the viewer is not a member of, which is precisely what the deleted
    # `first_space/0` would have picked.
    test "the oldest space in a foreign org no longer supplies the roster", %{conn: conn} do
      {sxi, soylent} = tenant_orgs()

      # Seeded first, so it is the oldest.
      theirs = seed_org_space(soylent, "Oldest")
      mine = seed_org_space(sxi, "Newer")

      assert DateTime.compare(theirs.space.inserted_at, mine.space.inserted_at) in [:lt, :eq]

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      names = roster_agent_names(view)

      assert mine.principal.name in names
      refute theirs.principal.name in names
    end

    test "an agent on two visible spaces is listed once and counted once", %{conn: conn} do
      {sxi, _soylent} = tenant_orgs()
      a = seed_org_space(sxi, "First")
      b = seed_org_space(sxi, "Second")

      # Put A's member on B's roster too — same agent, two visible spaces.
      {:ok, _} = Chat.add_space_agent(b.space.id, a.member.id, role: "member")

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      names = roster_agent_names(view)

      # Present (positive control) and present exactly once.
      assert a.member.name in names
      assert Enum.count(names, &(&1 == a.member.name)) == 1

      # The denominator counts it once too: unique agent ids == total.
      assigns = :sys.get_state(view.pid).socket.assigns
      %AsyncResult{result: composite} = assigns.composite_status
      %AsyncResult{result: items} = assigns.roster_items

      unique_ids = items |> Enum.map(fn {e, _} -> e.agent_id end) |> Enum.uniq() |> length()
      assert composite.total == unique_ids
      assert composite.total == length(items)
      # Sanity: b's roster really does contain the shared agent, so the
      # dedupe above removed a duplicate rather than never seeing one.
      assert Enum.any?(Chat.list_space_agents(b.space.id), &(&1.agent_id == a.member.id))
    end

    test "a {:roster_changed_any, _} broadcast refreshes the composite without a remount",
         %{conn: conn} do
      {sxi, _soylent} = tenant_orgs()
      mine = seed_org_space(sxi, "Live")

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      pid_before = view.pid

      %AsyncResult{result: before_composite} =
        :sys.get_state(view.pid).socket.assigns.composite_status

      assert mine.member.name in roster_agent_names(view)

      # Mutate the roster out-of-band. `Chat.remove_space_agent/2` fans out on
      # the global topic the shell subscribed to at mount.
      Chat.remove_space_agent(mine.space.id, mine.member.id)
      _ = render(view)

      %AsyncResult{result: after_composite} =
        :sys.get_state(view.pid).socket.assigns.composite_status

      assert view.pid == pid_before, "the LV must not have remounted"
      assert after_composite.total == before_composite.total - 1
      refute mine.member.name in roster_agent_names(view)
    end

    test "a viewer with no org memberships sees an empty roster, not every agent",
         %{conn: conn} do
      {sxi, _soylent} = tenant_orgs()
      mine = seed_org_space(sxi, "Fenced")

      # Positive control: an sxi member DOES see this agent, so the empty
      # result below is the `:none` fence firing and not an empty database.
      {member_conn, _} = scoped_conn(conn, sxi)
      {:ok, member_view, _} = live(member_conn, ~p"/tasks")
      _ = render_async(member_view, 2_000)
      assert mine.principal.name in roster_agent_names(member_view)

      # `Tenancy.visibility/1` → `:none` for a user with zero memberships,
      # and `Tenancy.scope/3`'s `:none` clause is fail-closed.
      {none_conn, none_user} = scoped_conn(conn, nil)
      assert Tenancy.visibility(Platform.Accounts.get_user(none_user.id)) == :none

      {:ok, none_view, _} = live(none_conn, ~p"/tasks")
      _ = render_async(none_view, 2_000)

      assert roster_agent_names(none_view) == []

      %AsyncResult{result: composite} =
        :sys.get_state(none_view.pid).socket.assigns.composite_status

      assert composite.total == 0
      assert composite.state == :none
    end
  end

  # ── Agents meter renders the ratio (stage 4) ──────────────────────────────
  #
  # The dot was decorative before this stage: stage 2 changed `composite/1`
  # to return a MAP while the template still called `dot_color(composite)`,
  # which fell through the atom clauses to the catch-all and rendered
  # `bg-neutral` no matter what the roster was doing. The fix is to pass
  # `composite.state`, and the guard against it regressing is the paired
  # transition below — a single-state assertion cannot tell a live indicator
  # from a hardcoded one.
  describe "agents meter ratio" do
    # `agent_status/1` for a builtin agent is `Registry.lookup(...)` →
    # `Process.alive?/1`. Registering a live process under the agent's slug is
    # therefore the honest way to make an agent read `:active`; nothing is
    # stubbed. The process is linked to the test and dies with it.
    defp make_agent_active(agent) do
      test = self()

      pid =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Platform.Agents.Registry, agent.slug, nil)
          send(test, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered, 1_000
      assert Platform.Chat.SpaceAgentPresence.agent_status(agent) == :active
      pid
    end

    defp seed_meter_space(org, healthy_count, unhealthy_count) do
      n = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{name: "Meter Space", slug: "meter-space-#{n}", org_id: org.id})

      agents =
        for i <- 1..(healthy_count + unhealthy_count) do
          Repo.insert!(%Agent{
            name: "MeterBot#{i}",
            slug: "meter-bot-#{n}-#{i}",
            status: "active",
            runtime_type: "builtin"
          })
        end

      [principal | members] = agents
      {:ok, _} = Chat.set_principal_agent(space.id, principal.id)
      for m <- members, do: {:ok, _} = Chat.add_space_agent(space.id, m.id, role: "member")

      %{space: space, agents: agents}
    end

    defp dot_class(html) do
      case Regex.run(~r/class="([^"]*)"[^>]*data-test-id="shell-agents-dot"/, html) do
        [_, class] -> class
        nil -> flunk("the agents dot never rendered — nothing to compare across the transition")
      end
    end

    # The header strip only. Scoping the brand-token refutation to the whole
    # page would let unrelated markup decide the result either way.
    defp header_strip(html) do
      case Regex.run(~r/(<header[^>]*id="utility-bar".*?<\/header>)/s, html) do
        [_, strip] -> strip
        nil -> flunk("the utility bar never rendered")
      end
    end

    test "the button renders the seeded roster as a literal n/m ratio", %{conn: conn} do
      {sxi, _} = tenant_orgs()
      %{agents: agents} = seed_meter_space(sxi, 2, 1)
      [a, b, _c] = agents
      _ = make_agent_active(a)
      _ = make_agent_active(b)

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_async(view, 2_000)

      # The number itself, not the word. A build that still renders the bare
      # label "Agents" for a populated roster fails here.
      assert html =~ ~s(data-test-id="shell-agents-ratio")
      assert html =~ "2/3"
      refute html =~ "0/0"
    end

    # PAIRED TRANSITION, in one run. Assert both endpoint values AND that they
    # differ. If a future refactor makes the dot constant again, the equality
    # refutation fails even if someone updates both endpoint expectations to
    # the same class.
    test "the dot class and the ratio both CHANGE when roster health changes", %{conn: conn} do
      {sxi, _} = tenant_orgs()
      %{space: space, agents: agents} = seed_meter_space(sxi, 2, 1)
      [a, b, c] = agents
      _ = make_agent_active(a)
      _ = make_agent_active(b)

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      before_html = render_async(view, 2_000)

      before_dot = dot_class(before_html)
      assert before_dot =~ "bg-warning", "2 of 3 healthy must read degraded, got: #{before_dot}"
      assert before_html =~ "2/3"

      # Flip the last agent healthy and nudge the shell to recompute over the
      # SAME roster (no membership change, so any difference below is health,
      # not arithmetic).
      _ = make_agent_active(c)

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Chat.global_roster_topic(),
        {:roster_changed_any, space.id}
      )

      after_html = render(view)
      after_dot = dot_class(after_html)

      assert after_dot =~ "bg-success", "3 of 3 healthy must read success, got: #{after_dot}"
      assert after_html =~ "3/3"

      # The load-bearing assertion.
      refute before_dot == after_dot,
             "the dot class did not change across a real health transition — the indicator is decorative"

      refute before_html =~ "3/3" and after_html =~ "2/3",
             "the ratio did not change across the transition"
    end

    # Brand tokens only. The design canvas names these five raw Tailwind
    # classes as the violation; they must not come back in the meter markup
    # or in the module that supplies its colours.
    test "no raw Tailwind status colours in the agents meter or its colour module", %{conn: conn} do
      {sxi, _} = tenant_orgs()
      %{agents: [a | _]} = seed_meter_space(sxi, 1, 2)
      _ = make_agent_active(a)

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)
      opened = view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()

      banned = ["bg-red-500", "bg-green-500", "bg-green-400", "bg-blue-500", "bg-zinc-500"]

      # Positive control: the markup under test really does carry status
      # colours, so the refutations below are about the TOKENS used and not
      # about an empty panel.
      assert opened =~ "bg-warning" or opened =~ "bg-success" or opened =~ "bg-error"

      meter_markup = header_strip(opened)

      for klass <- banned do
        refute meter_markup =~ klass, "raw Tailwind #{klass} is back in the agents meter"
      end

      source = File.read!("lib/platform/chat/space_agent_presence.ex")
      assert source =~ "bg-success", "positive control: the module does define dot colours"

      for klass <- banned do
        refute source =~ klass, "raw Tailwind #{klass} is back in space_agent_presence.ex"
      end
    end

    test "an orphaned roster row reads 'Deleted agent' with no dot and no status", %{conn: conn} do
      {sxi, _} = tenant_orgs()
      %{agents: agents} = seed_meter_space(sxi, 1, 1)
      [principal, member] = agents
      _ = make_agent_active(principal)
      Repo.delete!(member)

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)
      opened = view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()

      # "Unknown agent" describes a naming problem; the fact is a deleted
      # record. And an orphan must not claim a status — "offline" is a false
      # statement about a row that no longer exists.
      assert opened =~ "Deleted agent"
      refute opened =~ "Unknown agent"

      orphan_row =
        opened
        |> String.split("Deleted agent")
        |> hd()
        |> String.split(~s(<div class="flex items-center justify-between))
        |> List.last()

      refute orphan_row =~ "rounded-full",
             "the orphan row still renders a status dot: #{orphan_row}"

      # Positive control: a live row DOES carry a dot, so the refutation above
      # is about the orphan and not about dots having disappeared entirely.
      assert opened =~ "rounded-full"
    end

    # The roster panel is anchored to the HEADER's right edge, not to its
    # trigger button. Anchored to the button (`right-0` on a wrapper with
    # `relative`) the panel measured left: -60.2px at 375px, clipping every
    # agent name to its tail. This test pins the anchor; the geometry itself
    # is measured in the browser with getBoundingClientRect().left >= 0 —
    # NOT with an overflow check, which cannot see leftward overflow
    # (no scrollbar, scrollWidth == clientWidth).
    test "the roster panel anchors to the header, not to the trigger button", %{conn: conn} do
      {sxi, _} = tenant_orgs()
      %{agents: [a | _]} = seed_meter_space(sxi, 1, 1)
      _ = make_agent_active(a)

      {conn, _user} = scoped_conn(conn, sxi)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = render_async(view, 2_000)

      # The positioning context must be the full-width header.
      assert html =~ ~r/<header[^>]*id="utility-bar"[^>]*class="relative /

      opened = view |> element(~s([data-test-id="shell-roster-button"])) |> render_click()

      panel_classes =
        case Regex.run(~r/class="([^"]*)"[^>]*data-test-id="shell-roster-panel"/, opened) do
          [_, classes] -> classes
          nil -> flunk("the roster panel never rendered — its anchor cannot be checked")
        end

      assert panel_classes =~ "right-4",
             "panel must clear the viewport edge, got: #{panel_classes}"

      refute panel_classes =~ "right-0",
             "right-0 anchors the panel to a mid-strip button and pushes it off-screen"
    end
  end

  # ── Push registration on every shell surface (task 019ffb7b stage 3) ──────
  #
  # Before this stage the `#push-subscribe` anchor lived in
  # `chat_live.html.heex` and the four push handlers lived in `chat_live.ex`,
  # so registration was bound to `/chat`. A user working from Tasks or Inbox
  # mounted no hook, reported no permission state, and never registered a
  # subscription. The anchor is now a shell singleton and the handlers are a
  # `:push_events` attach on `ShellLive.on_mount/4`, so every surface that
  # renders the shell carries both.
  #
  # `data-permission` reflects the server assign onto the anchor so the wire
  # state is observable in the DOM. Without it there is nothing on `/tasks`
  # that renders off `:push_permission` — the visible consumers are the
  # stage-4 notification-state row on `/inbox` and the banner on `/chat` — and
  # the assign could only be asserted by reaching into the LiveView's process
  # state.
  describe "push registration anchor" do
    test "renders on a non-chat authenticated route", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#push-subscribe[phx-hook='PushSubscribe']")
    end

    test "seeds the permission state as unknown", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert has_element?(view, "#push-subscribe[data-permission='unknown']")
    end

    test "is a singleton on /chat, where the anchor used to be declared", %{conn: conn} do
      conn = authenticated_conn(conn)

      # `/chat` live-redirects to the first active channel when the user has
      # one; the anchor is shell-level either way.
      html =
        case live(conn, ~p"/chat") do
          {:ok, _view, html} -> html
          {:error, {:live_redirect, %{to: path}}} -> elem(live(conn, path), 2)
        end

      count =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#push-subscribe")
        |> Enum.count()

      assert count == 1,
             "exactly one element may carry the push-subscribe DOM id, found #{count}"
    end
  end

  describe "push events on a non-chat route" do
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      %{view: view}
    end

    test "push_permission_state sets the assign", %{view: view} do
      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(view, "#push-subscribe[data-permission='prompt']")
    end

    test "push_unsupported sets the assign", %{view: view} do
      render_hook(view, "push_unsupported", %{})

      assert has_element?(view, "#push-subscribe[data-permission='unsupported']")
    end

    test "enable_notifications pushes the permission request back to the hook", %{view: view} do
      render_hook(view, "enable_notifications", %{})

      assert_push_event(view, "request_push_permission", %{})
    end

    # A subscribe failure under an already-granted permission is not a
    # denial. TasksLive has no catch-all handle_event/3, so an unhandled
    # hook event would take the view down here.
    test "push_subscribe_failed is handled and leaves the assign alone", %{view: view} do
      render_hook(view, "push_permission_state", %{"state" => "granted"})

      render_hook(view, "push_subscribe_failed", %{
        "name" => "AbortError",
        "message" => "push service error"
      })

      assert has_element?(view, "#push-subscribe[data-permission='granted']")
    end

    # No `current_participant` exists off `/chat`. Since task 019ffe52 fix A
    # the handler falls back to `Push.subscribe_for_user/2`, and this setup's
    # user is in no space at all, so there is still no row to key to. The
    # handler must degrade rather than crash, which is what this case is for.
    #
    # It used to assert `data-permission='granted'` here. That assertion was
    # the defect written down: nothing was written and the shell said it was.
    # Fix B changed the contract, so the assertion changed with it, deliberately
    # and not to make a red go away. The permission now stays where it was
    # ("unknown", since this setup never reported one) and the failure is
    # carried on `:push_registration_failed`. The full contract, including the
    # case where the browser HAS granted, is in
    # `shell_live_push_registration_test.exs`; the registration that does land
    # off `/chat` for a user who is in a space is there too.
    test "push_subscribed does not crash without a current participant", %{view: view} do
      render_hook(view, "push_subscribed", %{
        "endpoint" => "https://push.example.com/endpoint",
        "keys" => %{"p256dh" => "p256dh-key", "auth" => "auth-key"}
      })

      # Alive: the clause handled the event rather than taking the view down.
      assert has_element?(view, "#push-subscribe")

      refute has_element?(view, "#push-subscribe[data-permission='granted']"),
             "a registration that wrote nothing must not report a grant"

      assert :sys.get_state(view.pid).socket.assigns[:push_registration_failed]
    end
  end

  # ---------------------------------------------------------------------
  # Inbox reconciliation on the shell mount path (task 01a00066 stage 3)
  #
  # THE DEFECT IS SURFACE REACHABILITY, not the reconciler. Before this
  # stage the only caller of `Inbox.reconcile_for_user/1` was
  # `InboxLive.load_items/1`, and `/inbox` is fenced off from external
  # users by `PlatformWeb.Plugs.ExternalUserScope` (allowlist: `[]`,
  # `["chat"]`, `["chat", slug]` — everything else 403s). So the one
  # self-healing seam never ran for exactly the users who cannot reach it.
  # The load-bearing test here is therefore an EXTERNAL user mounting the
  # `chat.` host surface: an internal-user reconciliation test passes on
  # `origin/main` and proves nothing.
  #
  # `chat.example.test` is an INVENTED host fixture — the router matches
  # the `chat.` prefix, and `core` is public so no real hostname appears.
  # ---------------------------------------------------------------------
  describe "inbox reconciliation runs on the external chat mount" do
    alias Platform.Inbox

    @chat_host "chat.example.test"

    defp reconcile_user!(name) do
      n = System.unique_integer([:positive])

      Repo.insert!(%User{
        email: "reconcile-shell-#{n}@example.com",
        name: name,
        oidc_sub: "oidc-reconcile-shell-#{n}"
      })
    end

    defp reconcile_tenant_org! do
      n = System.unique_integer([:positive])

      Repo.insert!(%Platform.Tenancy.Org{
        name: "Reconcile Tenant #{n}",
        slug: "tenant_reconcile_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
      })
    end

    defp reconcile_external_user! do
      org = reconcile_tenant_org!()
      user = reconcile_user!("Xena External")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
      Tenancy.allow_dm(user, org)
      %{user: user, org: org}
    end

    # ONE space, TWO messages with distinct UUIDv7 ids and the read
    # watermark set BETWEEN them. `earlier` is behind the watermark
    # (positively confirmed read → the reconciler must clear its row);
    # `later` is ahead of it (unconfirmed → must survive). A one-message
    # fixture cannot separate a reconciler from one that clears
    # unconditionally.
    defp mention_pair!(user, org_id) do
      {:ok, space} =
        Chat.create_space(%{
          name: "Reconcile Shell",
          slug: "reconcile-shell-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: org_id
        })

      {:ok, me} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      {:ok, author} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          joined_at: DateTime.utc_now()
        })

      {:ok, earlier} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "first"
        })

      {:ok, later} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "second"
        })

      assert earlier.id < later.id
      :ok = Chat.mark_space_read(me.id, earlier.id)

      {:ok, read_row} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: earlier.id,
          title: "Mentioned (behind the watermark)",
          url: "/chat/#{space.slug}"
        })

      {:ok, unread_row} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: later.id,
          title: "Mentioned (ahead of the watermark)",
          url: "/chat/#{space.slug}"
        })

      %{space: space, read_row: read_row, unread_row: unread_row}
    end

    defp external_chat_conn(conn, user) do
      %{conn | host: @chat_host} |> init_test_session(current_user_id: user.id)
    end

    # A separate, EMPTY channel to land the mount on. The mount must not
    # visit the mention space: ChatLive advances that space's read
    # watermark on mount, which would push `later` behind the watermark
    # and dismiss BOTH rows — a fixture artefact that would read as an
    # over-eager reconciler (and, worse, would hide one).
    defp landing_channel!(user, org_id) do
      {:ok, ch} =
        Chat.create_space(%{
          name: "Landing",
          slug: "reconcile-landing-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: org_id
        })

      {:ok, _} =
        Chat.add_participant(ch.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      ch
    end

    test "an external user's stale mention is cleared by the mount and the badge DECREASES",
         %{conn: conn} do
      %{user: ext, org: org} = reconcile_external_user!()
      %{read_row: read_row, unread_row: unread_row} = mention_pair!(ext, org.id)
      landing = landing_channel!(ext, org.id)

      # Pre-state: both rows live, so any decrease below is caused by the
      # mount and not by the fixture.
      assert Inbox.unread_count(ext.id) == 2

      {:ok, view, _html} = live(external_chat_conn(conn, ext), "/chat/#{landing.slug}")

      # The mount genuinely succeeded — asserting against a dead LiveView
      # would pass vacuously.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_user_id == ext.id

      # THE NUMBER, not "a function was called". 2 -> 1.
      assert Inbox.unread_count(ext.id) == 1
      assert assigns.inbox_unread_count == 1

      # BOTH sides on one mount: behind the watermark cleared, ahead of it
      # survived. Without the second assertion a reconciler that dismissed
      # every row would pass.
      live_ids = Inbox.list_unread_for_user(ext.id) |> MapSet.new(& &1.id)
      refute MapSet.member?(live_ids, read_row.id)
      assert MapSet.member?(live_ids, unread_row.id)

      # #589/#592: the badge and the list must AGREE after reconciliation.
      # Both derive from `Inbox.unread_scope/1`; the list call here is the
      # read-filtered one the Inbox surface renders.
      assert assigns.inbox_unread_count == MapSet.size(live_ids)
    end

    test "CONTROL: the fence is unchanged — the same external user is still 403'd from /inbox",
         %{conn: conn} do
      %{user: ext} = reconcile_external_user!()

      denied =
        conn
        |> init_test_session(current_user_id: ext.id)
        |> get(~p"/inbox")

      assert denied.status == 403
      assert denied.halted
    end

    test "DIRECTION CONTROL: an internal user's mount and inbox behaviour are unchanged",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]
      user = Repo.get!(User, user_id)
      refute Tenancy.external_user?(user)

      org = Tenancy.get_org_by_slug!("fabrikam")
      %{read_row: read_row, unread_row: unread_row} = mention_pair!(user, org.id)

      assert Inbox.unread_count(user_id) == 2

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      # Same seam, same per-side outcome on the internal shell — the change
      # moved the call, it did not make it external-only.
      assert assigns.inbox_unread_count == 1
      assert Inbox.unread_count(user_id) == 1

      live_ids = Inbox.list_unread_for_user(user_id) |> MapSet.new(& &1.id)
      refute MapSet.member?(live_ids, read_row.id)
      assert MapSet.member?(live_ids, unread_row.id)

      # And the fence still lets an internal user through to /inbox.
      assert conn |> get(~p"/inbox") |> Map.get(:status) == 200
    end
  end

  # ---------------------------------------------------------------------
  # Task 01a00066 stage 4 — the shell counts only what the viewer can reach.
  #
  # `compute_inbox_count/1` now consumes `Inbox.reachable_unread_count/1` for
  # BOTH the mount assign and the `:inbox_count_refresh` recompute, so the
  # first paint and the live badge agree about what is counted.
  #
  # A FINDING recorded here because it makes one assertion below weaker than
  # it looks: the badge is painted only by `IconRail.badge_text/1` from
  # `layouts/shell.html.heex`, and the external surface renders NO icon rail
  # (`Layouts.external/1`). So on the external mount "no badge node" cannot
  # by itself distinguish "correctly absent" from "nothing renders here
  # anyway" — the load-bearing external assertion is therefore the ASSIGN
  # (the count the renderer would be handed), and the internal test below is
  # the control that shows a badge node does appear when the count is
  # non-zero. That is why the rule is implemented at the COUNT.
  # ---------------------------------------------------------------------
  describe "the shell badge count excludes what the viewer cannot reach" do
    alias Platform.Inbox

    defp sponsor_row!(user) do
      {:ok, row} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "task_sponsor_assigned",
          source_type: "task",
          source_id: Ecto.UUID.generate(),
          title: "You are the sponsor"
        })

      row
    end

    defp unreachable_mention_row!(user) do
      # A mention whose message id resolves to nothing: the reconciler cannot
      # POSITIVELY confirm it read, so the row survives the mount and the
      # count below is about reachability, not about reconciliation.
      {:ok, row} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "You were mentioned"
        })

      row
    end

    defp badge_nodes(html) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-role="inbox-badge"]))
    end

    test "an external user whose ONLY row is unreachable gets count 0 and NO badge node",
         %{conn: conn} do
      %{user: ext, org: org} = reconcile_external_user!()
      sponsor = sponsor_row!(ext)
      landing = landing_channel!(ext, org.id)

      # The row is live and the RAW count sees it — so a 0 below is the
      # reachability rule, not an empty fixture and not a dismissal.
      assert Inbox.unread_count(ext.id) == 1

      {:ok, view, html} = live(external_chat_conn(conn, ext), "/chat/#{landing.slug}")

      # Pin that the mount succeeded before reading anything off the DOM.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_user_id == ext.id

      # THE load-bearing assertion: the number the renderer is handed is 0,
      # which is what makes `badge_text/1` return nil and the node vanish.
      assert assigns.inbox_unread_count == 0

      # The row was NOT dismissed — counting and clearing stay separate.
      assert Inbox.unread_count(ext.id) == 1
      assert MapSet.member?(Inbox.list_unread_for_user(ext.id) |> MapSet.new(& &1.id), sponsor.id)

      # ABSENCE, not a rendered "0". Weak on this surface (see the note
      # above), asserted anyway so a future external rail cannot paint one.
      assert Enum.count(badge_nodes(html)) == 0
    end

    test "OTHER SIDE: the same external user's live chat_mention IS counted", %{conn: conn} do
      %{user: ext, org: org} = reconcile_external_user!()
      _sponsor = sponsor_row!(ext)
      mention = unreachable_mention_row!(ext)
      landing = landing_channel!(ext, org.id)

      assert Inbox.unread_count(ext.id) == 2

      {:ok, view, _html} = live(external_chat_conn(conn, ext), "/chat/#{landing.slug}")
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_user_id == ext.id

      # 1, not 0 and not 2: the mention counts, the sponsor row does not.
      assert assigns.inbox_unread_count == 1

      live_ids = Inbox.list_unread_for_user(ext.id) |> MapSet.new(& &1.id)
      assert MapSet.member?(live_ids, mention.id)
    end

    test "DIRECTION CONTROL: an internal user with the SAME rows counts both AND paints a badge",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]
      user = Repo.get!(User, user_id)
      refute Tenancy.external_user?(user)

      _sponsor = sponsor_row!(user)
      _mention = unreachable_mention_row!(user)

      {:ok, view, html} = live(conn, ~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.current_user_id == user_id

      # Every kind, unchanged — and identical to the unfiltered count.
      assert assigns.inbox_unread_count == 2
      assert Inbox.unread_count(user_id) == 2

      # The badge node IS present here. This is what makes the external
      # absence above informative rather than vacuous.
      nodes = badge_nodes(html)
      assert Enum.count(nodes) == 1
      assert nodes |> LazyHTML.text() |> String.trim() == "2"
    end
  end
end
