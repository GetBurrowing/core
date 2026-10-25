defmodule PlatformWeb.ChatLiveMainHeadTest do
  @moduledoc """
  Burrow redesign 22 stage 4: the conversation's desktop header is masters'
  main-pane header (master-desktop.html `.mhead` L732): `#chat-title` (into
  the details panel on All), the people subtitle, `#chat-search` (the
  panel's Search page), `#chat-call` and the `#chat-details` toggle. The old
  desktop header controls, the goal strip and the search and pins drawers
  are gone; Promote to channel is a details panel row for a group
  conversation; the desktop Members and Agents popovers sit under their
  panel rows; non-chat modules render no list pane; and every shell
  LiveView keeps a catch-all `handle_info/2`.

  Every absence sits beside a presence on the same fixture.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  @goal_flag :agents_goal_surface
  @head ~s([data-role="main-head"])

  setup do
    previous = Application.get_env(:platform, @goal_flag)
    on_exit(fn -> Application.put_env(:platform, @goal_flag, previous) end)
    :ok
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "main-head-#{tag}-#{n}@example.com",
      name: "Head #{tag} #{n}",
      oidc_sub: "oidc-main-head-#{tag}-#{n}"
    })
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "main-head-agent-#{n}",
      name: "#{name} #{n}",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp channel!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "head-room-#{n}", slug: "head-room-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  defp seat(space, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp seat_user(space, user), do: seat(space, "user", user.id, user.name)

  defp open_as(conn, user, path) do
    {:ok, view, _html} = conn |> init_test_session(current_user_id: user.id) |> live(path)
    view
  end

  defp at(conn, user, space), do: open_as(conn, user, "/chat/" <> Chat.space_path_segment(space))

  defp q(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(view, selector), do: view |> q(selector) |> Enum.count()
  defp text(view, selector), do: view |> q(selector) |> LazyHTML.text() |> String.trim()
  defp attr(view, selector, name), do: view |> q(selector) |> LazyHTML.attribute(name)

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp with_meetings(_context) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  describe "the main-pane header at lg" do
    setup :with_meetings

    test "carries the title, the subtitle, Search, Call and Details, in the lg-only branch",
         %{conn: conn} do
      user = user!("head")
      channel = channel!()
      seat_user(channel, user)
      seat_user(channel, user!("two"))
      seat_user(channel, user!("three"))
      view = at(conn, user, channel)

      # The lg-only branch; the phone header is the other branch.
      [classes] = attr(view, @head, "class")
      assert "hidden" in String.split(classes) and "lg:flex" in String.split(classes)

      # The header bar's lg paint (masters .mhead: 52px, base-100, edge).
      [bar] = attr(view, "header:has(#chat-title)", "class")

      for c <- ~w(lg:h-[52px] lg:px-4 lg:bg-base-100 lg:border-edge),
          do: assert(c in String.split(bar))

      assert text(view, "#{@head} #chat-title") == "#" <> channel.name
      assert count(view, "#{@head} #chat-title .hero-chevron-down") == 1
      assert attr(view, "#chat-title", "aria-controls") == ["details-panel"]
      assert text(view, ~s(#{@head} [data-role="chat-subtitle"])) == "3 people"

      assert text(view, "#{@head} #chat-search") == "Search"
      assert count(view, "#{@head} #chat-search .hero-magnifying-glass") == 1
      assert text(view, "#{@head} #chat-call") == "Call"
      assert count(view, "#{@head} #chat-call .hero-phone") == 1
      assert attr(view, "#chat-call", "phx-click") == ["meeting_join"]

      assert attr(view, "#{@head} #chat-details", "title") == ["Details"]
      assert attr(view, "#chat-details", "aria-controls") == ["details-panel"]
      assert attr(view, "#chat-details", "aria-pressed") == ["false"]
      assert count(view, "#chat-details .hero-view-columns") == 1

      # The phone header and its Call are unchanged beside it.
      assert count(view, ~s(button[data-role="space-title"])) == 1
      assert count(view, ~s(button[data-role="space-call"].lg\\:hidden)) == 1
    end

    test "Call is absent when meetings are off; Details stays",
         %{conn: conn} do
      user = user!("nocall")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)
      assert count(view, "#chat-call") == 1

      Application.put_env(:platform, :livekit, [])
      view = at(conn, user, channel)
      assert count(view, "#chat-details") == 1
      assert count(view, "#chat-call") == 0
    end

    test "none of the old desktop header, strip or drawers is left", %{conn: conn} do
      user = user!("gone")
      channel = channel!(%{topic: "a topic"})
      p = seat_user(channel, user)

      {:ok, m} =
        Chat.post_message(%{
          space_id: channel.id,
          participant_id: p.id,
          content_type: "text",
          content: "pin me"
        })

      Repo.insert!(%Chat.Pin{space_id: channel.id, message_id: m.id, pinned_by: p.id})
      view = at(conn, user, channel)
      assert count(view, "#chat-title") == 1

      for selector <- [
            "#chat-search-form",
            "header #promote-to-channel-form",
            ~s(header [phx-click="pin_panel_toggle"]),
            ~s(header [phx-click="canvas_panel_toggle"]),
            ~s([data-role="agents-goal-strip"]),
            ~s([data-role="desktop-space-title"]),
            ~s([data-role="members-open"]),
            ~s([data-role="agents-open"]),
            ~s(header [phx-click="settings_open"]),
            ".chat-header-scope-pill"
          ] do
        assert count(view, selector) == 0, "#{selector} is still rendered"
      end

      render_submit(view, "search_submit", %{"search" => %{"query" => "pin"}})
      html = render(view)
      refute html =~ "Search Results"
      refute html =~ "Pinned Messages"

      # The drawers are deleted, not hidden: no component renders them and no
      # state can open them.
      Code.ensure_loaded!(PlatformWeb.ChatLive.Partials.Conversation)

      for drawer <- [:search_drawer, :pins_drawer] do
        refute function_exported?(PlatformWeb.ChatLive.Partials.Conversation, drawer, 1),
               "#{drawer}/1 is back"
      end

      refute Map.has_key?(lv_assigns(view), :show_pins)
      assert Map.has_key?(lv_assigns(view), :pins)
    end
  end

  describe "the subtitle" do
    test "a channel adds its topic only while no goal renders", %{conn: conn} do
      Application.put_env(:platform, @goal_flag, true)
      user = user!("topic")

      plain = channel!(%{topic: "ship the header"})
      seat_user(plain, user)
      view = at(conn, user, plain)
      assert text(view, ~s([data-role="chat-subtitle"])) == "1 person · ship the header"

      goal =
        channel!(%{
          topic: "ship the header",
          goal: "Close backlog items",
          leader_agent_id: agent!("Lead").id
        })

      seat_user(goal, user)
      view = at(conn, user, goal)
      # Positive control: the goal really renders for this space.
      assert lv_assigns(view).goal_panel != nil
      assert text(view, ~s([data-role="chat-subtitle"])) == "1 person"
    end

    test "a DM reads direct, an agent DM reads agent, a group counts its people",
         %{conn: conn} do
      a = user!("a")
      b = user!("b")
      c = user!("c")

      {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)
      assert text(at(conn, a, dm), ~s([data-role="chat-subtitle"])) == "direct"

      agent = agent!("Pal")
      {:ok, agent_dm} = Chat.find_or_create_dm(a.id, "agent", agent.id)
      view = open_as(build_conn(), a, "/chat/" <> Chat.space_path_segment(agent_dm))
      assert text(view, ~s([data-role="chat-subtitle"])) == "agent"

      {:ok, group} =
        Chat.create_group_conversation(a.id, [
          %{type: "user", id: b.id},
          %{type: "user", id: c.id}
        ])

      view = open_as(build_conn(), a, "/chat/" <> Chat.space_path_segment(group))
      assert text(view, ~s([data-role="chat-subtitle"])) == "3 people"
    end
  end

  describe "the header opens the details panel" do
    test "Details toggles #details-panel on Space, and aria-pressed follows", %{conn: conn} do
      user = user!("toggle")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)
      assert count(view, "#details-panel") == 0

      view |> element("#chat-details") |> render_click()
      assert count(view, "#details-panel") == 1
      assert lv_assigns(view).details_panel == :space
      assert attr(view, "#chat-details", "aria-pressed") == ["true"]
      [pressed] = attr(view, "#chat-details", "class")
      assert "bg-base-300" in String.split(pressed) and "text-primary" in String.split(pressed)

      view |> element("#chat-details") |> render_click()
      assert count(view, "#details-panel") == 0
      assert attr(view, "#chat-details", "aria-pressed") == ["false"]
    end

    test "Search opens the panel's Search page", %{conn: conn} do
      user = user!("search")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)

      view |> element("#chat-search") |> render_click()
      assert lv_assigns(view).details_panel == :search
      assert count(view, ~s(#details-panel [data-page="search"] #details-search-form)) == 1
    end

    test "the title opens the panel on the All segment", %{conn: conn} do
      user = user!("title")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)

      view |> element("#chat-title") |> render_click()
      assert lv_assigns(view).details_panel == {:links, :all}
      assert count(view, ~s(#details-segs button[data-seg="all"][aria-selected="true"])) == 1
    end
  end

  describe "Promote to channel" do
    test "is a panel row for a group conversation only", %{conn: conn} do
      a = user!("pa")
      b = user!("pb")
      c = user!("pc")

      row =
        ~s(#details-panel [data-page="space"] form#promote-to-channel-form[phx-submit="promote_to_channel"])

      {:ok, group} =
        Chat.create_group_conversation(a.id, [
          %{type: "user", id: b.id},
          %{type: "user", id: c.id}
        ])

      view = open_as(conn, a, "/chat/" <> Chat.space_path_segment(group))
      render_click(view, "details_open", %{"page" => "space"})
      assert count(view, row) == 1
      assert text(view, row) =~ "Promote to channel"
      assert count(view, ~s(#{row} input[name="name"][required])) == 1

      channel = channel!()
      seat_user(channel, a)
      view = at(build_conn(), a, channel)
      render_click(view, "details_open", %{"page" => "space"})
      assert count(view, "#details-panel [data-role='details-hide']") == 1
      assert count(view, "#promote-to-channel-form") == 0

      {:ok, dm} = Chat.find_or_create_dm(a.id, "user", b.id)
      view = at(build_conn(), a, dm)
      render_click(view, "details_open", %{"page" => "space"})
      assert count(view, "#details-panel [data-role='details-close-dm']") == 1
      assert count(view, "#promote-to-channel-form") == 0
    end
  end

  describe "the desktop Members and Agents popovers" do
    # The popover slots render nothing (not a stray "false") where a row is
    # absent: found on the dev server, a channel with no agent printed
    # "false" under Members.
    test "an absent row's popover slot renders no text", %{conn: conn} do
      user = user!("noagent")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)
      render_click(view, "details_open", %{"page" => "space"})

      assert count(view, ~s(#details-panel [data-role="details-members"])) == 1
      assert count(view, ~s(#details-panel [data-role="details-agents"])) == 0
      refute text(view, ~s(#details-panel [data-page="space"])) =~ ~r/\b(false|true)\b/

      {:ok, dm} = Chat.find_or_create_dm(user.id, "user", user!("other").id)
      view = at(build_conn(), user, dm)
      render_click(view, "details_open", %{"page" => "space"})
      assert count(view, ~s(#details-panel [data-role="details-settings"])) == 1
      refute text(view, ~s(#details-panel [data-page="space"])) =~ ~r/\b(false|true)\b/
    end

    test "open under their panel rows", %{conn: conn} do
      user = user!("pop")
      channel = channel!()
      seat_user(channel, user)
      seat(channel, "agent", agent!("Helper").id, "Helper")
      view = at(conn, user, channel)
      render_click(view, "details_open", %{"page" => "space"})

      view |> element(~s(#details-panel [data-role="details-members"])) |> render_click()

      assert count(
               view,
               ~s(#details-panel [data-role="details-members"] + #chat-members-popover #members-popover)
             ) == 1

      view |> element(~s(#details-panel [data-role="details-agents"])) |> render_click()
      assert count(view, ~s(#details-panel [data-role="details-agents"] + #agents-popover)) == 1
    end

    test "the refused-summon View members opens a closed panel with the popover",
         %{conn: conn} do
      user = user!("refused")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)
      assert count(view, "#details-panel") == 0

      render_click(view, "members_open", %{"details" => "space"})
      assert lv_assigns(view).details_panel == :space
      assert count(view, "#details-panel #members-popover") == 1
      refute_push_event(view, "details:changed", %{open: true})
    end
  end

  describe "non-chat modules" do
    test "/tasks renders the sidebar and the page, with no list pane or details panel",
         %{conn: conn} do
      user = user!("tasks")
      view = open_as(conn, user, ~p"/tasks")

      assert count(view, "#sidebar") == 1
      assert count(view, "#chat-list") == 0
      assert count(view, "#details-panel") == 0
      assert count(view, "#chat-title") == 0
    end
  end

  # Rung 20 crashed a shell LiveView on a `{:new_message}` it had no clause
  # for. Every LiveView in the shell keeps a catch-all `handle_info/2`.
  describe "catch-all handle_info" do
    test "ChatLive survives an unknown message", %{conn: conn} do
      user = user!("catch-chat")
      channel = channel!()
      seat_user(channel, user)
      view = at(conn, user, channel)
      ref = Process.monitor(view.pid)

      # `{:new_message, _}` is one of ChatLive's own messages, so the unknown
      # ones here are shapes no clause names.
      send(view.pid, {:burrow_redesign_22_unknown, %{unknown: true}})
      send(view.pid, :burrow_redesign_22_unknown)

      assert render(view) =~ ~s(id="chat-title")
      refute_received {:DOWN, ^ref, _, _, _}
    end

    test "a non-chat shell LiveView (Changelog) survives an unknown message", %{conn: conn} do
      user = user!("catch-changelog")
      view = open_as(conn, user, ~p"/changelog")
      ref = Process.monitor(view.pid)

      send(view.pid, {:new_message, %{unknown: true}})
      send(view.pid, :burrow_redesign_22_unknown)

      assert render(view) =~ ~s(id="sidebar")
      refute_received {:DOWN, ^ref, _, _, _}
    end
  end
end
