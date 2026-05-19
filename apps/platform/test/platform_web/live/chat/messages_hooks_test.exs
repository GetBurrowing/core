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

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MessagesHooks

  describe "reinsert_stream_messages/2" do
    test "empty list returns socket unchanged without a DB call" do
      # Build a bare socket; if the function tried to hit the DB it would
      # crash with a NoConnectionError in this minimal setup because no
      # SQL Sandbox checkout has been done for the bare socket. So
      # "returns the socket" is itself the no-DB-call assertion.
      socket = %Phoenix.LiveView.Socket{}

      assert MessagesHooks.reinsert_stream_messages(socket, []) == socket
    end
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
