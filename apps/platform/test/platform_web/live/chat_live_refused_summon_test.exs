defmodule PlatformWeb.ChatLiveRefusedSummonTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 2: the author-only notice
  shown when a channel member's `@[agent]` mention could not add the agent.

  The notice is delivered by a direct `send/2` to the author's own LiveView,
  so the load-bearing assertions are the pair: the AUTHOR's view renders
  `[data-role=refused-summon-notice]` with the exact copy, and a second
  member's view of the same message renders none. Each refute sits beside an
  assert that the same view DID render the message, so an empty page cannot
  pass it.

  The bracketed tokens are fixtures exercising the mention parser.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  @notice "[data-role=refused-summon-notice]"
  @channel_reason "Only a channel admin can bring agents into this channel."

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "refused-#{tag}-#{n}@example.com",
      name: "Refused #{tag} #{n}",
      oidc_sub: "oidc-refused-#{tag}-#{n}"
    })
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "refused-agent-#{n}",
      name: "#{name}#{n}",
      status: "active"
    })
  end

  defp channel! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_channel(%{name: "Refused #{n}", slug: "refused-#{n}"})
    space
  end

  defp live_as(conn, user, space) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    view
  end

  defp send_text(view, text) do
    view
    |> form("#compose-form", compose: %{text: text})
    |> render_submit()
  end

  # Whitespace-normalised text of the first node matching `selector`.
  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "a member's refused mention shows the author the notice with the exact copy",
       %{conn: conn} do
    space = channel!()
    agent = agent!("Helper")
    member = user!("member")
    view = live_as(conn, member, space)

    send_text(view, "@[#{agent.slug}] hi")

    assert has_element?(view, @notice)

    # The statement is one <p>; its text is exact. The meta line is flex
    # items (the gap is CSS), so its pieces are asserted one by one.
    assert text_of(view, "#{@notice} p") ==
             "@#{agent.name} was not added. #{@channel_reason}"

    assert text_of(view, "[data-role=refused-summon-visibility]") == "Only you can see this"
    assert text_of(view, "[data-role=refused-summon-dismiss]") == "Dismiss"

    assert has_element?(view, "#{@notice}[role=status]")
    # The notice must not carry `data-message-id`: scroll-to-message and
    # the context popover resolve rows with `[data-message-id="<id>"]`, and
    # an inline-thread reply has no row of its own, so its notice would be
    # the first match.
    refute has_element?(view, "#{@notice}[data-message-id]")
    assert has_element?(view, "[data-role=refused-summon-dismiss]")
  end

  test "another member viewing the same message sees no notice", %{conn: conn} do
    space = channel!()
    agent = agent!("Helper")
    author = user!("author")
    other = user!("other")

    other_view = live_as(Phoenix.ConnTest.build_conn(), other, space)
    author_view = live_as(conn, author, space)

    send_text(author_view, "@[#{agent.slug}] other-viewer-check")

    assert has_element?(author_view, @notice)
    # The message reached the second view (PubSub), so the refute below is
    # about the notice and not about an empty pane.
    assert render(other_view) =~ "other-viewer-check"
    refute has_element?(other_view, @notice)
  end

  test "Dismiss removes the notice and leaves the message", %{conn: conn} do
    space = channel!()
    agent = agent!("Helper")
    member = user!("member")
    view = live_as(conn, member, space)

    send_text(view, "@[#{agent.slug}] dismiss-me")
    assert has_element?(view, @notice)

    view |> element("[data-role=refused-summon-dismiss]") |> render_click()

    refute has_element?(view, @notice)
    assert render(view) =~ "dismiss-me"
  end

  test "two refused agents render ONE notice with joined names", %{conn: conn} do
    space = channel!()
    a = agent!("Alpha")
    b = agent!("Beta")
    member = user!("member")
    view = live_as(conn, member, space)

    send_text(view, "@[#{a.slug}] and @[#{b.slug}] help")

    html = render(view)
    assert length(Floki.find(Floki.parse_document!(html), @notice)) == 1

    assert text_of(view, "#{@notice} p") ==
             "@#{a.name} and @#{b.name} were not added. #{@channel_reason}"
  end

  test "three refused agents are joined with a comma and a final and", %{conn: conn} do
    space = channel!()
    [a, b, c] = Enum.map(["Alpha", "Beta", "Gamma"], &agent!/1)
    member = user!("member")
    view = live_as(conn, member, space)

    send_text(view, "@[#{a.slug}] @[#{b.slug}] @[#{c.slug}] help")

    assert text_of(view, "#{@notice} p") ==
             "@#{a.name}, @#{b.name} and @#{c.name} were not added. #{@channel_reason}"
  end

  test "a creator (channel admin) gets no notice and the agent is added", %{conn: conn} do
    creator = user!("creator")
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_channel(%{name: "Owned #{n}", slug: "owned-#{n}", created_by: creator.id})

    agent = agent!("Helper")
    view = live_as(conn, creator, space)

    send_text(view, "@[#{agent.slug}] admin-post")

    assert render(view) =~ "admin-post"
    refute has_element?(view, @notice)
    assert Enum.any?(Chat.list_participants(space.id), &(&1.participant_id == agent.id))
  end

  test "an inline thread reply shows the notice under the reply", %{conn: conn} do
    space = channel!()
    agent = agent!("Helper")
    member = user!("member")
    view = live_as(conn, member, space)

    send_text(view, "thread root")
    [root | _] = Chat.list_messages(space.id)

    render_click(view, "open_inline_thread", %{"message-id" => root.id})

    render_submit(view, "send_inline_thread_message", %{
      "inline_thread_compose" => %{
        "text" => "@[#{agent.slug}] in thread",
        "message_id" => root.id
      }
    })

    assert has_element?(view, "#inline-thread-#{root.id} #{@notice}")
  end
end
