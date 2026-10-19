defmodule PlatformWeb.ShellLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Phoenix.LiveView.AsyncResult
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
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
    # The rail label is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
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

    {conn, user} = authenticated_conn_with_user(conn)
    # Task 01a011e6 stage 3: the roster is fenced to spaces the viewer is a
    # participant of, so the fixture has to join them.
    join_space!(space, user)
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

  # Task 01a0691d stage 3 (T3.6): the shell FORWARDS `{:roster_changed, _}`
  # only to views that declare `:roster_changed_downstream?`, and keeps the
  # halt for everyone else. That is not caution for its own sake — the views in
  # the `:authenticated` session have no `handle_info` catch-all
  # (`ChangelogLive` has exactly one clause; likewise `AdminFederationLive` and
  # `RecoveryLive`), so a blanket `:cont` would `FunctionClauseError` them and
  # crash-remount the page on somebody else's roster edit.
  #
  # The case above is the positive half: the shell's own roster still refreshes
  # on the same message, on both branches.
  test "a shell view without the downstream flag still halts {:roster_changed, _}",
       %{conn: conn} do
    {conn, _user} = authenticated_conn_with_user(conn)

    {:ok, space} =
      Chat.create_space(%{
        name: "Halt Space",
        slug: "test-shell-halt-#{System.unique_integer([:positive])}"
      })

    {:ok, view, _html} = live(conn, "/changelog")

    refute :sys.get_state(view.pid).socket.assigns[:roster_changed_downstream?],
           "this view declares the flag, so it is not the un-flagged case this test needs"

    send(view.pid, {:roster_changed, space.id})

    assert is_binary(render(view))
    assert Process.alive?(view.pid)
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

    {conn, user} = authenticated_conn_with_user(conn)
    join_space!(space, user)
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

  # Task 01a011e6 stage 3. `ShellLive.visible_roster/2` now requires the viewer
  # to hold a `participant_type: "user"` row on the space, so a roster fixture
  # that seeds agents but never joins the viewer produces an empty meter. Every
  # fixture below therefore joins its viewer explicitly — which also makes the
  # membership precondition of each test visible at its call site instead of
  # being an accident of the old org-only fence.
  defp join_space!(space, %{id: _} = user),
    do: presence_participant!(space, user, "Fixture Viewer")

  defp join_space!(_space, nil), do: nil

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

      subscribed = :sys.get_state(view.pid).socket.assigns.shell_chat_space_ids

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
      home = Tenancy.get_org_by_slug!("globex")

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
  # (current_path, root_user, sidebar_collapsed) to the icon-rail and
  # bottom-rail at both breakpoints, and the Admin slot's DOM presence
  # respects the root_user gate end-to-end.
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
      # `Tenancy.root_admin_preloaded?/1` instead of the
      # `Accounts.root_user?/1` stub. Default test conn seeds an admin
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

      join_space!(space, Keyword.get(opts, :viewer))

      %{space: space, principal: principal, member: member}
    end

    # Three independent assertions, deliberately. A test that only clicks and
    # asserts "no crash" passes against a build with no button at all, and a
    # test that only asserts the click returns html passes against a build
    # that renders an empty panel. So: (1) the button exists, (2) clicking it
    # does not raise, (3) the panel is actually POPULATED with the member and
    # carries the real space id on its Remove control.
    test "roster button opens a populated panel without crashing", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      %{space: space, member: member} = seed_roster_space(viewer: user)
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
      {conn, user} = authenticated_conn_with_user(conn)
      %{member: member} = seed_roster_space(viewer: user)

      Repo.delete!(member)
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
      {Tenancy.get_org_by_slug!("globex"), Tenancy.get_org_by_slug!("initech")}
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

    defp seed_org_space(org, label, opts \\ []) do
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

      join_space!(space, Keyword.get(opts, :viewer))

      %{space: space, principal: principal, member: member}
    end

    defp roster_agent_names(view) do
      :sys.get_state(view.pid).socket.assigns.roster_items
      |> then(fn %AsyncResult{result: items} -> items || [] end)
      |> Enum.map(fn {entry, _status} -> entry.agent && entry.agent.name end)
    end

    test "a foreign org's agents are absent while the viewer's own org's are present",
         %{conn: conn} do
      {globex, initech} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      mine = seed_org_space(globex, "Mine", viewer: user)
      # Deliberately NOT joined: the viewer is an org-mate of this space but
      # not a member of it, which is exactly the case the stage-3 fence adds.
      theirs = seed_org_space(initech, "Theirs")
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
      {globex, initech} = tenant_orgs()

      # Seeded first, so it is the oldest.
      {conn, user} = scoped_conn(conn, globex)

      theirs = seed_org_space(initech, "Oldest")
      mine = seed_org_space(globex, "Newer", viewer: user)

      assert DateTime.compare(theirs.space.inserted_at, mine.space.inserted_at) in [:lt, :eq]
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      names = roster_agent_names(view)

      assert mine.principal.name in names
      refute theirs.principal.name in names
    end

    test "an agent on two visible spaces is listed once and counted once", %{conn: conn} do
      {globex, _initech} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      a = seed_org_space(globex, "First", viewer: user)
      b = seed_org_space(globex, "Second", viewer: user)

      # Put A's member on B's roster too — same agent, two visible spaces.
      {:ok, _} = Chat.add_space_agent(b.space.id, a.member.id, role: "member")
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
      {globex, _initech} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      mine = seed_org_space(globex, "Live", viewer: user)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _ = render_async(view, 2_000)

      pid_before = view.pid

      %AsyncResult{result: before_composite} =
        :sys.get_state(view.pid).socket.assigns.composite_status

      assert mine.member.name in roster_agent_names(view)

      # Mutate the roster out-of-band. `Chat.remove_space_agent/3` fans out on
      # the global topic the shell subscribed to at mount. `user` was joined to
      # this space by `seed_org_space/3`, so it is an authorized dismisser.
      :ok = Chat.remove_space_agent({:user, user.id}, mine.space.id, mine.member.id)
      _ = render(view)

      %AsyncResult{result: after_composite} =
        :sys.get_state(view.pid).socket.assigns.composite_status

      assert view.pid == pid_before, "the LV must not have remounted"
      assert after_composite.total == before_composite.total - 1
      refute mine.member.name in roster_agent_names(view)
    end

    test "a viewer with no org memberships sees an empty roster, not every agent",
         %{conn: conn} do
      {globex, _initech} = tenant_orgs()
      # Positive control: an globex member DOES see this agent, so the empty
      # result below is the `:none` fence firing and not an empty database.
      {member_conn, member_user} = scoped_conn(conn, globex)
      mine = seed_org_space(globex, "Fenced", viewer: member_user)
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

    defp seed_meter_space(org, healthy_count, unhealthy_count, opts \\ []) do
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

      join_space!(space, Keyword.get(opts, :viewer))

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
      {globex, _} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      %{agents: agents} = seed_meter_space(globex, 2, 1, viewer: user)
      [a, b, _c] = agents
      _ = make_agent_active(a)
      _ = make_agent_active(b)
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
      {globex, _} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      %{space: space, agents: agents} = seed_meter_space(globex, 2, 1, viewer: user)
      [a, b, c] = agents
      _ = make_agent_active(a)
      _ = make_agent_active(b)
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
      {globex, _} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      %{agents: [a | _]} = seed_meter_space(globex, 1, 2, viewer: user)
      _ = make_agent_active(a)
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
      {globex, _} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      %{agents: agents} = seed_meter_space(globex, 1, 1, viewer: user)
      [principal, member] = agents
      _ = make_agent_active(principal)
      Repo.delete!(member)
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
      {globex, _} = tenant_orgs()
      {conn, user} = scoped_conn(conn, globex)
      %{agents: [a | _]} = seed_meter_space(globex, 1, 1, viewer: user)
      _ = make_agent_active(a)
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

  # ── Reproduction: does the roster's per-space subscribe reach a NON-member? ──
  #
  # Task 01a011e6 stage 1. REPRODUCTION ONLY — these tests characterise the
  # current behaviour of `visible_roster/1` + the `{:roster_resolved, sid}`
  # hook. They assert what the code does today, not what it ought to do.
  #
  # The traced path: `visible_roster/1` picks `sid` as the space_id of the
  # most-recently-updated row it selected, `async_load_roster/2` sends
  # `{:roster_resolved, sid}` to the LV, and the `:roster_updates` hook then
  # calls `ChatPubSub.subscribe(sid)` — subscribing the viewer's shell LV to
  # `chat:space:<sid>`. The only fence on that query is
  # `Tenancy.scope(visibility, binding: :space, field: :org_id)`. There is NO
  # viewer-membership clause and no `s.kind` clause, so an org-mate who is not
  # a participant of the space can still be handed its topic.
  #
  # But the query ALSO carries `where: p.participant_type == "agent"`, which is
  # what separates the two fixtures below. A human-to-human DM contributes no
  # "agent" row at all (and `Chat.create_space/1` explicitly skips the
  # historian auto-join for `kind: "dm"`), so it can never be `sid`.
  #
  # Subscription membership is read from the PubSub registry directly
  # (`Registry.lookup(Platform.PubSub, ...)`) rather than from
  # `socket.assigns[:roster_space_id]`. That assign is written by the code
  # under test; asserting on it would be circular.
  describe "roster_resolved per-space subscribe vs. a non-participant viewer" do
    setup %{conn: conn} do
      # A seeded child org — a freshly created top-level org has
      # `parent_org_id == nil`, which resolves `:root_all` and disables the
      # very org fence these fixtures depend on.
      org = Tenancy.get_org_by_slug!("globex")

      # Two staff in a private conversation, and a third org-mate who is NOT a
      # participant of it. Invented names only; `core` is public.
      insider_a = presence_user!("Dana Duofirst")
      insider_b = presence_user!("Errol Duosecond")
      outsider = presence_user!("Nina Nonmember")

      Enum.each([insider_a, insider_b, outsider], &presence_org_member!(&1, org))

      %{
        conn: init_test_session(conn, current_user_id: outsider.id),
        org: org,
        insider_a: insider_a,
        insider_b: insider_b,
        outsider: outsider
      }
    end

    defp dm_space!(org) do
      {:ok, space} =
        Chat.create_space(%{
          name: "Two Person Thread",
          slug: "shell-leak-dm-#{System.unique_integer([:positive])}",
          kind: "dm",
          org_id: org.id
        })

      space
    end

    # Force this space to be the newest `s.updated_at` in the viewer's visible
    # set, so `visible_roster/1`'s `sort_by(:desc)` cannot pick a seeded space
    # instead and make the result an accident of fixture ordering.
    defp make_newest!(space, offset_seconds \\ 3600) do
      future =
        DateTime.utc_now() |> DateTime.add(offset_seconds, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(
          from(s in Platform.Chat.Space, where: s.id == ^space.id),
          set: [updated_at: future]
        )

      space
    end

    defp leak_agent!(name) do
      Repo.insert!(%Agent{
        name: name,
        slug: "shell-leak-agent-#{System.unique_integer([:positive])}",
        status: "active",
        runtime_type: "builtin"
      })
    end

    defp subscribers(space_id) do
      Registry.lookup(Platform.PubSub, Platform.Chat.PubSub.space_topic(space_id))
    end

    test "(a) a DM with two user participants and NO agent is never selected as sid", ctx do
      # Control channel first, so it is the OLDER of the two spaces.
      control = presence_space!(ctx.org)
      # Stage 3: the control must be a space the viewer is a MEMBER of, or the
      # fence (correctly) keeps it out and the positive control below is dead.
      presence_participant!(control, ctx.outsider, "Nina Nonmember")
      {:ok, _} = Chat.add_agent_participant(control.id, leak_agent!("Control Scribe"))
      # Ahead of any seeded space, but behind the DM below.
      make_newest!(control, 1800)

      dm = dm_space!(ctx.org) |> make_newest!()
      presence_participant!(dm, ctx.insider_a, "Dana Duofirst")
      presence_participant!(dm, ctx.insider_b, "Errol Duosecond")

      # Anti-vacuity: the fixture really is a DM with two user rows and zero
      # agent rows. Without this, an empty space would satisfy the refute.
      assert Repo.aggregate(
               from(p in Chat.Participant,
                 where: p.space_id == ^dm.id and p.participant_type == "user"
               ),
               :count
             ) == 2

      assert Repo.aggregate(
               from(p in Chat.Participant,
                 where: p.space_id == ^dm.id and p.participant_type == "agent"
               ),
               :count
             ) == 0

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      # The subscribe is installed on a send/2 round trip out of the async
      # Task, so it is not in place when live/2 returns. Sync on the LV's own
      # mailbox rather than sleeping.
      _ = :sys.get_state(view.pid)

      dm_pids = subscribers(dm.id) |> Enum.map(&elem(&1, 0))
      control_pids = subscribers(control.id) |> Enum.map(&elem(&1, 0))

      # POSITIVE CONTROL, and a discriminating one. The subscribe mechanism
      # demonstrably ran for this very LV — it holds the control channel's
      # topic. So the refute below is about the DM being excluded, not about a
      # dead LiveView or an un-synced assertion. And because the DM is the
      # NEWER space of the two, recency cannot explain the difference: the only
      # clause that separates them is `p.participant_type == "agent"`.
      assert view.pid in control_pids,
             "control channel subscribe did not happen; registry held " <>
               "#{inspect(subscribers(control.id))} — the refute below would be vacuous"

      refute view.pid in dm_pids
    end

    # Task 01a011e6 stage 3 INVERTED this test. Before the fence it asserted
    # that the non-participant DID receive the topic (that was the bug). It now
    # asserts the fence holds, and it keeps a discriminating positive control
    # so the refute cannot pass for the wrong reason.
    test "(b) a DM WITH an agent participant is NOT handed to a non-participant", ctx do
      # A space the viewer really is a member of, and OLDER than the DM. If the
      # fence works, `sid` falls through to this one — so a passing refute on
      # the DM comes with proof that the subscribe mechanism ran on this very
      # LV, and that recency did not explain the difference.
      own = presence_space!(ctx.org) |> make_newest!(1800)
      presence_participant!(own, ctx.outsider, "Nina Nonmember")
      {:ok, _} = Chat.add_agent_participant(own.id, leak_agent!("Own Scribe"))
      make_newest!(own, 1800)

      dm = dm_space!(ctx.org) |> make_newest!()
      presence_participant!(dm, ctx.insider_a, "Dana Duofirst")
      presence_participant!(dm, ctx.insider_b, "Errol Duosecond")

      agent = leak_agent!("Deputy Scribe")
      {:ok, _} = Chat.add_agent_participant(dm.id, agent)
      # `add_agent_participant/3` touches the space; re-pin it as newest.
      make_newest!(dm)

      assert Repo.aggregate(
               from(p in Chat.Participant,
                 where: p.space_id == ^dm.id and p.participant_type == "agent"
               ),
               :count
             ) == 1

      # The viewer is definitively NOT a participant of this space.
      refute Repo.exists?(
               from(p in Chat.Participant,
                 where: p.space_id == ^dm.id and p.participant_id == ^ctx.outsider.id
               )
             )

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      lookup = subscribers(dm.id)
      pids = Enum.map(lookup, &elem(&1, 0))

      assert view.pid in Enum.map(subscribers(own.id), &elem(&1, 0)),
             "the roster subscribe did not run on this LV at all (own space " <>
               "#{own.id} held #{inspect(subscribers(own.id))}), so the refute " <>
               "below would be vacuous"

      refute view.pid in pids,
             "the non-participant shell LV #{inspect(view.pid)} still holds " <>
               "chat:space:#{dm.id}; registry held #{inspect(lookup)}"
    end

    # Also inverted by stage 3: delivery, not just registration.
    test "(b') no broadcast on that DM's topic reaches the non-participant's mailbox",
         ctx do
      own = presence_space!(ctx.org)
      presence_participant!(own, ctx.outsider, "Nina Nonmember")
      {:ok, _} = Chat.add_agent_participant(own.id, leak_agent!("Own Scribe"))
      make_newest!(own, 1800)

      dm = dm_space!(ctx.org) |> make_newest!()
      presence_participant!(dm, ctx.insider_a, "Dana Duofirst")
      presence_participant!(dm, ctx.insider_b, "Errol Duosecond")

      agent = leak_agent!("Deputy Scribe")
      {:ok, _} = Chat.add_agent_participant(dm.id, agent)
      make_newest!(dm)

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      # A second, independent channel. The registry says who is REGISTERED;
      # this says what is DELIVERED. Suspending the LV first makes the mailbox
      # read race-free — a suspended `:sys` process accepts messages but
      # processes none, so the probe cannot be drained by the `_msg -> {:cont,
      # socket}` catch-all before we look.
      topic = Platform.Chat.PubSub.space_topic(dm.id)
      own_topic = Platform.Chat.PubSub.space_topic(own.id)
      :sys.suspend(view.pid)

      try do
        Phoenix.PubSub.broadcast(Platform.PubSub, topic, {:shell_leak_probe, :leaked})
        Phoenix.PubSub.broadcast(Platform.PubSub, own_topic, {:shell_leak_probe, :own})
        {:messages, mailbox} = Process.info(view.pid, :messages)

        # ANTI-VACUITY: the member-space probe, broadcast the same way in the
        # same suspended window, IS delivered. So "nothing was delivered at
        # all" cannot be what makes the refute pass.
        assert {:shell_leak_probe, :own} in mailbox,
               "expected the member-space probe on #{own_topic} in the mailbox; " <>
                 "mailbox held #{inspect(mailbox)}"

        refute {:shell_leak_probe, :leaked} in mailbox,
               "the probe on #{topic} still reached the non-participant LV mailbox; " <>
                 "mailbox held #{inspect(mailbox)}"
      after
        :sys.resume(view.pid)
      end
    end
  end

  # ── Stage 2: does the leaked topic reach the ASSIGNS, or only the MAILBOX? ──
  #
  # Task 01a011e6 stage 2. Stage 1 established that a non-participant org-mate's
  # shell LiveView ends up registered on `chat:space:<sid>` for an
  # agent-bearing space. That is a MAILBOX finding. It is NOT the same claim as
  # "a user saw someone else's message", and this block exists to keep the two
  # apart with independent evidence.
  #
  # The route that matters is `/chat`, not `/tasks`: `ShellLive`'s
  # `:roster_updates` hook halts only on `{:roster_resolved, _}`,
  # `{:roster_changed, _}` and the presence messages, and its catch-all
  # (`shell_live.ex` `_msg, socket -> {:cont, socket}`) passes every chat
  # broadcast THROUGH to the host LiveView. Of the host LiveViews in the
  # `:authenticated` live_session, only `ChatLive` (via
  # `PlatformWeb.Chat.MessagesHooks`) has a `handle_info({:new_message, msg}, _)`
  # that touches the payload at all. `TasksLive`'s clause discards `msg` and
  # re-reads its OWN `:execution_space_id`; `MeetingLive`'s participant clauses
  # discard the payload and re-read their own `chat_space_id`.
  #
  # So `/chat` is the worst case, and these two tests pin the two answers
  # separately. A single test that passed if EITHER were true would pin neither.
  describe "roster leak: mailbox reach vs. assigns reach on /chat" do
    setup %{conn: conn} do
      org = Tenancy.get_org_by_slug!("globex")

      insider_a = presence_user!("Dana Duofirst")
      insider_b = presence_user!("Errol Duosecond")
      outsider = presence_user!("Nina Nonmember")

      Enum.each([insider_a, insider_b, outsider], &presence_org_member!(&1, org))

      dm = dm_space!(org) |> make_newest!()
      insider_a_p = presence_participant!(dm, insider_a, "Dana Duofirst")
      presence_participant!(dm, insider_b, "Errol Duosecond")

      # The `participant_type == "agent"` clause in `visible_roster/1` is the
      # ONLY reason a plain staff-to-staff DM is not exposed (stage 1 fixture
      # (a)). It is an accidental confidentiality fence, not a designed one —
      # broadening that query would silently widen this leak. The agent row
      # below is what puts this space inside the leak's blast radius.
      {:ok, _} = Chat.add_agent_participant(dm.id, leak_agent!("Deputy Scribe"))
      make_newest!(dm)

      # Stage 3 control: a space the viewer really IS a member of, so every
      # refute below has a same-run positive counterpart on the same LV.
      own = presence_space!(org)
      presence_participant!(own, outsider, "Nina Nonmember")
      {:ok, _} = Chat.add_agent_participant(own.id, leak_agent!("Own Scribe"))
      make_newest!(own, 1800)

      # A second org-mate who is a member of NOTHING. `/chat` index does not
      # redirect for them, so they are the fixture for the residual `not nil`
      # defect below — which needs a mount with no active space at all.

      %{
        conn: init_test_session(conn, current_user_id: outsider.id),
        org: org,
        dm: dm,
        own: own,
        insider_a_p: insider_a_p,
        outsider: outsider
      }
    end

    # `/chat` index live_redirects into the viewer's first space once they
    # have one — which, post-fence, every fixture viewer with a roster does.
    # Follow it rather than asserting a shape the route no longer has.
    defp live_chat_index(conn) do
      case live(conn, ~p"/chat") do
        {:ok, view, html} ->
          {view, html}

        {:error, {:live_redirect, %{to: to}}} ->
          live(conn, to) |> then(fn {:ok, v, h} -> {v, h} end)
      end
    end

    @leaked_body "quarantine-canary-do-not-render-7f3a1c"

    defp post_leaked!(ctx) do
      {:ok, msg} =
        Chat.post_message(%{
          space_id: ctx.dm.id,
          participant_id: ctx.insider_a_p.id,
          content_type: "text",
          content: @leaked_body
        })

      msg
    end

    # Stage 3 inverted this. It measured the leak; it now guards the fence.
    test "MAILBOX: the /chat mount of a non-participant receives NO space broadcast", ctx do
      {view, _html} = live_chat_index(ctx.conn)
      _html = render_async(view, 2_000)
      # The subscribe is installed on a send/2 round trip out of the async
      # roster Task, so it is not in place when live/2 returns. Sync on the
      # LV's own mailbox rather than sleeping.
      _ = :sys.get_state(view.pid)

      lookup = subscribers(ctx.dm.id)

      assert view.pid in Enum.map(subscribers(ctx.own.id), &elem(&1, 0)),
             "the roster subscribe did not run on this /chat LV at all, so the " <>
               "refutes below would be vacuous"

      refute view.pid in Enum.map(lookup, &elem(&1, 0)),
             "the non-participant /chat LV #{inspect(view.pid)} still holds " <>
               "chat:space:#{ctx.dm.id}; registry held #{inspect(lookup)}"

      # Registry membership says who is REGISTERED. This says what is
      # DELIVERED. Suspending first makes the read race-free: a suspended
      # `:sys` process accepts messages but processes none, so the hooks
      # cannot drain the probe before we look.
      :sys.suspend(view.pid)

      try do
        _msg = post_leaked!(ctx)

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          Platform.Chat.PubSub.space_topic(ctx.own.id),
          {:shell_leak_probe, :own}
        )

        {:messages, mailbox} = Process.info(view.pid, :messages)

        # ANTI-VACUITY on the same mailbox read.
        assert {:shell_leak_probe, :own} in mailbox,
               "expected the member-space probe in the mailbox; mailbox held " <>
                 "#{inspect(mailbox)}"

        refute Enum.any?(mailbox, fn
                 {:new_message, %{space_id: sid}} -> sid == ctx.dm.id
                 _ -> false
               end),
               "a {:new_message, _} for chat:space:#{ctx.dm.id} still reached the " <>
                 "non-participant LV mailbox; mailbox held #{inspect(mailbox)}"
      after
        :sys.resume(view.pid)
      end
    end

    # STAGE 3 — the fence holds, AND a residual defect it now hides.
    #
    # Before the fence this test asserted the leaked broadcast CRASHED the
    # LiveView: `is_own_message` in `MessagesHooks.handle_info({:new_message,
    # msg}, _)` is `current_participant && ...`, which is `nil` — not `false` —
    # when the viewer holds no participant row, and `not nil` is an
    # ArgumentError. The roster leak was the only thing delivering a
    # background-space message to a viewer in that state, so removing the leak
    # removes the only observed symptom.
    #
    # **The `not nil` is still wrong and is NOT fixed here.** It is out of this
    # stage's scope and burying a real defect inside a security change would be
    # worse than leaving it visible. It is recorded here and in the stage
    # report so it can carry its own ticket: any future caller that reaches
    # that clause with a nil participant will crash exactly the same way.
    #
    # It is not asserted here because there is no longer a mount that reaches
    # it: every route into `ChatLive` now auto-creates the viewer's
    # participant row on the space it lands in.
    test "the leaked broadcast no longer arrives and the LV survives", ctx do
      {view, _html} = live_chat_index(ctx.conn)
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      # Anti-vacuity: the LV is alive and subscribed to the space the viewer
      # IS in, so "it survived" is not "it never ran".
      assert view.pid in Enum.map(subscribers(ctx.own.id), &elem(&1, 0))

      refute view.pid in Enum.map(subscribers(ctx.dm.id), &elem(&1, 0))

      _msg = post_leaked!(ctx)
      _ = render(view)

      assert Process.alive?(view.pid),
             "the LV died on a broadcast it should never have received"
    end

    # Stage 2 found that the only assigns-level consequence of the leak was a
    # phantom unread key for a space the viewer is not in (metadata, never
    # content). Stage 3 removes it.
    test "ASSIGNS(own space open): no phantom unread key for the non-member space", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.own.slug}")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      # ANTI-VACUITY: the LV is subscribed to the space the viewer IS in, so
      # the unread machinery is demonstrably live on this process.
      assert view.pid in Enum.map(subscribers(ctx.own.id), &elem(&1, 0)),
             "the member-space subscription is absent, so the refutes below " <>
               "would be vacuous"

      _msg = post_leaked!(ctx)

      html = render(view)
      assert Process.alive?(view.pid)

      assigns = :sys.get_state(view.pid).socket.assigns

      dump =
        inspect(Map.drop(assigns, [:__changed__]),
          limit: :infinity,
          printable_limit: :infinity,
          structs: false
        )

      refute Map.has_key?(assigns.unread_counts, ctx.dm.id),
             "a phantom unread key for a space the viewer is not in survived; " <>
               "unread_counts held #{inspect(assigns.unread_counts)}"

      refute dump =~ ctx.dm.id
      refute dump =~ @leaked_body
      refute html =~ @leaked_body
    end
  end

  # ── Stage 3: the fence itself — narrowing, and only narrowing ──────────────
  #
  # Task 01a011e6 stage 3. `visible_roster/2` now intersects with the viewer's
  # own `participant_type: "user"` rows and drops `kind: "dm"` outright. Both
  # clauses only ever REMOVE rows, and that is the property these tests pin:
  # the post-fix agent set is compared against the pre-fix query recomputed in
  # the test, and asserted to be a strict subset of it. A change that made the
  # roster "more complete" would fail here, which is the point — the
  # `participant_type == "agent"` clause is an accidental confidentiality
  # fence and broadening this query widens the leak.
  describe "roster fence: viewer membership and private kinds" do
    setup %{conn: conn} do
      org = Tenancy.get_org_by_slug!("globex")

      viewer = presence_user!("Vera Viewer")
      other = presence_user!("Oscar Otherstaff")
      Enum.each([viewer, other], &presence_org_member!(&1, org))

      %{conn: conn, org: org, viewer: viewer, other: other}
    end

    # The pre-fix query, recomputed here rather than read through the code
    # under test: agent participant rows on non-archived spaces, org-fenced
    # only. This is the SUPERSET the fenced result must sit inside.
    defp prefix_agent_ids(org) do
      from(p in Chat.Participant,
        join: s in Platform.Chat.Space,
        on: s.id == p.space_id,
        where:
          p.participant_type == "agent" and is_nil(s.archived_at) and
            s.org_id == ^org.id,
        select: p.participant_id
      )
      |> Repo.all()
      |> MapSet.new()
    end

    defp roster_agent_ids(view) do
      :sys.get_state(view.pid).socket.assigns.roster_items.result
      |> Enum.map(fn {entry, _status} -> entry.agent_id end)
      |> MapSet.new()
    end

    test "narrows to member spaces, excludes DMs, and never adds a row", ctx do
      mine = presence_space!(ctx.org)
      presence_participant!(mine, ctx.viewer, "Vera Viewer")
      mine_agent = leak_agent!("Mine Scribe")
      {:ok, _} = Chat.add_agent_participant(mine.id, mine_agent)

      # Same org, agent-bearing, viewer NOT a participant. This is the row the
      # pre-fix query handed out.
      theirs = presence_space!(ctx.org)
      presence_participant!(theirs, ctx.other, "Oscar Otherstaff")
      theirs_agent = leak_agent!("Theirs Scribe")
      {:ok, _} = Chat.add_agent_participant(theirs.id, theirs_agent)

      # A DM the viewer IS a participant of, with an agent on it. Membership
      # alone would admit this one; the kind clause is what excludes it.
      dm = dm_space!(ctx.org)
      presence_participant!(dm, ctx.viewer, "Vera Viewer")
      dm_agent = leak_agent!("Dm Scribe")
      {:ok, _} = Chat.add_agent_participant(dm.id, dm_agent)
      make_newest!(dm)

      before = prefix_agent_ids(ctx.org)

      conn = init_test_session(ctx.conn, current_user_id: ctx.viewer.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      after_ids = roster_agent_ids(view)

      # THE NARROWING PROPERTY. Not "the result is what I expected" — "the
      # result cannot contain anything the old one did not".
      assert MapSet.subset?(after_ids, before),
             "the fenced roster admitted rows the pre-fix query rejected: " <>
               "#{inspect(MapSet.difference(after_ids, before))}"

      # Anti-vacuity for the subset assertion: the superset is genuinely
      # bigger, so `subset?` is not passing because both sides are equal (or
      # empty).
      assert MapSet.member?(before, theirs_agent.id)
      assert MapSet.member?(before, dm_agent.id)
      assert MapSet.size(after_ids) < MapSet.size(before)

      # And the specific removals, each for its own reason.
      assert MapSet.member?(after_ids, mine_agent.id),
             "the viewer's OWN space was dropped — this is over-narrowing"

      refute MapSet.member?(after_ids, theirs_agent.id)
      refute MapSet.member?(after_ids, dm_agent.id)

      # The DM is the newest space, so before the kind clause it would have
      # been `sid`. It is not.
      #
      # Asserted on `roster_space_id` rather than on the PubSub registry ON
      # PURPOSE: the viewer IS a member of this DM, so the SEPARATE
      # viewer-presence path (`Chat.list_member_space_ids/1` since 01a01f4c)
      # legitimately holds a `chat:space:<dm>` registration on this same pid.
      # The registry therefore cannot discriminate the roster path here — and
      # that shared registration is also why this stage adds no unsubscribe:
      # `Phoenix.PubSub.unsubscribe/2` would drop BOTH.
      assert :sys.get_state(view.pid).socket.assigns.roster_space_id == mine.id
    end

    test "a viewer who is a member of nothing gets an empty meter and a nil principal", ctx do
      theirs = presence_space!(ctx.org)
      presence_participant!(theirs, ctx.other, "Oscar Otherstaff")
      {:ok, _} = Chat.add_agent_participant(theirs.id, leak_agent!("Theirs Scribe"))
      make_newest!(theirs)

      # Anti-vacuity: there IS an agent-bearing space in the viewer's org, so
      # the empty result below is the fence, not an empty database.
      assert MapSet.size(prefix_agent_ids(ctx.org)) > 0

      conn = init_test_session(ctx.conn, current_user_id: ctx.viewer.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.roster_items.result == []

      # `shell.html.heex` gates the whole Agents button on `principal_name`,
      # and its legacy-dot branch covers nil. A non-member viewer losing the
      # button is the expected UI consequence of the fence, not a regression —
      # it is why this stage carries a human gate.
      assert assigns.principal_name.result == nil

      refute view.pid in Enum.map(subscribers(theirs.id), &elem(&1, 0))
    end
  end

  # ── Stage 4: the membership clause, isolated, with a paired positive control ─
  #
  # Task 01a011e6 stage 4. Stage 3 already inverted a refute for a NON-MEMBER
  # (`(b) a DM WITH an agent participant is NOT handed to a non-participant`),
  # but its positive control differs from the refuted space in BOTH membership
  # AND kind: `kind: "dm"` vs `kind: "channel"`. `@private_roster_kinds` alone
  # is enough to make that refute pass, so it cannot tell whether the
  # membership `exists/1` subquery does anything at all. Stage 3's own fence
  # tests read the answer back through `roster_items` / `roster_space_id` —
  # assigns written by the code under test.
  #
  # This block closes that gap. The two spaces below are the SAME kind, in the
  # SAME org, both agent-bearing, seeded in ONE test body from ONE fixture, and
  # differ in exactly one fact: whether the viewer holds a `participant_type:
  # "user"` row. Subscription state is read from the PubSub registry
  # (`Registry.lookup(Platform.PubSub, "chat:space:" <> id)`), never from
  # `:roster_space_id` or `:shell_chat_space_ids`.
  #
  # The positive control is a REGISTRATION COUNT, not a membership test, and
  # that is load-bearing. For a member space both the roster path
  # (`{:roster_resolved, sid}` → `ChatPubSub.subscribe/1`) and the presence path
  # (`{:presence_spaces_resolved, ids}` → `ChatPubSub.subscribe/1`) legitimately
  # register the same topic on the same pid, so mere presence in the registry
  # cannot distinguish "the roster path ran" from "only presence ran". Two
  # registrations can. A fence that excluded everything would leave one.
  describe "roster fence: membership is the discriminator (registry-read)" do
    setup %{conn: conn} do
      # A seeded CHILD org. A freshly created top-level org has
      # `parent_org_id == nil`, which resolves `:root_all`, and
      # `Tenancy.scope(q, :root_all, _)` is identity — that would silently
      # disable the org fence and make everything below pass for the wrong
      # reason. Asserted, not assumed.
      org = Tenancy.get_org_by_slug!("globex")

      refute is_nil(org.parent_org_id),
             "fixture org #{org.slug} is top-level, so visibility resolves to " <>
               ":root_all and Tenancy.scope/3 is identity — these tests would " <>
               "be vacuous"

      viewer = presence_user!("Wanda Watcher")
      other = presence_user!("Gil Gatekept")
      Enum.each([viewer, other], &presence_org_member!(&1, org))

      %{
        conn: init_test_session(conn, current_user_id: viewer.id),
        org: org,
        viewer: viewer,
        other: other
      }
    end

    # How many registrations this pid holds on the space's topic. Duplicate
    # keys are allowed, so a pid that subscribed twice appears twice — which is
    # the only registry-visible difference between "roster + presence" and
    # "presence only".
    defp registration_count(space_id, pid) do
      space_id |> subscribers() |> Enum.count(fn {p, _} -> p == pid end)
    end

    # MUTATION PROOF (both sides), against `ShellLive.visible_roster/2`:
    #
    #   refute side  — delete the `exists(...)` viewer-membership clause,
    #                  restoring the pre-fix query. `foreign` is the newest
    #                  agent-bearing channel, so it becomes `sid` and the LV
    #                  subscribes to it: the refute reds.
    #   control side — replace that clause's `vp.participant_type == "user"`
    #                  with a value no row carries, fencing every space out.
    #                  The roster path then subscribes to nothing, `member`
    #                  keeps only its presence-path registration, and the
    #                  count-of-2 control reds.
    test "a non-member holds no registration while the member space holds both paths'",
         ctx do
      # The viewer's own space: same kind, agent-bearing, viewer joined.
      member = presence_space!(ctx.org)
      presence_participant!(member, ctx.viewer, "Wanda Watcher")
      {:ok, _} = Chat.add_agent_participant(member.id, leak_agent!("Member Scribe"))
      make_newest!(member, 1800)

      # The org-mate's space: SAME kind, SAME org, also agent-bearing, viewer
      # NOT joined — and deliberately the NEWER of the two, so that recency
      # would hand it to the viewer if the membership clause were gone. Kind
      # cannot explain the divergence below; only membership can.
      foreign = presence_space!(ctx.org)
      presence_participant!(foreign, ctx.other, "Gil Gatekept")
      {:ok, _} = Chat.add_agent_participant(foreign.id, leak_agent!("Foreign Scribe"))
      make_newest!(foreign, 3600)

      # Anti-vacuity on the fixture itself: the two spaces really are alike
      # except for the viewer's row.
      assert member.kind == foreign.kind
      assert member.org_id == foreign.org_id

      for s <- [member, foreign] do
        assert Repo.aggregate(
                 from(p in Chat.Participant,
                   where: p.space_id == ^s.id and p.participant_type == "agent"
                 ),
                 :count
               ) == 1,
               "space #{s.id} is not agent-bearing, so the roster query could " <>
                 "never select it for either reason"
      end

      assert Repo.exists?(
               from(p in Chat.Participant,
                 where:
                   p.space_id == ^member.id and p.participant_type == "user" and
                     p.participant_id == ^ctx.viewer.id
               )
             )

      refute Repo.exists?(
               from(p in Chat.Participant,
                 where: p.space_id == ^foreign.id and p.participant_id == ^ctx.viewer.id
               )
             )

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      # Both subscribes are installed on a send/2 round trip out of an async
      # Task, so neither is in place when live/2 returns. Sync on the LV's own
      # mailbox rather than sleeping.
      _ = :sys.get_state(view.pid)

      member_count = registration_count(member.id, view.pid)
      foreign_count = registration_count(foreign.id, view.pid)

      # THE REFUTE, asserted FIRST so the two mutations below get separate,
      # attributable kills: removing the membership clause makes `foreign` the
      # `sid` and reds THIS line, while fencing everything out leaves this line
      # green (nothing is subscribed) and reds the control instead. Ordered the
      # other way round, the control fires for both and the refute is never
      # evaluated under either mutant.
      #
      # Same kind, same org, agent-bearing, and NEWER than the member space —
      # the only difference is the missing participant row.
      assert foreign_count == 0,
             "the non-member shell LV #{inspect(view.pid)} holds " <>
               "#{foreign_count} registration(s) on chat:space:#{foreign.id}; " <>
               "registry held #{inspect(subscribers(foreign.id))}"

      # POSITIVE CONTROL. An unpaired refute would pass against a build that
      # subscribed nobody at all; this is what rules that out.
      #
      # AMENDED BY TASK 01a01a1b STAGE 2: this read `== 2`, one registration
      # per path. Both paths now hold the space through
      # `PlatformWeb.SpaceTopics`, which subscribes only when the holder set
      # was empty, so the correct count is 1 and the REGISTRY CAN NO LONGER
      # DISTINGUISH "both paths ran" from "one did". The count keeps its
      # original job (non-zero rules out a build that subscribed nobody); the
      # two-paths claim moves to the holder map below, which is the only
      # surface that still records per-owner intent.
      assert member_count == 1,
             "expected the member space #{member.id} to hold exactly one shared " <>
               "registration for #{inspect(view.pid)}, got " <>
               "#{member_count}: #{inspect(subscribers(member.id))} — the refute " <>
               "above is vacuous without this"

      # Per-owner bookkeeping, read deliberately and labelled as such: this is
      # an assign written by the code under test, so it is NOT evidence about
      # the registry (the line above is). It is evidence that BOTH branches
      # reached this space, which is what the old `== 2` used to carry.
      holders_socket = :sys.get_state(view.pid).socket

      assert PlatformWeb.SpaceTopics.held_by?(holders_socket, member.id, :roster),
             "the roster branch did not reach the member space, so the refute above " <>
               "could be green because the roster path is dead rather than fenced"

      assert PlatformWeb.SpaceTopics.held_by?(holders_socket, member.id, :presence),
             "the presence branch did not reach the member space, so the refute above " <>
               "could be green because the presence path is dead rather than fenced"
    end

    # The sibling guard. `Phoenix.PubSub.unsubscribe/2` drops EVERY
    # registration a pid holds on a topic, and for a member both paths land on
    # the same topic on the same pid — so a fence that reached the presence
    # path would be invisible in the test above (the count would just fall to
    # 1, which reads like "roster excluded it"). This isolates the presence
    # path on a space the roster query provably cannot supply: a member channel
    # with NO agent participant. `visible_roster/2` requires
    # `p.participant_type == "agent"`, so any registration here came from
    # the shell's chat subscribe set, `Chat.list_member_space_ids/1`.
    test "the presence path still registers a member space the roster query cannot supply",
         ctx do
      # Keeps the roster path alive and pointed elsewhere, so this test is not
      # quietly measuring a dead LiveView.
      rostered = presence_space!(ctx.org)
      presence_participant!(rostered, ctx.viewer, "Wanda Watcher")
      {:ok, _} = Chat.add_agent_participant(rostered.id, leak_agent!("Rostered Scribe"))
      make_newest!(rostered, 3600)

      agentless = presence_space!(ctx.org)
      presence_participant!(agentless, ctx.viewer, "Wanda Watcher")

      # Same shape, but the viewer is not a member: the presence path is
      # membership-fenced too, so this pairs the assertion below.
      strangers = presence_space!(ctx.org)
      presence_participant!(strangers, ctx.other, "Gil Gatekept")

      for s <- [agentless, strangers] do
        assert Repo.aggregate(
                 from(p in Chat.Participant,
                   where: p.space_id == ^s.id and p.participant_type == "agent"
                 ),
                 :count
               ) == 0,
               "space #{s.id} has an agent participant, so the roster path " <>
                 "could have supplied it and this test would not isolate presence"
      end

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      _html = render_async(view, 2_000)
      _ = :sys.get_state(view.pid)

      assert registration_count(agentless.id, view.pid) == 1,
             "the presence-path registration on chat:space:#{agentless.id} did " <>
               "not survive the roster fence; registry held " <>
               "#{inspect(subscribers(agentless.id))}"

      refute view.pid in Enum.map(subscribers(strangers.id), &elem(&1, 0)),
             "a non-member space reached the presence subscribe set; registry " <>
               "held #{inspect(subscribers(strangers.id))}"
    end
  end

  # ── roster subscription release on a space switch (task 01a011e9 stage 5) ──
  #
  # The roster branch of the `:roster_updates` hook subscribes TWO topics for
  # the space it resolves: `space_agents:<id>` (roster-exclusive) and
  # `chat:space:<id>` via `Chat.PubSub` (SHARED with the presence branch).
  # Before this stage a switch A -> B silently abandoned both and overwrote
  # `:roster_space_id`, so nothing recorded what was held.
  #
  # HOW ARRIVAL IS OBSERVED. Not via `:roster_space_id` — the code under test
  # writes it, so reading it back would be circular. Instead each test renames
  # an agent DIRECTLY in the database (a plain `Repo.update!`, which emits no
  # broadcast of its own) and then broadcasts on the topic under test. The
  # shell answers any roster ping by recomputing the whole viewer union, so
  # the new name reaches `assigns.roster_items` IF AND ONLY IF the message was
  # delivered to the LiveView. Every absence assertion below is paired, in the
  # same test, with a delivery that MUST land.
  # REBASE NOTE (2026-08-19, onto 86ea77b0). This helper gained a `viewer`
  # argument and the `join_space!/2` call below. Task 01a011e6 stage 3 fenced
  # `visible_roster/2` to spaces the viewer holds a `participant_type: "user"`
  # row on, so the original fixture — which seeded a space and an agent but
  # never joined the viewer — now yields an EMPTY roster. Both tests below read
  # arrival through `roster_items`, so without the join every `roster_names/1`
  # call returns `[]` and the negative assertions would pass for the wrong
  # reason. The anti-vacuity assertions (`assert agent_a.name in
  # roster_names(view)`) caught it as a hard failure rather than letting it go
  # quiet. The FIXTURE was fixed, not the assertions: the tests are about
  # subscription release, and membership is a precondition they always intended
  # rather than anything they mean to vary.
  defp roster_probe_space!(name, slug_prefix, viewer) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: name, slug: "#{slug_prefix}-#{n}"})

    agent =
      Repo.insert!(%Agent{
        name: "#{slug_prefix}-bot-#{n}",
        slug: "#{slug_prefix}bot-#{n}",
        status: "active",
        runtime_type: "builtin"
      })

    Chat.set_principal_agent(space.id, agent.id)

    # The membership row the roster fence requires. Without it this space is
    # invisible to the viewer's meter no matter what is broadcast on its topics.
    join_space!(space, viewer)

    {space, agent}
  end

  defp roster_names(view) do
    _ = render(view)
    assigns = :sys.get_state(view.pid).socket.assigns

    case assigns.roster_items do
      %AsyncResult{ok?: true, result: items} when is_list(items) ->
        Enum.map(items, fn
          {%{agent: %{name: name}}, _status} -> name
          {%{name: name}, _status} -> name
          %{agent: %{name: name}} -> name
          %{name: name} -> name
        end)

      _ ->
        []
    end
  end

  describe "roster space switch releases the subscriptions it took out" do
    test "the previous space's space_agents topic stops being delivered, while the new one is",
         %{conn: conn} do
      # The viewer is resolved FIRST so each probe space can join it at
      # creation time — see the rebase note on `roster_probe_space!/3`.
      {conn, viewer} = authenticated_conn_with_user(conn)

      {space_a, agent_a} = roster_probe_space!("Roster Probe A", "test-shell-roster-a", viewer)
      {space_b, _agent_b} = roster_probe_space!("Roster Probe B", "test-shell-roster-b", viewer)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      # Drive the switch explicitly rather than relying on which space the
      # async loader happened to resolve first.
      send(view.pid, {:roster_resolved, space_a.id})
      send(view.pid, {:roster_resolved, space_b.id})
      _ = render(view)

      # ANTI-VACUITY: the agent we are about to rename is genuinely in the
      # viewer's union right now, so a later absence means "no refresh ran",
      # not "this agent was never visible".
      assert agent_a.name in roster_names(view)

      renamed = "renamed-#{System.unique_integer([:positive])}"
      Repo.update!(Ecto.Changeset.change(agent_a, name: renamed))

      # NEGATIVE. The LV released `space_agents:<A>` when it switched to B.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        "space_agents:#{space_a.id}",
        {:roster_changed, space_a.id}
      )

      refute renamed in roster_names(view),
             "a broadcast on the ABANDONED space_agents:<A> topic still reached the LiveView"

      # POSITIVE CONTROL, same test, same observable. If the rename simply
      # never surfaced in `roster_items` the refutation above would be
      # vacuous; this proves the observable can see it.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        "space_agents:#{space_b.id}",
        {:roster_changed, space_b.id}
      )

      assert renamed in roster_names(view),
             "a broadcast on the CURRENT space_agents:<B> topic did not reach the LiveView"
    end

    # THE OVERLAP CASE — the reason this stage exists.
    #
    # `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`: it drops EVERY
    # registration this pid holds for the topic. The presence branch subscribes
    # `chat:space:<id>` for every space in `:shell_chat_space_ids`, so releasing
    # the roster's chat subscription unconditionally would take presence's with
    # it — silently, with no error. That is how the unread badge died in
    # `cb429830`. This test fails if the release is made unconditional.
    test "a chat-topic broadcast on the previous space still arrives when presence holds it",
         %{conn: conn} do
      {conn, viewer} = authenticated_conn_with_user(conn)

      {space_a, agent_a} = roster_probe_space!("Overlap Probe A", "test-shell-overlap-a", viewer)
      {space_b, _agent_b} = roster_probe_space!("Overlap Probe B", "test-shell-overlap-b", viewer)

      # Space C is the NEGATIVE CONTROL and the viewer DELIBERATELY DOES NOT
      # JOIN IT — hence `nil` rather than `viewer`. Membership is not a
      # neutral detail here: the presence branch subscribes `chat:space:<id>`
      # for EVERY id in `Chat.list_member_space_ids/1`, which is
      # exactly "spaces the viewer holds a user row on". Joining C would
      # therefore put C's chat topic in this LV's subscribe set and the
      # broadcast below would legitimately arrive, collapsing the control.
      #
      # C is a space "this LiveView never subscribed", and that is a claim
      # about SUBSCRIPTION, not about roster visibility — so it neither needs
      # nor tolerates the membership row that spaces A and B require.
      {space_c, _agent_c} = roster_probe_space!("Overlap Probe C", "test-shell-overlap-c", nil)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      _html = render_async(view, 2_000)

      # Presence independently holds space A's chat topic.
      send(view.pid, {:presence_spaces_resolved, [space_a.id]})
      send(view.pid, {:roster_resolved, space_a.id})
      send(view.pid, {:roster_resolved, space_b.id})
      _ = render(view)

      assert space_a.id in (:sys.get_state(view.pid).socket.assigns[:shell_chat_space_ids] || [])
      assert agent_a.name in roster_names(view)

      renamed = "overlap-#{System.unique_integer([:positive])}"
      Repo.update!(Ecto.Changeset.change(agent_a, name: renamed))

      # The PROBE is a `{:roster_changed, _}` message published on the CHAT
      # topic. What is under test is delivery of that topic to this pid, not
      # the payload: the `:roster_updates` hook dispatches on message shape,
      # so a roster ping is simply the shape whose handling is observable in
      # `roster_items`. (`presence_diff`, the payload this topic really
      # carries, lands in `presence_list` instead and would not discriminate.)

      # NEGATIVE CONTROL, same observable: a space this LV never subscribed.
      # Without it the assertion below could pass on an observable that
      # refreshes for reasons of its own.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.Chat.PubSub.space_topic(space_c.id),
        {:roster_changed, space_c.id}
      )

      refute renamed in roster_names(view),
             "a broadcast on a chat topic this LiveView never subscribed still reached it"

      # Presence's own hold on space A must survive the roster switch.
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Platform.Chat.PubSub.space_topic(space_a.id),
        {:roster_changed, space_a.id}
      )

      assert renamed in roster_names(view),
             "the roster switch released a chat topic that :shell_chat_space_ids still holds"
    end
  end

  describe "top bar account menu" do
    test "collapses the username and log out into one avatar button", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      {:ok, view, _html} = live(conn, "/changelog")
      html = render(view)

      assert has_element?(
               view,
               ~s(#account-menu-trigger[aria-label="Account menu"][aria-haspopup="menu"][aria-expanded="false"])
             )

      assert has_element?(view, ~s(#account-menu-trigger [data-avatar-kind="human"]))

      # The Log out item is the SAME control as before: a plain GET link to
      # /auth/logout, no data-method, inside the menu.
      assert has_element?(
               view,
               ~s(#account-menu-list[role="menu"] a[role="menuitem"][href="/auth/logout"]),
               "Log out"
             )

      refute has_element?(view, ~s(#account-menu-list a[data-method]))
      assert has_element?(view, "#account-menu-list", user.name)
      assert has_element?(view, "#account-menu-list", user.email)

      # Exactly one logout link in the top bar, and it lives in the menu: the
      # old inline icon link and bare username span are gone.
      header = view |> element("header#utility-bar") |> render()
      assert length(Regex.scan(~r{href="/auth/logout"}, header)) == 1
      refute header =~ ~s(title="Log out")
      refute header =~ ~s(<span class="text-xs text-base-content/50">#{user.name}</span>)
      assert html =~ "account-menu-list"
    end
  end
end
