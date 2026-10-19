defmodule PlatformWeb.ChatLive.MessagesHooksTest do
  @moduledoc """
  Tests for `PlatformWeb.ChatLive.MessagesHooks`.

  Most stream-mutation helpers here are exercised via the chat LiveView
  integration tests (`PlatformWeb.ChatLiveTest`), which is the
  project's convention for hook code that needs a live socket. The
  tests in this file cover pure-function properties that don't need a
  configured stream — primarily empty-input short-circuits where the
  function must NOT touch the DB — plus targeted regression tests for
  stream-ordering behaviour where LV's integration harness is the most
  honest way to observe the actual stream output.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Phoenix.Component
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.ExternalUserFixtures
  alias Platform.Repo
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive.MessagesHooks

  describe "reinsert_stream_messages/3" do
    test "empty list returns socket unchanged without a DB call" do
      # Build a bare socket; if the function tried to hit the DB it would
      # crash with a NoConnectionError in this minimal setup because no
      # SQL Sandbox checkout has been done for the bare socket. So
      # "returns the socket" is itself the no-DB-call assertion.
      socket = %Phoenix.LiveView.Socket{}

      assert MessagesHooks.reinsert_stream_messages(socket, []) == socket
    end
  end

  # Task 01a0119e. `:rendered_message_ids` is a bare id set with no space in
  # it, so a caller entering space B can hand this function an id that still
  # belongs to space A. These tests read `streams.messages.inserts` directly:
  # what matters is which rows reached the stream, and an assertion that the
  # call merely "returned something" or "raised" would keep passing if the
  # filter were deleted and something else on the path happened to blow up.
  describe "reinsert_stream_messages/3 space filter" do
    setup do
      user = ExternalUserFixtures.create_user!()
      alpha = space_with_message!(user)
      beta = space_with_message!(user)

      %{alpha: alpha, beta: beta, socket: streaming_socket()}
    end

    test "an id belonging to another space never reaches the stream", ctx do
      result =
        MessagesHooks.reinsert_stream_messages(ctx.socket, [ctx.beta.message.id],
          space_id: ctx.alpha.space.id
        )

      assert inserted_ids(result) == []
    end

    test "an id from the space being written is inserted", ctx do
      result =
        MessagesHooks.reinsert_stream_messages(ctx.socket, [ctx.alpha.message.id],
          space_id: ctx.alpha.space.id
        )

      assert inserted_ids(result) == [ctx.alpha.message.id]
    end

    test "a mixed batch keeps only the rows of the space being written", ctx do
      result =
        MessagesHooks.reinsert_stream_messages(
          ctx.socket,
          [ctx.alpha.message.id, ctx.beta.message.id],
          space_id: ctx.beta.space.id
        )

      assert inserted_ids(result) == [ctx.beta.message.id]
    end

    test "omitting :space_id raises rather than writing unfiltered", ctx do
      # The unsafe call is the one that must be impossible to make by accident:
      # a caller that forgets the space gets a KeyError, not a silent bleed.
      assert_raise KeyError, fn ->
        MessagesHooks.reinsert_stream_messages(ctx.socket, [ctx.beta.message.id])
      end
    end

    test "a nil :space_id means nothing is on screen and inserts nothing", ctx do
      result =
        MessagesHooks.reinsert_stream_messages(ctx.socket, [ctx.alpha.message.id], space_id: nil)

      assert inserted_ids(result) == []
    end

    test "the re-fetch is scoped to the caller's external allowlist", ctx do
      # The ids come out of an in-memory MapSet, so this re-fetch is the only
      # membership check on the path. Built from a REAL external session rather
      # than a hand-made struct, so the test also pins that such a session
      # produces an external scope at all.
      outsider = ExternalUserFixtures.external_user!(Tenancy.get_org_by_slug!("globex"))
      scope = ExternalScope.for_user(outsider.id)
      assert %ExternalScope{external?: true} = scope

      socket = Component.assign(ctx.socket, :external_scope, scope)

      result =
        MessagesHooks.reinsert_stream_messages(socket, [ctx.alpha.message.id],
          space_id: ctx.alpha.space.id
        )

      assert inserted_ids(result) == []
    end
  end

  describe "clear_rendered_messages/1" do
    test "empties the id set, the day-label map and the day cursors" do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Component.assign(:rendered_message_ids, MapSet.new(["id-1", "id-2"]))
        |> Component.assign(:msg_day_labels, %{"id-1" => "2026-01-01"})
        |> Component.assign(:last_msg_day, "2026-01-01")
        |> Component.assign(:first_msg_day, "2025-12-31")

      cleared = MessagesHooks.clear_rendered_messages(socket)

      assert MapSet.size(cleared.assigns.rendered_message_ids) == 0
      assert cleared.assigns.msg_day_labels == %{}
      assert cleared.assigns.last_msg_day == nil
      assert cleared.assigns.first_msg_day == nil
    end
  end

  describe "active_space_id/1" do
    test "reads the open space, and is nil when none is open" do
      assert MessagesHooks.active_space_id(%Phoenix.LiveView.Socket{}) == nil

      socket = Component.assign(%Phoenix.LiveView.Socket{}, :active_space, %{id: "space-1"})
      assert MessagesHooks.active_space_id(socket) == "space-1"
    end
  end

  # A socket with the `:messages` stream configured but no LiveView process —
  # enough to observe what a stream write actually did. `stream/4` attaches an
  # `:after_render` hook, so `private.lifecycle` has to be present; a bare
  # `%Socket{}` carries only `live_temp`.
  defp streaming_socket do
    %Phoenix.LiveView.Socket{
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
    |> Phoenix.LiveView.stream(:messages, [])
  end

  defp inserted_ids(socket) do
    socket.assigns.streams.messages.inserts
    |> Enum.reverse()
    |> Enum.map(fn {_dom_id, _at, item, _limit, _update_only} -> item.id end)
  end

  defp space_with_message!(user) do
    space = ExternalUserFixtures.channel!()
    participant = ExternalUserFixtures.add_user!(space.id, user.id)
    message = ExternalUserFixtures.post!(space.id, participant.id, "fixture message")

    %{space: space, participant: participant, message: message}
  end

  # Regression for the "older batch renders inverted" bug
  # (infinite-scroll follow-up to task 019e18fc / PR #380): when the
  # user scrolls up and the next older page is fetched, the batch must
  # render in ASC `inserted_at` order at the top of the stream.
  #
  # Pre-fix, the helper iterated the ASC-ordered batch and called
  # `stream_insert(..., at: 0)` on each message. Consecutive `at: 0`
  # prepends REVERSE the input order (each new insert becomes the new
  # index 0, displacing the previous), so the batch landed with newest-
  # of-batch at the top — visually inverted vs. the rest of the
  # timeline.
  describe "load_older_messages/2 ordering" do
    test "older batch renders in ascending inserted_at order at top of stream",
         %{conn: conn} do
      user =
        Repo.insert!(%User{
          email: "older_order_test@example.com",
          name: "Older Order Test",
          oidc_sub: "oidc-older-order"
        })

      conn = init_test_session(conn, current_user_id: user.id)

      unique = System.unique_integer([:positive])

      {:ok, space} =
        Chat.create_space(%{
          name: "older-order-#{unique}",
          slug: "older-order-#{unique}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      # `@message_limit` is 50, so the initial mount loads the 50
      # newest messages. Seed 55 — the first 5 (oldest) become the
      # "older batch" that load_older_messages/2 must prepend on
      # scroll. UUIDv7 message ids sort lexicographically by time, so
      # post order == DB order (DESC by inserted_at == DESC by id).
      messages =
        for i <- 1..55 do
          {:ok, msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: participant.id,
              content_type: "text",
              content: "msg-#{String.pad_leading(Integer.to_string(i), 3, "0")}"
            })

          msg
        end

      # The first 5 posted are the oldest and should appear ONLY after
      # an older-batch load — they're not on the initial 50.
      older_batch_ids =
        messages
        |> Enum.take(5)
        |> Enum.map(& &1.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      # Sanity check: the older 5 messages must NOT yet be in the DOM
      # before the scroll-trigger; if they were, this test wouldn't be
      # exercising the load_older path.
      initial_html = render(view)

      Enum.each(older_batch_ids, fn id ->
        refute initial_html =~ ~s(data-message-id="#{id}"),
               "older-batch message #{id} unexpectedly rendered on initial mount"
      end)

      # Trigger the infinite-scroll handler. The bug, pre-fix, places
      # the newest-of-batch (msg-005) at the top of the stream and the
      # oldest-of-batch (msg-001) just below it — i.e. DESC within the
      # batch. The fix yields ASC: msg-001 at the very top, msg-005
      # immediately above the originally-rendered top.
      html = render_hook(view, "load_older_messages", %{})

      # Extract the rendered order of older-batch messages from the
      # HTML. Each chat row carries `data-message-id="<uuid>"`; the
      # batch must appear in the same order as `older_batch_ids`
      # (ASC by inserted_at, which equals post-order).
      rendered_order =
        Regex.scan(~r/data-message-id="([0-9a-f-]{36})"/, html)
        |> Enum.map(fn [_, id] -> id end)

      rendered_older =
        Enum.filter(rendered_order, &(&1 in older_batch_ids))

      assert rendered_older == older_batch_ids,
             """
             older batch is in the wrong order in the stream.
             expected (ASC by inserted_at): #{inspect(older_batch_ids)}
             got:                           #{inspect(rendered_older)}
             """
    end
  end
end
