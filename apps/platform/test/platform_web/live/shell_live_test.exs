defmodule PlatformWeb.ShellLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp authenticated_conn_with_user(conn, opts \\ []) do
    role = Keyword.get(opts, :role, "admin")

    user =
      Repo.insert!(%User{
        email: "shell_test_#{System.unique_integer([:positive])}@example.com",
        name: "Shell Test User",
        oidc_sub: "oidc-shell-test-#{System.unique_integer([:positive])}"
      })

    # MT/RBAC stack 2 (task 019e3c4a): the admin nav gate now reads
    # `Tenancy.root_admin_preloaded?/1` instead of the
    # `Accounts.root_user?/1` stub. Default test users are admin so
    # the existing "renders rail / admin section" assertions keep working;
    # tests that need a non-admin can pass `role: "member"`.
    if role do
      acme = Tenancy.get_org_by_slug!("acme")

      Repo.insert!(%OrgMembership{
        user_id: user.id,
        org_id: acme.id,
        role: role
      })
    end

    {init_test_session(conn, current_user_id: user.id), user}
  end

  # ── Synchronising on a `send_update/2`-driven LiveComponent change ───────
  #
  # `render/1` is synchronous with the LiveView process for exactly ONE
  # mailbox turn: `Phoenix.LiveViewTest.ClientProxy` pings the LV, so every
  # message queued BEFORE the ping has been handled by the time the proxy
  # renders its cached tree.
  #
  # That is one turn short whenever the assertion's target is produced by
  # `send_update/2`, because `send_update/2` is `send(self(), ...)` — the
  # component's `update/2` runs on the LV's NEXT turn, and the diff it
  # produces reaches the proxy after the proxy has already decided what to
  # render. Concretely, for the meeting bar:
  #
  #   1. the test broadcasts `:meeting_media_state`      -> LV queue [B]
  #   2. the test calls `render(view)`; the proxy pings  -> LV queue [B, P]
  #   3. LV handles B; ShellLive's `:roster_updates` hook calls
  #      `send_update(MeetingBarLive, ...)`               -> LV queue [P, U]
  #   4. LV answers the ping P; the proxy renders — but U has not run, so
  #      the bar in the rendered tree still carries its previous mic state.
  #
  # Whether the assertion passes therefore depends on a genuine race between
  # two processes: whether the LV happens to get scheduled for U (and its
  # diff reaches the proxy) before the proxy dequeues its own render
  # request. Under load it loses. Measured at 1 failure / 30 isolated runs
  # on this test before this helper existed (seed 12 of 1..30).
  #
  # A SECOND `render/1` closes it deterministically rather than
  # probabilistically: U is already queued ahead of the second ping, so the
  # LV must run U — and push its diff — before it can answer that ping, and
  # the proxy only self-schedules its render after the ping returns. No
  # sleeps, no polling, no weakened assertion.
  #
  # Use this instead of `render/1` for any assertion whose subject is
  # written by `send_update/2`.
  defp render_settled(view) do
    _ = render(view)
    render(view)
  end

  defp authenticated_conn(conn, opts \\ []) do
    {conn, _user} = authenticated_conn_with_user(conn, opts)
    conn
  end

  # PWA app-shell scroll lock regression. The root shell container must
  # constrain itself to the viewport and refuse to scroll
  # (`overflow-hidden`) so the bottom-tab nav stays functionally rooted on
  # mobile — without these, the body itself scrolls and drags the chrome
  # out of view (Alex's mobile review-request hotfix, supersedes the inner
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
  # PWA scroll lock (Alex's report after #333 merged): #333 rooted the
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

  test "shell renders when no space exists", %{conn: conn} do
    # Clean slate — no spaces
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/chat")

    html = render_async(view, 1_000)
    # The rail label is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
  end

  # ── the shell's chat subscribe set (task 019fe4b1 stage 3) ────────────────
  #
  # The people-online badge these fixtures were written for was deleted in
  # task 01a1557a-8f80 stage 3 (presence is read in the Members sheet, see
  # `chat_live_members_test.exs`). The subscribe set it shared a Task with is
  # what remains.
  #
  # Orgs come from the seeded tenants rather than a freshly created one: a new
  # top-level org has `parent_org_id == nil`, which resolves `:root_all` and
  # silently disables the very org fence these tests exist to prove.
  defp presence_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "shell-subscribe-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-shell-subscribe-#{n}"
    })
  end

  defp presence_org_member!(user, org) do
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: org.id, role: "member"})
  end

  defp presence_space!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Presence Chan",
        slug: "shell-subscribe-#{System.unique_integer([:positive])}",
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

  describe "the shell's chat subscribe set" do
    setup %{conn: conn} do
      home = Tenancy.get_org_by_slug!("globex")
      foreign = Tenancy.get_org_by_slug!("initech")

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

    test "the LV subscribes to every viewer space, not one arbitrary space", ctx do
      second = presence_space!(ctx.home)
      presence_participant!(second, ctx.viewer, "Vera Viewer")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      subscribed = :sys.get_state(view.pid).socket.assigns.shell_chat_space_ids

      # Both spaces, not just the oldest — a single-topic subscription shows up
      # as a permanently stale list, which looks perfectly fine on first load.
      assert ctx.shared.id in subscribed
      assert second.id in subscribed
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

  # Burrow redesign 22 stage 1 deleted the shell's collapsible rail: no
  # SidebarCollapse host, no toggle_sidebar / sidebar_hydrate handlers.
  test "the shell carries no sidebar-collapse machinery", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, view, html} = live(conn, ~p"/tasks")

    # Positive control: the sidebar itself rendered.
    assert html =~ ~s(id="sidebar")
    refute html =~ ~s(id="sidebar-collapse-hook")
    refute html =~ ~s(phx-click="toggle_sidebar")
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns, :sidebar_collapsed)
  end

  # ---------------------------------------------------------------------
  # Sidebar and bottom-rail integration (task 019e389b Stage 3; the desktop
  # sidebar replaced the icon rail in Burrow redesign 22 stage 1)
  #
  # The component-level rendering contracts are covered by SidebarTest and
  # IconRailTest. These tests check the *wiring*: the shell layout passes the
  # right assigns (current_path, root_user) to the sidebar and the bottom
  # rail, and Admin stays a Settings page end-to-end.
  # ---------------------------------------------------------------------

  # Task 01a1557a-807f stage 4: two of the More sheet's ways out, through the
  # shell's own handlers (scrim, swipe and Escape push the same event).
  describe "More sheet dismissal" do
    defp more_open?(view), do: has_element?(view, "#more-sheet[data-open=true]")

    test "the handle, a real Close button, closes the open sheet", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      view |> element(~s([data-bottom-rail] button[data-destination="more"])) |> render_click()
      assert more_open?(view)

      view |> element("#more-sheet button.sheet-handle-button") |> render_click()
      refute more_open?(view)
    end

    # Task 01a1557a-807f stage 5: LiveView runs a live link's phx-click
    # through liveSocket.execJS/3, so a bare event name on a navigate/patch
    # link throws in the browser and pushes nothing. The whole rendered shell,
    # with the More sheet open, carries none.
    test "no live link in the shell carries a bare-string phx-click", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/files")
      view |> element(~s([data-bottom-rail] button[data-destination="more"])) |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      links = LazyHTML.query(doc, "[data-phx-link]")
      # Positive control: the sheet's rows are among the live links seen.
      assert doc |> LazyHTML.query("#more-sheet [data-phx-link]") |> Enum.count() > 3

      bare =
        for link <- Enum.to_list(links),
            click = link |> LazyHTML.attribute("phx-click") |> List.first(),
            click != nil,
            not match?({:ok, [_ | _]}, Jason.decode(click)),
            do: {LazyHTML.attribute(link, "href"), click}

      assert bare == []
    end

    test "More tapped again closes the sheet", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")
      more = ~s([data-bottom-rail] button[data-destination="more"])

      view |> element(more) |> render_click()
      assert more_open?(view)
      assert view |> element(more) |> render() =~ ~s(phx-click="close_more_sheet")

      view |> element(more) |> render_click()
      refute more_open?(view)
      assert view |> element(more) |> render() =~ ~s(phx-click="open_more_sheet")
    end
  end

  describe "sidebar integration" do
    test "renders the desktop sidebar", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(data-sidebar)
      assert html =~ ~s(id="sidebar")
      assert html =~ ~s(aria-label="Main navigation")
    end

    test "renders the mobile bottom-rail wrapper", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ ~s(data-bottom-rail)
    end

    test "active-state marker tracks current_path on the desktop sidebar", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks")

      # The Tasks row carries the current class + aria-current=page on /tasks.
      # Attribute order between `data-destination` and `aria-current` is not
      # guaranteed by the renderer, so accept either order.
      assert html =~ ~r/sidebar-row--current[^"]*"[^>]*data-destination="tasks"/

      assert html =~ ~r/data-destination="tasks"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="tasks"/s
    end

    test "active-state marker tracks current_path on the mobile bottom-rail", %{conn: conn} do
      # Was /activity; Activity left the bar in task 01a1557a-7a71 stage 2.
      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/meetings")

      assert html =~ ~r/bottom-nav-tab--active[^"]*"[^>]*data-destination="meetings"/
    end

    test "opening the More sheet lights More, and only More, in the rendered shell", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/tasks")
      assert bar_active_keys(html) == ["tasks"]

      html =
        view
        |> element(~s([data-bottom-rail] button[data-destination="more"]))
        |> render_click()

      assert bar_active_keys(html) == ["more"]

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-bottom-rail] button[data-destination="more"]))
             |> LazyHTML.attribute("aria-expanded") == ["true"]
    end

    test "the bar shows the More dot when the viewer has an unread inbox item", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, _view, html} = live(conn, ~p"/tasks")
      refute html =~ ~s(data-role="more-unread-dot")

      {:ok, _} =
        Platform.Inbox.emit(%{
          user_id: user_id,
          kind: "chat_mention",
          source_type: "chat_message",
          source_id: Ecto.UUID.generate(),
          title: "You were mentioned",
          body: "…",
          url: "/chat/x"
        })

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s([data-bottom-rail] [data-role="more-unread-dot"]))
             |> Enum.count() == 1
    end

    test "Admin is a Settings page, not a sidebar row, even for an admin", %{
      conn: conn
    } do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The sidebar lists exactly the phone's rows (Burrow redesign 22), and
      # Admin left those for /settings in task 01a1557a-807f stage 2.
      assert has_element?(view, ~s(#sidebar [data-destination="settings"][href="/settings"]))
      refute has_element?(view, ~s(#sidebar [data-destination="admin"]))
    end

    test "Admin tile is absent from the shell for a non-admin (member) user", %{
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
  end

  describe "Admin gate (root_admin? + root_user)" do
    test "root_user assign reflects real Acme-root admin membership", %{conn: conn} do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.root_user == true
    end

    test "root_user is false for an Acme member (non-admin)", %{conn: conn} do
      conn = authenticated_conn(conn, role: "member")
      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert :sys.get_state(view.pid).socket.assigns.root_user == false
    end

    test "Settings renders the Admin row for an admin user", %{conn: conn} do
      conn = authenticated_conn(conn, role: "admin")
      {:ok, _view, html} = live(conn, ~p"/settings")

      # Admin left the More sheet for /settings (task 01a1557a-807f stage 2),
      # and the desktop sidebar that replaced the icon rail lists only the
      # sheet's rows (Burrow redesign 22), so /settings is its one home.
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

    test "clearing the last item pushes zero so the hook clears the badge", %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, item} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert_push_event(view, "app_badge", %{count: 1, label: "1"})

      # This drove the badge to zero with `mark_read/2` until task `01a00108`
      # stage 4 retired read-as-cleared. Reading no longer changes the count, so
      # the trigger is now a dismissal — the property under test (a recompute
      # that lands on 0 pushes a clear to the client) is unchanged.
      #
      # mark_dismissed/2 broadcasts on the user's inbox topic; the recompute
      # drops the dismissed row, so the client must be told to clear. A nil
      # label is the hook's "no prefix" signal, matching the rail dropping its
      # badge node at 0.
      {:ok, _} = Inbox.mark_dismissed(item.id, user_id)
      _ = render(view)

      assert_push_event(view, "app_badge", %{count: 0, label: nil})
    end

    # INVERTED by task 01a11703: the badge counts rows the user has not opened
    # (`Inbox.badge_scope/1`), so a read moves it even though the row stays on
    # the /inbox list. This used to pin "reading does NOT move the badge"
    # (task 01a00108 stage 4).
    test "reading an item clears it from the badge and pushes the clear",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      user_id = conn.private.plug_session["current_user_id"]

      {:ok, item} = Inbox.emit(inbox_attrs(user_id))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert_push_event(view, "app_badge", %{count: 1, label: "1"})

      # mark_read/2 broadcasts `:inbox_changed`; the recompute lands on 0.
      {:ok, _} = Inbox.mark_read(item.id, user_id)
      _ = render(view)

      assert_push_event(view, "app_badge", %{count: 0, label: nil})
      assert Platform.Inbox.unread_count(user_id) == 0
      # Still listed: reading is not a list clear.
      assert user_id |> Platform.Inbox.unread_scope() |> Platform.Repo.aggregate(:count) == 1
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
  # Chat unread total in the shell (task 01a01b29 stage 1)
  #
  # Nothing renders this number yet (stage 2 puts it on the rail), so every
  # assertion here reads the assign directly.
  #
  # The vacuous version of this suite seeds unread rows and asserts the assign
  # is non-zero at mount. That passes against a shell that never updates. The
  # assertion that does the work is CHANGE OVER TIME: mount on `/tasks`, post
  # into a channel the viewer is not viewing, and watch the assign move with no
  # remount.
  # ---------------------------------------------------------------------
  describe "chat unread count live wiring" do
    test "a stranger's message moves the count live, and the mount seed is the right number",
         %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      channel = chat_unread_channel!("larkspur")
      chat_unread_join!(channel, user)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(view)

      assert chat_unread(view) == 0

      chat_unread_post_from_a_stranger(channel, "first fixture message")
      chat_unread_barrier(view)

      assert chat_unread(view) == 1,
             "a message in a channel the viewer is not viewing did not move the shell count: " <>
               "the /tasks session is subscribed to the space but nothing consumes {:new_message, _}"

      # Positive control, deliberately in the same test. The assertion above
      # measures movement; this one measures that the number is CORRECT rather
      # than merely present. A shell broken in both states (seed always 0,
      # refresh always +1) satisfies the first assertion on its own.
      {:ok, seeded, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(seeded)

      assert chat_unread(seeded) == 1,
             "a fresh mount seeded the wrong number for one already-unread message"

      chat_unread_post_from_a_stranger(channel, "second fixture message")
      chat_unread_barrier(seeded)

      assert chat_unread(seeded) == 2,
             "the live refresh did not add to a non-zero seed"
    end

    test "a participating channel with nothing unread counts zero", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      channel = chat_unread_channel!("marigold")
      chat_unread_join!(channel, user)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(view)

      # The absent-badge half of the zero contract belongs to stage 2. Here it
      # is the integer.
      assert chat_unread(view) == 0
    end

    test "a channel the viewer does not participate in does not count", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      joined = chat_unread_channel!("nasturtium")
      chat_unread_join!(joined, user)

      stranger_only = chat_unread_channel!("oleander")

      # Unread in somebody else's channel, present before the mount so the
      # seed has to reject it too.
      chat_unread_post_from_a_stranger(stranger_only, "not the viewer's channel")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(view)

      assert chat_unread(view) == 0,
             "the seed counted a channel the viewer holds no participant row on"

      chat_unread_post_from_a_stranger(joined, "the viewer's channel")
      chat_unread_barrier(view)

      assert chat_unread(view) == 1,
             "count everything: the refresh picked up a channel the viewer does not participate in"
    end

    test "an archived channel with unread does not contribute", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      # `Chat.unread_counts_for_user/1` does NOT filter archived spaces and
      # `Chat.list_member_space_ids/1` does, so this is the only test
      # that exercises the `Map.take/2` intersection in
      # `Chat.total_unread_for_viewer/1`. Without it, an archived space holding
      # unread pins the number at a value no broadcast can ever move.
      archived = chat_unread_channel!("periwinkle")
      chat_unread_join!(archived, user)
      chat_unread_post_from_a_stranger(archived, "unread that must not be counted")
      {:ok, _} = Chat.archive_space(archived)

      live_channel = chat_unread_channel!("quince")
      chat_unread_join!(live_channel, user)
      chat_unread_post_from_a_stranger(live_channel, "unread that must be counted")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(view)

      assert chat_unread(view) == 1,
             "an archived channel's unread reached the total; the intersection is not holding"
    end

    test "entering the channel clears the count", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      channel = chat_unread_channel!("rosemary")
      chat_unread_join!(channel, user)
      chat_unread_post_from_a_stranger(channel, "one unread")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      chat_unread_settle(view)
      assert chat_unread(view) == 1

      # Navigating into the channel is what calls `mark_read_at_channel_tip/2`,
      # which moves the read watermark. This is the `handle_params` queue path,
      # and it is also what proves the deferral: the hook runs BEFORE
      # `MessagesHooks`, so an inline recompute would still read 1 here.
      {:ok, chat_view, _html} = live(conn, ~p"/chat/#{Chat.space_path_segment(channel)}")
      chat_unread_settle(chat_view)
      chat_unread_barrier(chat_view)

      assert chat_unread(chat_view) == 0,
             "reading the channel left the shell count at its pre-read value"
    end

    # ── Fixtures ──────────────────────────────────────────────────────────

    defp chat_unread(view), do: :sys.get_state(view.pid).socket.assigns.chat_unread_count

    defp chat_unread_channel!(slug) do
      {:ok, channel} =
        Chat.create_space(%{
          name: String.capitalize(slug),
          slug: "#{slug}-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      channel
    end

    # `chat_unread_channel!/1` adds nobody. Without an explicit
    # `participant_type: "user"` row for the viewer,
    # `Chat.list_member_space_ids/1` returns `[]`, the shell subscribes to
    # nothing, and every assertion above goes red for the wrong reason.
    defp chat_unread_join!(channel, user) do
      {:ok, participant} =
        Chat.add_participant(channel.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: "Fixture Viewer",
          joined_at: DateTime.utc_now()
        })

      participant
    end

    # The author must not be the viewer: `count_unread/3` excludes
    # `m.participant_id != participant_pk`, so a self-authored message moves
    # nothing and the assertions would pass vacuously.
    defp chat_unread_post_from_a_stranger(space, body) do
      {:ok, author} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Fixture Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: body
        })

      message
    end

    # The subscribe only happens once `assign_async` resolves AND the LiveView
    # has processed `{:presence_spaces_resolved, _}`. Posting before that races
    # the registration and flakes.
    defp chat_unread_settle(view) do
      render_async(view, 2_000)
      _ = render(view)
      :ok
    end

    # TWO barriers, and the second is NOT redundant. Do not delete it. The
    # first `render/1` lets the process handle `{:new_message, _}`, which only
    # QUEUES the refresh; the queued `:chat_unread_refresh` is still behind it
    # in the mailbox. A single barrier reads the pre-refresh value.
    defp chat_unread_barrier(view) do
      _ = render(view)
      _ = render(view)
      :ok
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

      # Two flushes, not one: the bar's mic state is written by
      # `send_update/2`, which lands a turn after the broadcast. See
      # `render_settled/1`.
      post_html = render_settled(view)

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

      # `send_update/2`-written state — see `render_settled/1`. Same race as
      # the mic-button test above; this one had simply not been observed
      # losing it yet.
      html = render_settled(view)
      assert html =~ "hero-microphone-slash"
      assert html =~ "hero-video-camera-slash"

      :ok = MeetingState.broadcast_left(user_id)
    end
  end

  # ---------------------------------------------------------------------
  # Mini-bar Leave durably stamps the participant row (task 019ee06b Stage 2)
  #
  # Regression net for the bug Alex reported: clicking the persistent
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
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
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

      org = Tenancy.get_org_by_slug!("acme")
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

  # Burrow redesign 22 stage 1 deleted the account menu: at lg the
  # sidebar's user row links /settings, where Sign out lives; below lg the
  # More sheet's Settings row does the same.
  describe "account (the menu's replacement)" do
    test "no account menu and no logout link in the shell; the user row links /settings",
         %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      {:ok, view, _html} = live(conn, "/changelog")
      html = render(view)

      refute has_element?(view, "#account-menu")
      refute has_element?(view, "#account-menu-trigger")
      refute html =~ ~s(href="/auth/logout")

      assert has_element?(view, ~s(#sidebar-user[href="/settings"]))
      assert has_element?(view, ~s(#sidebar-user [data-avatar-kind="human"]))
      assert has_element?(view, "#sidebar-user", user.name)

      top = view |> element("header#phone-top-bar") |> render()
      refute top =~ "account-menu"
    end
  end

  defp bar_active_keys(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-bottom-rail] .bottom-nav-tab--active")
    |> LazyHTML.attribute("data-destination")
  end
end
