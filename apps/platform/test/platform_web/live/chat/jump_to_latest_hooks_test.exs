defmodule PlatformWeb.ChatLive.JumpToLatestHooksTest do
  @moduledoc """
  Server-side state for the jump-to-latest control (task `01a03c76`
  stage 1). Nothing renders yet — stage 1 lands the assigns and the two
  `handle_event/3` clauses that drive them, and this file pins their
  behaviour before any template depends on it.

  Why the state is server-side at all: the acceptance criterion for the
  control is that the node is ABSENT from the DOM when there is nothing
  to jump to. A `:if` over a server assign gives a LiveView test a real
  absence assertion. A JS-toggled class is only assertable as
  `opacity: 0` / `hidden`, which keeps passing while the actual defect —
  an unreachable-but-present node still in the accessibility tree and
  still swallowing taps — persists. So the count and the away-flag are
  socket assigns, not client state.

  Why the 150px threshold is NOT here: `NEAR_BOTTOM_PX` lives in
  `assets/js/hooks/scroll_to_bottom.js`. The hook compares and pushes a
  BOOLEAN (`%{"away" => true | false}`); the server never sees a pixel
  distance. Duplicating the number server-side would create two
  definitions that drift. The tests below therefore drive the boolean
  directly, which is the real wire payload.

  These tests reach into `:sys.get_state(view.pid).socket.assigns`
  rather than asserting on markup, because in stage 1 there is by
  construction no markup to assert on. Stage 2 adds the rendering and
  its own absence tests.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MessagesHooks

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "jump_test_#{System.unique_integer([:positive])}@example.com",
        name: "Jump Test User",
        oidc_sub: "oidc-jump-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp other_user! do
    Repo.insert!(%User{
      email: "jump_other_#{System.unique_integer([:positive])}@example.com",
      name: "Someone Else",
      oidc_sub: "oidc-jump-other-#{System.unique_integer([:positive])}"
    })
  end

  defp ensure_space(slug) do
    Chat.get_space_by_slug(slug) ||
      elem(Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"}), 1)
  end

  # `Chat.add_participant/2` strictly inserts, so re-adding the same user
  # errors — look the existing row up instead (mirrors the helper in
  # `scroll_to_bottom_test.exs`).
  defp participant_for(space, user) do
    case Chat.add_participant(space.id, %{
           participant_type: "user",
           participant_id: user.id,
           display_name: user.name || user.email,
           joined_at: DateTime.utc_now()
         }) do
      {:ok, p} ->
        p

      {:error, _changeset} ->
        Enum.find(Chat.list_participants(space.id), fn p ->
          p.participant_type == "user" and p.participant_id == user.id
        end) || raise "no participant row for user #{user.id} in space #{space.id}"
    end
  end

  defp post_message(space, user, content, opts \\ []) do
    participant = participant_for(space, user)

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content,
        thread_id: Keyword.get(opts, :thread_id)
      })

    message
  end

  # `Chat.post_message/1` already broadcasts `{:new_message, msg}`, and the
  # local PubSub adapter dispatches to local subscribers in the CALLING
  # process — so by the time it returns, the message is already in the
  # LiveView's mailbox. Do NOT also `send/2` it by hand: an earlier draft of
  # this file did, and every foreign message counted twice.
  #
  # `render/1` is then the sync barrier: it is a call into the same process
  # and so cannot be served until the `:new_message` ahead of it is handled.
  defp sync(view) do
    _ = render(view)
    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Read back from the single source of truth rather than restated, so the
  # boundary tests below move with the cap instead of pinning today's ruling.
  @cap MessagesHooks.jump_count_cap()

  defp expected_label(n) when is_integer(n) do
    if n > @cap, do: "#{@cap}+", else: Integer.to_string(n)
  end

  defp count(view), do: assigns(view)[:jump_new_message_count]

  describe "jump-to-latest counter" do
    test "starts at zero with the away-flag false", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("jump-seed-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "a message so the space is not empty")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      assert count(view) == 0
      assert assigns(view)[:jump_away_from_bottom] == false
    end

    test "does not increment while the reader is at the tip", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-at-tip-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      # Explicitly report "not away" — this is the payload the hook sends
      # when the scroll position is within NEAR_BOTTOM_PX of the bottom.
      render_hook(view, "jump_to_latest_distance", %{"away" => false})
      assert assigns(view)[:jump_away_from_bottom] == false

      _ = post_message(space, other, "arrives while you are at the tip")
      sync(view)

      assert count(view) == 0,
             "a message that lands while the reader is already at the bottom needs no " <>
               "jump affordance — counting it would render the control over a message " <>
               "that is already on screen"
    end

    test "increments once per foreign message while away from the tip", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-away-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      assert assigns(view)[:jump_away_from_bottom] == true

      _ = post_message(space, other, "first while away")
      sync(view)
      assert count(view) == 1

      # Second arrival: pins that the counter accumulates rather than
      # latching at 1. A `max(count, 1)` implementation would pass a
      # single-message test and still render "1" for a burst of ten.
      _ = post_message(space, other, "second while away")
      sync(view)
      assert count(view) == 2
    end

    test "the reader's own message never increments, even while away", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-own-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      _ = post_message(space, user, "my own message")
      sync(view)

      assert count(view) == 0,
             "sending a message snaps you to the bottom, so your own message can never " <>
               "be something you need to jump down to"

      # Positive control in the same run and the same away-state: a
      # foreign message DOES count. Without this the assertion above is
      # satisfied by a counter that never increments at all.
      _ = post_message(space, other, "someone else's message")
      sync(view)
      assert count(view) == 1
    end

    test "a thread reply never increments", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-thread-#{System.unique_integer([:positive])}")
      parent = post_message(space, user, "the parent message")

      {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      reply = post_message(space, other, "a reply in the thread", thread_id: thread.id)
      refute is_nil(reply.thread_id), "fixture precondition: the reply must carry a thread_id"

      sync(view)

      assert count(view) == 0,
             "thread replies do not appear in the main timeline, so jumping to the " <>
               "bottom of it would not reveal them"

      # Positive control: a top-level message from the same sender in the
      # same away-state does count, so the refutation above is about the
      # thread_id and not about the away-flag having been lost.
      _ = post_message(space, other, "a top-level message")
      sync(view)
      assert count(view) == 1
    end

    test "pressing jump_to_latest clears the count", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-press-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      _ = post_message(space, other, "something to jump to")
      sync(view)
      assert count(view) == 1

      render_hook(view, "jump_to_latest", %{})

      assert count(view) == 0
    end

    test "entering a different space resets the count", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      suffix = System.unique_integer([:positive])
      space_a = ensure_space("jump-reset-a-#{suffix}")
      space_b = ensure_space("jump-reset-b-#{suffix}")
      _ = post_message(space_a, user, "seed a")
      _ = post_message(space_b, user, "seed b")

      refute space_a.id == space_b.id,
             "fixture precondition: the two spaces must be distinct or the patch below " <>
               "is not a space change"

      {:ok, view, _html} = live(conn, ~p"/chat/#{space_a.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      _ = post_message(space_a, other, "unread in the first space")
      sync(view)
      assert count(view) == 1

      _ = render_patch(view, ~p"/chat/#{space_b.slug}")

      assert count(view) == 0,
             "the count describes the space you left; carrying it across would show a " <>
               "pill in a conversation whose tip you are already at"
    end
  end

  describe "jump-to-latest chip rendering" do
    # Every absence assertion below is PAIRED with a positive control in the
    # same test — render the away state, assert present; render the bottom
    # state, assert absent. An unpaired `refute has_element?` passes just as
    # happily when the selector is misspelled, the route 404s, or the
    # LiveView never mounted, so on its own it is not evidence of anything.
    #
    # The assertions are on the ELEMENT, never on an `opacity: 0` or a
    # hidden class. That distinction is the whole acceptance criterion: a
    # transparent node is still in the accessibility tree and still swallows
    # taps over the composer, so a test that accepts `opacity: 0` as
    # "hidden" keeps passing through exactly the defect it is meant to catch.

    test "the chip is absent at the tip and present once the reader scrolls away",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("jump-chip-vis-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      # Positive control: the chip really does render, so the refutation
      # below is about the away-flag and not about a bad selector.
      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      assert has_element?(view, "button.chat-jump-chip")
      assert has_element?(view, "button.chat-jump-chip[phx-click='jump_to_latest']")
      assert render(view) =~ "Jump to latest"

      render_hook(view, "jump_to_latest_distance", %{"away" => false})

      refute has_element?(view, "button.chat-jump-chip"),
             "at the bottom of the conversation the control must LEAVE THE DOM — a " <>
               "transparent or zero-width node still takes taps over the composer"

      refute render(view) =~ "Jump to latest"
    end

    test "the badge is absent at zero and present at one, with the label unchanged",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-badge-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      # Scrolled up with nothing new: chip yes, badge no. The chip's own
      # presence is the positive control for this refutation.
      assert has_element?(view, "button.chat-jump-chip")

      refute has_element?(view, ".chat-jump-chip-count"),
             "with no new messages there is no count to show, and an empty badge would " <>
               "be a saturated pixel announcing nothing"

      _ = post_message(space, other, "one arrives while you are away")
      sync(view)

      assert count(view) == 1
      assert has_element?(view, ".chat-jump-chip-count", "1")

      # The label is still there and still first: the badge grows the chip
      # rightward into empty space rather than shoving the words sideways.
      assert has_element?(view, "button.chat-jump-chip")
      assert render(view) =~ "Jump to latest"
    end

    test "the accessible name carries the count as a sentence, singular at one",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-aria-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      assert has_element?(
               view,
               "button.chat-jump-chip[aria-label='Jump to latest message.']"
             )

      _ = post_message(space, other, "first")
      sync(view)

      assert has_element?(
               view,
               "button.chat-jump-chip[aria-label='Jump to latest message. 1 new message.']"
             )

      _ = post_message(space, other, "second")
      sync(view)

      assert has_element?(
               view,
               "button.chat-jump-chip[aria-label='Jump to latest message. 2 new messages.']"
             )
    end

    test "pressing the chip clears the count and removes the badge", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-press-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      _ = post_message(space, other, "something to catch up on")
      sync(view)
      assert has_element?(view, ".chat-jump-chip-count", "1")

      view |> element("button.chat-jump-chip") |> render_click()

      assert count(view) == 0

      refute has_element?(view, ".chat-jump-chip-count"),
             "the press is the catch-up: leaving the badge behind would claim there is " <>
               "still something unseen"

      # The chip itself is still rendered here on purpose. Presence tracks
      # the scroll position, which only the client can report, and the
      # client has not reported yet — the two predicates are independent.
      assert has_element?(view, "button.chat-jump-chip")
    end
  end

  describe "jump-to-latest count label (stage 4)" do
    # Every assertion here is written against `MessagesHooks.jump_count_cap/0`
    # rather than against the literal 99. The cap is an OPEN question — the
    # design canvas says `99+`, Chat's icon-rail badge says `9+`, and the
    # ruling is still out. Pinning "99+" in each assertion would mean the
    # one-line answer costs an edit in every test, which is exactly the
    # pressure that turns a single constant into two drifting ones.
    #
    # What these tests DO pin, and what survives either ruling: that the
    # label is the number itself at and below the cap, and `"<cap>+"` strictly
    # above it. The `cap` and `cap + 1` cases are the boundary; `cap - 1` is
    # the interior control that stops an off-by-one (`>=` instead of `>`)
    # from passing.

    test "the cap is a positive integer" do
      assert is_integer(@cap) and @cap > 1,
             "the boundary cases below are only meaningful if there is a real " <>
               "threshold with room beneath it"
    end

    test "counts of 1 and 12 render as themselves" do
      assert MessagesHooks.jump_count_label(1) == "1"
      assert MessagesHooks.jump_count_label(12) == "12"
    end

    test "99 and 100 straddle whichever cap is ruled" do
      # Stated as the RULE, not as today's strings: under the canvas's 99 the
      # first is "99" and the second "99+"; under the rail's 9 both are "9+".
      # Both readings are correct for this assertion, and flipping the
      # constant does not touch this file.
      assert MessagesHooks.jump_count_label(99) == expected_label(99)
      assert MessagesHooks.jump_count_label(100) == expected_label(100)

      refute MessagesHooks.jump_count_label(100) == "100" and @cap < 100,
             "a count above the cap must never render in full"
    end

    test "the label saturates exactly one above the cap, not at it" do
      assert MessagesHooks.jump_count_label(@cap) == Integer.to_string(@cap),
             "the cap itself fits and must be shown in full"

      assert MessagesHooks.jump_count_label(@cap + 1) == "#{@cap}+"

      assert MessagesHooks.jump_count_label(@cap - 1) == Integer.to_string(@cap - 1)
    end

    test "the accessible name speaks the full count even when the badge is capped" do
      # The badge saturates; the sentence does not. "99+ new messages" is not
      # a sentence, and a screen-reader user gets no way to see the number
      # any other way — the badge is aria-hidden.
      assert MessagesHooks.jump_aria_label(@cap + 1) =~ "#{@cap + 1} new messages"
      refute MessagesHooks.jump_aria_label(@cap + 1) =~ "+"
    end

    test "the accessible name is singular at one and plural elsewhere" do
      assert MessagesHooks.jump_aria_label(0) == "Jump to latest message."
      assert MessagesHooks.jump_aria_label(1) == "Jump to latest message. 1 new message."
      assert MessagesHooks.jump_aria_label(2) == "Jump to latest message. 2 new messages."

      refute MessagesHooks.jump_aria_label(1) =~ "messages",
             "\"1 new messages\" is the defect this case exists to catch"
    end

    test "the chip does not carry aria-live under any count" do
      # There is no aria-live anywhere in the chip markup; this pins the
      # decision at the label level, and the render test below pins the DOM.
      refute MessagesHooks.jump_aria_label(3) =~ "live"
    end
  end

  describe "jump-to-latest chip accessibility wiring (stage 4)" do
    test "the badge is aria-hidden while the button carries the readable name",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-a11y-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      _ = post_message(space, other, "one arrives")
      sync(view)

      assert has_element?(view, ".chat-jump-chip-count[aria-hidden='true']"),
             "the numeral is decoration for assistive tech — the sentence on the " <>
               "button is the accessible name, and reading both gives \"1 Jump to " <>
               "latest message. 1 new message.\""

      assert has_element?(
               view,
               "button.chat-jump-chip[aria-label='#{MessagesHooks.jump_aria_label(1)}']"
             )

      # The badge text is whatever the single label function says, so this
      # assertion survives a cap change too.
      assert has_element?(view, ".chat-jump-chip-count", MessagesHooks.jump_count_label(1))

      refute view |> element("button.chat-jump-chip") |> render() =~ "aria-live",
             "the chip is a way back, not an announcement: re-announcing on every " <>
               "increment is the alarm tone the design rejected"
    end
  end
end
