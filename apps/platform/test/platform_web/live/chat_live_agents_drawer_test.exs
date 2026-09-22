defmodule PlatformWeb.ChatLiveAgentsDrawerTest do
  @moduledoc """
  Render coverage for the Agents block mirrored into the MOBILE channel-browser
  drawer (task `01a0b491-0718-7001-8bba-bf50f119bb13`, v2 stage 1).

  v1 put the block on the desktop rail only, and the rail is `hidden lg:flex`,
  so on a phone the Agents space had no nav row at all. These cases address the
  drawer's own DOM tree — `data-role="agents-drawer-block"`, not the rail's
  `agents-rail-block`, which sits in the same HTML and would satisfy a sloppy
  assertion while the drawer stayed empty.

  Ordering is asserted on RELATIVE BYTE POSITION, not on presence: a row
  rendered at the bottom of the drawer is present and wrong.

  The two search cases are each other's positive control. The matches-nothing
  case alone passes for a row that never renders; the Agents-only case alone
  passes for a row that ignores search entirely.

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    :ok
  end

  defp enable_flag, do: Application.put_env(:platform, @flag_key, true)
  defp disable_flag, do: Application.put_env(:platform, @flag_key, false)

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agents_drawer_#{n}@example.com",
        name: "Agents Drawer Test User",
        oidc_sub: "oidc-agents-drawer-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_agent(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "agents-drawer-#{n}", name: name, status: "active"})
  end

  defp create_space(attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{name: "Agents #{n}", slug: "agents-drawer-space-#{n}", kind: "channel"},
          Map.new(attrs)
        )
      )

    space
  end

  defp add_user(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  defp open_drawer(view) do
    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()
  end

  defp search(view, query) do
    view
    |> element(~s(#mobile-channel-browser form[phx-change="drawer_search"]))
    |> render_change(%{"value" => query})
  end

  # The drawer and the desktop rail are BOTH in this HTML. Slice to the drawer
  # so nothing here can be satisfied by the rail's copy of the block.
  defp drawer_html(html) do
    case String.split(html, ~s(id="mobile-channel-browser"), parts: 2) do
      [_, rest] -> rest
      [only] -> only
    end
  end

  describe "the drawer carries the Agents block" do
    test "it renders and precedes the Pinned section by byte position", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      pinned = create_space(name: "pinned-control")
      add_user(pinned, user)
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      drawer = drawer_html(open_drawer(view))

      assert drawer =~ ~s(data-role="agents-drawer-block")
      assert drawer =~ ~s(data-role="agents-drawer-row")

      agents_at = :binary.match(drawer, ~s(data-role="agents-drawer-block")) |> elem(0)
      pinned_at = :binary.match(drawer, ~s(aria-label="Pinned")) |> elem(0)

      assert agents_at < pinned_at,
             "Agents block must precede the Pinned section in the drawer " <>
               "(agents at #{agents_at}, pinned at #{pinned_at})"
    end

    test "the row closes the drawer when tapped", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      drawer = drawer_html(open_drawer(view))

      [_, row] = String.split(drawer, ~s(data-role="agents-drawer-row"), parts: 2)
      row_head = String.slice(row, 0, 400)
      preceding = drawer |> String.split(~s(data-role="agents-drawer-row")) |> hd()

      assert String.contains?(preceding <> row_head, ~s(phx-click="close_mobile_browser")),
             "the Agents drawer row must carry phx-click=close_mobile_browser"
    end

    test "the leader's avatar is the row's only weight", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      drawer = drawer_html(open_drawer(view))

      assert drawer =~ ~s(data-role="agents-drawer-row-glyph")
      assert drawer =~ "Dalton leads"
      assert drawer =~ "ring-2 ring-focus-ring"
    end

    test "no leader renders the empty glyph column and no stand-in face", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      drawer = drawer_html(open_drawer(view))

      assert drawer =~ ~s(data-role="agents-drawer-row-glyph")

      [_, glyph] = String.split(drawer, ~s(data-role="agents-drawer-row-glyph"), parts: 2)
      refute glyph |> String.slice(0, 200) =~ "ring-2 ring-focus-ring"
    end
  end

  describe "the flag gates the drawer block" do
    test "with the flag unset nothing renders above Pinned — no empty container", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      disable_flag()

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      drawer = drawer_html(open_drawer(view))

      refute drawer =~ ~s(data-role="agents-drawer-block")
      refute drawer =~ ~s(data-role="agents-drawer-row")
      refute drawer =~ ~s(data-role="agents-drawer-row-glyph")
      refute drawer =~ ~s(aria-label="Agents")
    end
  end

  describe "drawer search and the No matches state" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      space =
        create_space(
          name: "Agents Zyxwv",
          goal: "Close backlog items in Suite",
          leader_agent_id: agent.id
        )

      add_user(space, user)

      pinned = create_space(name: "pinned-control")
      add_user(pinned, user)
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      open_drawer(view)

      %{view: view}
    end

    test "a query matching only the Agents space renders the row and no No-matches copy", %{
      view: view
    } do
      drawer = drawer_html(search(view, "Zyxwv"))

      assert drawer =~ ~s(data-role="agents-drawer-row")
      refute drawer =~ "No matches for"
    end

    test "a query matching nothing renders the No-matches copy and no Agents row", %{view: view} do
      drawer = drawer_html(search(view, "qqzzjjnomatch"))

      assert drawer =~ "No matches for"
      refute drawer =~ ~s(data-role="agents-drawer-row")
      refute drawer =~ ~s(data-role="agents-drawer-block")
    end
  end
end
