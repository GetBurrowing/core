defmodule PlatformWeb.ShellChatSubscribeSetTest do
  @moduledoc """
  Task `01a01f4c` stage 1 — a viewer with ZERO `org_memberships` rows, on a
  surface that is not `/chat`.

  ## Why this file exists and why it is not in `shell_live_test.exs`

  Every badge test in `shell_live_test.exs` runs on a `:root_all` viewer:
  its fixture seats the user on the root org, `Tenancy.root_member?/1` is true
  for any root membership whatever the role, and `Tenancy.scope(q, :root_all,
  _)` is the identity. So the org fence this task removes was already a no-op
  for every test that shipped before it, and removing it reddens NOTHING that
  exists. This file is the evidence for the change.

  ## The `/chat` trap

  These tests mount `~p"/tasks"`, and that is load-bearing rather than
  incidental. On `/chat`, `ChatLive.mount/3` subscribes every rail space
  through `presence_subscribe_space_ids/2`, which passes every id through for
  internal users, and a zero-org user IS internal: `Tenancy.external_user?/1`
  needs an `external == true` membership row and this viewer has no membership
  row at all. So a zero-org viewer's badge goes live on `/chat` against a
  completely unfixed build, and the same test written there would pass over the
  defect.

  ## Measurement discipline

  The badge is read from the RENDERED DOM (`data-role="chat-badge"`), not from
  `:chat_unread_count`, and the subscription is read from
  `Registry.lookup(Platform.PubSub, …)` filtered to the LiveView pid, not from
  `:shell_chat_space_ids`. Both of those assigns are written by the code under
  test, so reading them back to check it would be circular.

  ## A badge right at load is not a pass

  The two halves of this fix are independent and the load-time assertion only
  covers one of them. If the count were unfenced and `ShellLive` left alone,
  the badge would carry the right number at page load and no broadcast could
  ever move it, because the session would hold zero `chat:space:<id>`
  registrations. The live-post assertion is what separates those two states.

  `core` is PUBLIC: invented fixture names only.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo
  alias Platform.Tenancy

  describe "a viewer with no org membership, on /tasks" do
    setup %{conn: conn} do
      viewer =
        Repo.insert!(%User{
          email: "orgless_#{System.unique_integer([:positive])}@example.com",
          name: "Wren Wanderer",
          oidc_sub: "oidc-orgless-#{System.unique_integer([:positive])}"
        })

      # THE PRECONDITION THIS WHOLE FILE TURNS ON. Deliberately NO
      # `org_memberships` row. Without this assertion the tests below can pass
      # for an unrelated reason: `Tenancy.scope/3` is the identity at
      # `:root_all`, so a viewer who picked up a membership from a fixture
      # would exercise none of the change.
      assert Tenancy.visibility(viewer) == :none

      channel = channel!("larkspur")
      join!(channel, viewer)
      post_from_a_stranger(channel, "first unread")
      post_from_a_stranger(channel, "second unread")

      %{
        conn: init_test_session(conn, current_user_id: viewer.id),
        viewer: viewer,
        channel: channel
      }
    end

    test "the rail badge carries the pills' number, and a live post moves it", ctx do
      # The number the Chat sidebar's per-channel pill already shows. It has
      # never been org-fenced, which is why it was right while the badge was
      # blank.
      counts = Chat.unread_counts_for_user(ctx.viewer.id)
      assert Map.get(counts, ctx.channel.id) == 2

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      settle(view)

      # HALF ONE: the count. Before this change the badge node was absent
      # entirely and this read returned "".
      assert badge_numeral(view) == "2"
      assert badge_numeral(view) == to_string(counts |> Map.values() |> Enum.sum())

      # HALF TWO, and the half a load-time assertion cannot see: the session
      # actually holds the topic. Read off the registry rather than off
      # `:shell_chat_space_ids`, which the branch under test writes.
      assert holder_count(view, ctx.channel.id) > 0,
             "the session holds no chat:space:<id> registration for a channel it participates in"

      # HALF TWO, observed as behaviour. A badge that is right at load and does
      # not move here is a FAILURE, not a partial pass: it means the count was
      # unfenced and the subscribe set was not.
      post_from_a_stranger(ctx.channel, "third unread, posted live")
      barrier(view)

      assert badge_numeral(view) == "3",
             "the badge did not move on a live post, so the shell is not subscribed to the space it is counting"
    end

    test "a channel the viewer does not participate in moves nothing", ctx do
      # POSITIVE-CONTROL PAIR for the test above. A build that dropped the
      # membership predicate along with the org fence passes every assertion
      # there and fails here.
      stranger_channel = channel!("mulberry")
      post_from_a_stranger(stranger_channel, "not this viewer's business")

      {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
      settle(view)

      assert badge_numeral(view) == "2"
      assert holder_count(view, stranger_channel.id) == 0

      post_from_a_stranger(stranger_channel, "still not this viewer's business")
      barrier(view)

      assert badge_numeral(view) == "2"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # The badge numeral as the browser would read it. `""` is the real "no badge"
  # answer: `rail_badge/1`'s `:if` drops the node from the DOM at zero rather
  # than rendering an empty pill.
  defp badge_numeral(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(~s([data-role="chat-badge"]))
    |> Floki.text()
    |> String.trim()
  end

  # Registrations THIS LiveView pid holds on the space's chat topic. The
  # registry is the fact; the assign is the claim.
  defp holder_count(view, space_id) do
    Platform.PubSub
    |> Registry.lookup(ChatPubSub.space_topic(space_id))
    |> Enum.count(fn {pid, _} -> pid == view.pid end)
  end

  # The subscribe happens only once `assign_async` has resolved AND the
  # LiveView has processed `{:presence_spaces_resolved, _}`. Posting before
  # that races the registration and flakes.
  defp settle(view) do
    render_async(view, 2_000)
    _ = render(view)
    :ok
  end

  # TWO barriers, and the second is not redundant. The first `render/1` lets
  # the process handle `{:new_message, _}`, which only QUEUES the refresh; the
  # queued `:chat_unread_refresh` is still behind it in the mailbox.
  defp barrier(view) do
    _ = render(view)
    _ = render(view)
    :ok
  end

  defp channel!(slug) do
    {:ok, channel} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    channel
  end

  defp join!(channel, user) do
    {:ok, participant} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Wren Wanderer",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # The author must not be the viewer: `count_unread/3` excludes
  # `m.participant_id != participant_pk`, so a self-authored message moves
  # nothing and the assertions would pass vacuously.
  defp post_from_a_stranger(space, body) do
    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Ozgur Onlooker",
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
end
