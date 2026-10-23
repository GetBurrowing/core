defmodule PlatformWeb.ChatLiveDockTest do
  @moduledoc """
  Structure of the chat dock (task 01a15f2e-80cd-7000-8990-3b721f8bd938,
  stage 3).

  `#chat-dock` wraps the four contiguous siblings below the timeline: the
  streaming replies, the jump-to-latest anchor, the typing indicator and the
  composer. Its class is `chat-dock` everywhere (`display: contents`, so
  desktop and embedded chat keep their flex layout) plus `chat-dock--glass`
  on a ROUTED mount only; below lg that class makes it the glass overlay the
  phone timeline runs under (app.css; guarded by
  phone_chrome_clearance_guard_test.exs).

  Pinned here:

    * the dock's children are those four kinds, in that order, and nothing
      else, with every kind shown present at least once (anti-vacuity: an
      empty dock passes an "only these kinds" check);
    * `chat-dock--glass` is on a routed `/chat/:slug` mount and NOT on an
      embedded `ChatLive.Embedded` mount, with `chat-dock` and the
      `ChatDock` hook on both;
    * on an archived space the dock is present and the composer form absent.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  defp login(conn) do
    user =
      Repo.insert!(%User{
        email: "chat_dock_#{System.unique_integer([:positive])}@example.com",
        name: "Chat Dock User",
        oidc_sub: "oidc-chat-dock-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp join(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp new_space(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

    space
  end

  defp agent_participant(space) do
    agent =
      Repo.insert!(%Agent{
        slug: "dock-agent-#{System.unique_integer([:positive])}",
        name: "Dock Agent",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp doc(html), do: LazyHTML.from_document(html)
  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  # Each direct child of #chat-dock, classified. `:other` is anything that is
  # not one of the four kinds.
  defp dock_children(html) do
    html
    |> doc()
    |> LazyHTML.query("#chat-dock > *")
    |> Enum.map(fn node ->
      id = node |> LazyHTML.attribute("id") |> List.first() || ""
      class = node |> LazyHTML.attribute("class") |> List.first() || ""
      role = node |> LazyHTML.attribute("data-role") |> List.first() || ""
      typing = node |> LazyHTML.attribute("data-typing") |> List.first()
      classes = String.split(class)

      cond do
        id == "chat-streaming-replies" and elements?(node) ->
          :streaming

        id == "chat-streaming-replies" ->
          :streaming_idle

        id == "chat-jump-slot" and anchor?(node) ->
          :anchor

        id == "chat-jump-slot" ->
          :anchor_idle

        role == "typing-indicator" and typing == "true" ->
          :typing

        role == "typing-indicator" ->
          :typing_idle

        "compose-input-area" in classes ->
          :composer

        true ->
          {:other, id, class}
      end
    end)
  end

  # The streaming container and the typing indicator's wrapper are always
  # there (stage 5 of rung 10): `:*_idle` while empty. Each pair is one
  # slot, so the two share a rank.
  @order [
    [:streaming_idle, :streaming],
    [:anchor_idle, :anchor],
    [:typing_idle, :typing],
    :composer
  ]

  defp anchor?(node),
    do: node |> LazyHTML.query("#chat-jump-slot > .chat-jump-anchor") |> Enum.count() > 0

  defp elements?(node),
    do: node |> LazyHTML.query("#chat-streaming-replies > *") |> Enum.count() > 0

  defp in_order?(kinds) do
    ranks =
      Enum.map(kinds, fn kind ->
        Enum.find_index(@order, &(&1 == kind or (is_list(&1) and kind in &1)))
      end)

    Enum.all?(ranks, &is_integer/1) and ranks == Enum.sort(ranks)
  end

  describe "the dock's children" do
    test "streaming, anchor and composer, in that order, and nothing else", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-stream")
      join(space, user)
      agent = agent_participant(space)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      send(
        view.pid,
        {:agent_reply_chunk,
         %{
           space_id: space.id,
           chunk_id: "dock-chunk-1",
           text: "working on it",
           done: false,
           participant_id: agent.id
         }}
      )

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      kinds = dock_children(render(view))

      assert kinds == [:streaming, :anchor, :typing_idle, :composer]
      assert count(render(view), "#chat-dock > #chat-jump-slot > .chat-jump-anchor") == 1

      # The bubble is inside the container, never a sibling of the composer.
      html = render(view)
      assert count(html, "#chat-dock > #chat-streaming-replies > #streaming-dock-chunk-1") == 1
      assert count(html, "#chat-dock > [id^=streaming-]") == 0
      assert in_order?(kinds)
    end

    test "typing and composer, in that order (typing is suppressed while streaming)",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-typing")
      join(space, user)
      agent = agent_participant(space)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")
      assert dock_children(html) == [:streaming_idle, :anchor_idle, :typing_idle, :composer]

      send(
        view.pid,
        {:agent_typing, %{space_id: space.id, participant_id: agent.id, typing: true}}
      )

      kinds = dock_children(render(view))
      assert kinds == [:streaming_idle, :anchor_idle, :typing, :composer]
      assert in_order?(kinds)
    end

    # Gate case 7007 (stage 5): the indicator came and went as an `:if`
    # sibling directly before the composer area, so "Atlas is thinking…"
    # arriving ~60ms after an Enter send was a NEW node there; the DOM patch
    # re-added the composer area and the field blurred. The wrapper is now
    # one node with a DOM id (its morph key) whether or not anyone types.
    test "the typing indicator is one stable node, hidden while idle, typing or not",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-typing-stable")
      join(space, user)
      agent = agent_participant(space)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")

      wrapper = "#chat-dock > #chat-typing-indicator[data-role=typing-indicator]"
      before_composer = "#chat-typing-indicator + .compose-input-area"

      assert count(html, wrapper <> "[hidden][data-typing=false]") == 1
      assert count(html, "#chat-typing-indicator > *") == 0
      assert count(html, before_composer) == 1
      refute html =~ "is thinking"

      send(
        view.pid,
        {:agent_typing, %{space_id: space.id, participant_id: agent.id, typing: true}}
      )

      typing_html = render(view)
      assert count(typing_html, wrapper <> ":not([hidden])[data-typing=true]") == 1
      assert count(typing_html, before_composer) == 1
      assert typing_html =~ "is thinking"

      send(
        view.pid,
        {:agent_typing, %{space_id: space.id, participant_id: agent.id, typing: false}}
      )

      idle_html = render(view)
      assert count(idle_html, wrapper <> "[hidden][data-typing=false]") == 1
      assert count(idle_html, before_composer) == 1
      refute idle_html =~ "is thinking"
    end

    # Gate case 7007, round 2: the jump-to-latest anchor was an `:if` child of
    # #chat-dock with no id, so the chip appearing during a post-send patch
    # was a new node ahead of the typing indicator and the composer area; the
    # DOM patch re-appended both after it and the field blurred. The anchor
    # still leaves the DOM when hidden, but inside #chat-jump-slot.
    test "the jump anchor comes and goes inside #chat-jump-slot, never as a dock child",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-jump-slot")
      join(space, user)

      {:ok, view, html} = live(conn, ~p"/chat/#{space.slug}")
      assert count(html, "#chat-dock > #chat-jump-slot") == 1
      assert count(html, ".chat-jump-anchor") == 0

      shown = render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert count(shown, "#chat-dock > #chat-jump-slot > .chat-jump-anchor") == 1
      assert count(shown, "#chat-dock > .chat-jump-anchor") == 0

      hidden = render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})
      assert count(hidden, ".chat-jump-anchor") == 0
      assert count(hidden, "#chat-dock > #chat-jump-slot") == 1
    end

    test "the order predicate refuses a misordered or foreign child" do
      refute in_order?([:composer, :typing])
      refute in_order?([:streaming, {:other, "x", ""}, :composer])
      assert in_order?([:streaming, :streaming, :anchor, :typing, :composer])
    end
  end

  describe "glass on a routed mount only" do
    test "a routed /chat/:slug mount carries chat-dock--glass and the hook", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-routed")
      join(space, user)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#chat-drop-zone > #chat-dock.chat-dock[phx-hook=ChatDock]") == 1
      assert count(html, "#chat-dock.chat-dock--glass") == 1
    end

    test "an embedded mount carries chat-dock and the hook but not chat-dock--glass",
         %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-embedded")
      join(space, user)

      {:ok, _view, html} =
        live_isolated(conn, PlatformWeb.ChatLive.Embedded,
          session: %{"current_user_id" => user.id, "chat_space_slug" => space.slug}
        )

      assert count(html, "#chat-dock.chat-dock[phx-hook=ChatDock]") == 1
      assert count(html, "#chat-dock.chat-dock--glass") == 0
    end
  end

  describe "archived spaces" do
    test "the dock is present and the composer form is absent", %{conn: conn} do
      {conn, user} = login(conn)
      space = new_space("dock-archived")
      join(space, user)
      {:ok, space} = Chat.archive_space(space)

      {:ok, _view, html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(html, "#chat-drop-zone > #chat-dock") == 1
      assert count(html, "#chat-dock form#compose-form") == 0
      assert dock_children(html) == [:streaming_idle, :anchor_idle, :typing_idle, :composer]
    end
  end
end
