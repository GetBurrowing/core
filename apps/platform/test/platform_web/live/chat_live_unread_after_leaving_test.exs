defmodule PlatformWeb.ChatLiveUnreadAfterLeavingTest do
  @moduledoc """
  Task 01a011e9: a channel that was visited and then left keeps its unread
  badge live for the rest of the session.

  `mount/3` subscribes the LiveView to every rail space exactly once, and that
  single registration per topic is what moves the badge on a channel nobody is
  looking at. Leaving used to unsubscribe and stop there, and
  `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2` — it drops EVERY
  entry the pid holds for that topic — so the space went silent and its badge
  froze at zero, which `clear_unread/2` had already set on the way in.

  HOW THE FIX IS SHAPED NOW (task 01a01a1b stage 3). 01a011e9 repaired this by
  unsubscribing and then conditionally re-subscribing, gated on the rail's own
  subscribe set. That workaround is deleted. Every `chat:space:<id>`
  subscription on the pid is held through `PlatformWeb.SpaceTopics` under a
  named owner, and leaving releases only `:chat_active` — the rail's
  `:chat_rail` hold keeps the topic registered, so there is no window in which
  the registration does not exist and nothing to restore. The end states this
  file measures are unchanged, which is the point of keeping it.

  The two assertions in the test below are a matched pair and neither stands
  alone. The never-visited channel is a positive control: it proves the
  harness can read a badge moving at all. Without it, a red on the
  visited-then-left channel is equally consistent with a test that cannot see
  badges. With it, the asymmetry — control green, visited-then-left red — is
  what identifies the dropped subscription.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  describe "unread badges after leaving a channel" do
    test "a visited-then-left channel still increments, and so does one never visited",
         %{conn: conn} do
      conn = authed(conn)

      # Three channels with no relationship to each other beyond being in the
      # viewer's rail. `visited` is the space under test, `elsewhere` is only
      # somewhere to navigate to, and `never_visited` is the control.
      visited = create_channel("larkspur")
      elsewhere = create_channel("marigold")
      never_visited = create_channel("nasturtium")

      {:ok, view, _html} = live(conn, ~p"/chat/#{Chat.space_path_segment(visited)}")

      # Both rail rows start with no pill at all, so the assertions at the end
      # are measuring a change rather than restating the fixture.
      assert unread_pill(render(view), visited) == nil
      assert unread_pill(render(view), never_visited) == nil

      # Leave. The rail rows use `patch`, so this is the same in-process
      # `handle_params/3` transition a click produces — the seam that holds
      # the teardown block.
      render_patch(view, ~p"/chat/#{Chat.space_path_segment(elsewhere)}")

      post_from_a_stranger(never_visited, "control fixture message")
      post_from_a_stranger(visited, "subject fixture message")

      html = render(view)

      # Control first, deliberately. On a regression this one still passes and
      # the next one fails, and that asymmetry is the finding.
      assert unread_pill(html, never_visited) == "1",
             "positive control: a channel this session never visited did not increment, " <>
               "so the harness cannot see badges move and the assertion below proves nothing"

      assert unread_pill(html, visited) == "1",
             "a channel this session visited and then left stopped incrementing: " <>
               "leaving dropped the mount-time PubSub subscription and never restored it"
    end

    test "leaving retains one registration for a rail space and none for a space off it",
         %{conn: conn} do
      # The badge test above measures the direction that was broken. This one
      # measures the registration count on both sides of the gate, because the
      # obvious wrong fix — drop the `unsubscribe` and stop — passes the badge
      # test and leaks in the other direction, and a space with no rail row has
      # no badge to read. Still load-bearing after task 01a01a1b: the
      # per-owner release has to produce BOTH of these end states, and an
      # implementation that released nothing would also pass the badge test.
      conn = authed(conn)

      in_rail = create_channel("larkspur")
      off_rail = create_execution_space("Fixture Execution Space")

      {:ok, view, _html} = live(conn, ~p"/chat/#{Chat.space_path_segment(in_rail)}")

      assert registrations(view, in_rail) == 1,
             "the :chat_rail and :chat_active holds should share exactly one registration"

      # Leave the rail channel for a space the rail does not list.
      render_patch(view, ~p"/chat/#{Chat.space_path_segment(off_rail)}")

      assert registrations(view, in_rail) == 1,
             "leaving a rail channel must leave the mount-time registration in place, once"

      assert registrations(view, off_rail) == 1

      # Now leave the off-rail space. It was never in the mount subscribe set,
      # so it must end on zero.
      render_patch(view, ~p"/chat/#{Chat.space_path_segment(in_rail)}")

      assert registrations(view, off_rail) == 0,
             "a space the rail never listed kept a subscription it never had at mount"

      assert registrations(view, in_rail) == 1
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp authed(conn) do
    user =
      Repo.insert!(%User{
        email: "unread-after-leaving-#{unique()}@example.com",
        name: "Unread Fixture Viewer",
        oidc_sub: "oidc-unread-after-leaving-#{unique()}",
        avatar_url: nil
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug) do
    {:ok, channel} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    channel
  end

  # A message from somebody who is not the viewer. `handle_info({:new_message,
  # _})` skips the increment for the viewer's own participant row, so the
  # author has to be a separate participant or the badge never moves and every
  # assertion here goes vacuously red.
  defp post_from_a_stranger(space, body) do
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

  # A space the rail never lists: not a channel, not a DM, and not pinned to
  # any task. Reachable only by typing its URL, which is exactly the case the
  # teardown's gate has to keep unsubscribed.
  defp create_execution_space(name) do
    {:ok, space} = Chat.create_space(%{name: name, kind: "execution"})
    space
  end

  defp unique, do: System.unique_integer([:positive])

  # How many PubSub registrations the LiveView process holds for a space's
  # topic. `Phoenix.PubSub.subscribe/2` is `Registry.register/3` on a
  # `keys: :duplicate` registry, so this counts entries rather than answering
  # a yes/no — which is the whole point: two entries fire `handle_info` twice.
  defp registrations(view, space) do
    Platform.PubSub
    |> Registry.lookup(Platform.Chat.PubSub.space_topic(space.id))
    |> Enum.count(fn {pid, _meta} -> pid == view.pid end)
  end

  # ── Assertions ──────────────────────────────────────────────────────────

  # Burrow redesign 22 stage 2 deleted the desktop channel rail: the badge is
  # now the Chat list row's unread count, scoped to `#chat-list-scroller`
  # because the search sheet and popover rows carry the same data-role.
  defp unread_pill(html, space) do
    pills =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space.id}"] [data-role="chat-list-unread-count"] [aria-hidden="true"])
      )

    case LazyHTML.to_tree(pills) do
      [] -> nil
      [_single] -> pills |> LazyHTML.text() |> String.trim()
      many -> flunk("expected at most one list badge for #{space.id}, found #{length(many)}")
    end
  end
end
