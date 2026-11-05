defmodule PlatformWeb.NewConversationGroupDedupeTest do
  @moduledoc """
  The new-conversation modal reopens an existing group for the same people
  (task 01a1acea, stage 1). The component already calls
  `Chat.create_group_conversation/3`; this drives it through the LiveView for
  two users who pick the same set in different orders.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  @component "#chat-new-conversation"

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "new-convo-#{n}@example.com",
      name: "Dev #{label} #{n}",
      oidc_sub: "oidc-new-convo-#{n}"
    })
  end

  # A channel both starters sit in. A deep link mounts ChatLive directly;
  # a bare `/chat` sends a first-run member to `/start`.
  defp lobby!(users) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_channel(%{name: "Dev lobby #{n}", slug: "dev-lobby-#{n}"})

    for user <- users do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  # Opens the modal as `user`, picks `others` in the given order, submits,
  # and returns the path the LiveView navigated to.
  defp start_group(conn, lobby, user, others) do
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/chat/#{lobby.slug}")

    render_click(view, "new_conversation_open", %{})
    assert has_element?(view, "#{@component} h3", "New Conversation")

    for other <- others do
      view
      |> with_target(@component)
      |> render_click("new_conversation_toggle", %{"type" => "user", "id" => other.id})
    end

    view |> with_target(@component) |> render_click("new_conversation_submit", %{})
    {path, _flash} = assert_redirect(view)
    path
  end

  defp groups_for(user_ids) do
    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id,
      where: s.kind == "group" and p.participant_type == "user" and p.participant_id in ^user_ids,
      group_by: s.id,
      having: count(p.id) == ^length(user_ids),
      select: s.id
    )
    |> Repo.all()
  end

  test "A picks [B, C], then B picks [C, A]: both land in the same group", %{conn: conn} do
    a = user!("Alice")
    b = user!("Bob")
    c = user!("Carol")
    lobby = lobby!([a, b])

    path_a = start_group(conn, lobby, a, [b, c])
    assert [group_id] = groups_for([a.id, b.id, c.id])
    assert path_a == "/chat/#{group_id}"

    path_b = start_group(build_conn(), lobby, b, [c, a])
    assert path_b == path_a
    assert groups_for([a.id, b.id, c.id]) == [group_id]

    b_groups =
      b.id
      |> Chat.list_user_conversations()
      |> Enum.filter(&(&1.kind == "group"))

    assert Enum.map(b_groups, & &1.id) == [group_id]
  end
end
