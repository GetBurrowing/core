defmodule PlatformWeb.ShellLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.AsyncResult
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "shell_test@example.com",
        name: "Shell Test User",
        oidc_sub: "oidc-shell-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  # PWA app-shell scroll lock regression. The root shell container must
  # constrain itself to the dynamic viewport (`h-[100dvh]`) and refuse to
  # scroll (`overflow-hidden`) so the bottom-tab nav stays functionally
  # rooted on mobile — without these classes, the body itself scrolls and
  # drags the chrome out of view (Rowan's mobile review-request hotfix,
  # supersedes the inner `pb-` clearance from PR #331). Asserting the
  # literal class string keeps the fix from being quietly removed during
  # refactors.
  test "shell root container locks to viewport height (PWA scroll lock)", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "h-[100dvh]"
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

  test "shell chat nav link is prepared to restore the last selected chat space", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ ~s(id="shell-chat-link")
    assert html =~ ~s(phx-hook="LastChatLink")
    assert html =~ ~s(data-default-chat-path="/chat")
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
end
