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

      # Deep in history: the chip really does render, and that is the positive
      # control for the refutation below — it is about the reported position
      # and not about a bad selector. NOTE the `deep` flag. Before task
      # 01a0419a stage 4 `away` alone raised the chip; a fixture that still
      # sent `away` alone would now be asserting the SHALLOW band and would
      # fail, which is the criterion moving with the code rather than the
      # code drifting away from a criterion nobody re-read.
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert has_element?(view, "button.chat-jump-chip")
      assert has_element?(view, "button.chat-jump-chip[phx-click='jump_to_latest']")
      assert render(view) =~ "Jump to latest"

      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      refute has_element?(view, "button.chat-jump-chip"),
             "back at the tip the control must LEAVE THE DOM — a transparent or " <>
               "zero-width node still takes taps over the composer"

      refute render(view) =~ "Jump to latest"
    end

    # Overlay structure (task 01a0419a stage 2). These assert the DOM
    # RELATIONSHIP only — that the control is wrapped in the anchor/row pair
    # that the mobile CSS turns into a zero-height positioned overlay, and
    # that the wrappers leave the DOM with it. The geometry itself (centred,
    # 8px above the composer, nothing occluded) is not observable from
    # markup and is asserted by the stage-5 measurements instead.
    test "the control is wrapped in the overlay anchor, and the anchor leaves the DOM with it",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("jump-chip-overlay-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

      # Positive control for both refutations below: the deep state really
      # does render, so their absence is about the flags and not a typo.
      assert has_element?(view, "div.chat-jump-anchor")

      assert has_element?(
               view,
               "div.chat-jump-anchor > div.chat-jump-anchor-row > button.chat-jump-chip"
             ),
             "the control must be a child of the centring row inside the anchor — the " <>
               "anchor is what the mobile rules make a zero-height positioned box, so a " <>
               "control outside it is back in the flow and pushes the composer"

      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      assert has_element?(view, "form"),
             "positive control: the page is still rendered, so the refutations below " <>
               "are about the away-flag and not about a dead LiveView"

      refute has_element?(view, "div.chat-jump-anchor"),
             "the wrappers must leave the DOM with the control — an empty overlay left " <>
               "behind is a transparent full-width box sitting over the composer"

      refute has_element?(view, "button.chat-jump-chip")
    end

    test "the badge is absent at zero and present at one, with the label unchanged",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-badge-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

      # DEEP in history with nothing new: chip yes, badge no. The chip's own
      # presence is the positive control for this refutation.
      #
      # `deep` is load-bearing here and is not interchangeable with `away`.
      # Shallow-with-nothing-new is the one band that renders NOTHING, so
      # asserting a badgeless chip from `away` alone would assert the exact
      # behaviour Alex rejected. See the five-band describe block below.
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
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

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
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

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

  describe "jump-to-latest visibility bands (task 01a0419a stage 4)" do
    # THE CRITERION THAT MOVED. Task 01a03c76 shipped, and this file
    # confirmed, "visibility is the distance predicate alone and not gated on
    # having unread messages". That is now WRONG IN BOTH DIRECTIONS and is
    # replaced by the five bands below: shallow-with-nothing-new is gated on
    # unread messages and renders NOTHING, while deep-with-nothing-new is not
    # gated on them and renders a badgeless pill. The old criterion and the
    # old code drifted together because neither was re-read when the other
    # changed; this block is the criterion, written next to the code it
    # constrains.
    #
    #   position     nothing new       a message arrived
    #   ────────────────────────────────────────────────
    #   at bottom    nothing           nothing (it scrolls to you)
    #   shallow      NOTHING           pill WITH badge
    #   deep         pill, no badge    pill WITH badge
    #
    # PROVENANCE: proposed, WITHDRAWN by Saru in canvas revision 3, then
    # REINSTATED BY ALEX DIRECTLY — the deep case is not the same as reading a
    # few messages up. Collapsing `deep` back into `away` is a one-line change
    # that restores rejected behaviour, and these tests are what stops it.
    #
    # The pixel thresholds themselves (NEAR_BOTTOM_PX 150, DEEP_HISTORY_PX
    # 1800, ordered and enforced at JS module load) are not observable from
    # here — the client compares and sends booleans. What the position half
    # reports at each distance is asserted in
    # `assets/test/hooks/scroll_to_bottom_bands.test.js`.

    defp band_view(conn, tag) do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-band-#{tag}-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      %{view: view, space: space, other: other}
    end

    defp chip?(view), do: has_element?(view, "button.chat-jump-chip")
    defp badge?(view), do: has_element?(view, ".chat-jump-chip-count")

    test "BAND at-bottom, nothing new: nothing", %{conn: conn} do
      %{view: view} = band_view(conn, "bottom-quiet")

      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      # Positive control in the same test: the page is alive and the selector
      # is real, so the two refutations are about the band and not a dead
      # LiveView or a typo'd class.
      assert has_element?(view, "form")
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert chip?(view)
      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})

      refute chip?(view)
      refute badge?(view)
    end

    test "BAND at-bottom, a message arrives: still nothing, because it scrolls to you",
         %{conn: conn} do
      %{view: view, space: space, other: other} = band_view(conn, "bottom-arrival")

      render_hook(view, "jump_to_latest_distance", %{"away" => false, "deep" => false})
      _ = post_message(space, other, "arrives while you are watching the tip")
      sync(view)

      # The count is the positive control: the message genuinely landed in
      # this LiveView, so the absent chip is a decision and not a no-op.
      assert count(view) == 0,
             "a message arriving at a bottom-parked reader is scrolled to, not counted"

      refute chip?(view)
    end

    test "BAND shallow, nothing new: NOTHING — the band this whole change exists for",
         %{conn: conn} do
      # Alex's complaint in his own words: scrolling up to re-read a few
      # messages must not raise a control. Before this stage `away` alone put
      # the pill on screen, so this exact state is what shipped wrong.
      %{view: view} = band_view(conn, "shallow-quiet")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => false})

      # POSITIVE CONTROL, in this test, for the refutations below it: the very
      # same view raises the chip the moment either half of the rule is
      # satisfied. Without this the refutations are satisfied just as well by
      # a broken selector or a LiveView that never rendered.
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert chip?(view)
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => false})

      refute chip?(view),
             "scrolled up a little with nothing new, the control must LEAVE THE DOM — " <>
               "this is the state Alex filed the ticket about"

      refute has_element?(view, "div.chat-jump-anchor"),
             "the overlay wrappers go with it; an empty anchor is a transparent box " <>
               "left over the messages"

      assert count(view) == 0
    end

    test "BAND shallow, a message arrives: pill WITH badge", %{conn: conn} do
      %{view: view, space: space, other: other} = band_view(conn, "shallow-arrival")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => false})
      refute chip?(view)

      _ = post_message(space, other, "one arrives while you are reading back")
      sync(view)

      assert count(view) == 1
      assert chip?(view)
      assert badge?(view)
      assert has_element?(view, ".chat-jump-chip-count", "1")
    end

    test "BAND deep, nothing new: pill with NO badge", %{conn: conn} do
      %{view: view} = band_view(conn, "deep-quiet")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

      # The chip's presence is the positive control for the badge refutation.
      assert chip?(view)

      refute badge?(view),
             "nothing arrived, so there is no number to show and an empty badge would " <>
               "be a saturated pixel announcing nothing"

      assert has_element?(view, "button.chat-jump-chip[aria-label='Jump to latest message.']")
    end

    test "BAND deep, a message arrives: pill WITH badge", %{conn: conn} do
      %{view: view, space: space, other: other} = band_view(conn, "deep-arrival")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      refute badge?(view)

      _ = post_message(space, other, "one arrives while you are deep in history")
      sync(view)

      assert chip?(view)
      assert has_element?(view, ".chat-jump-chip-count", "1")
    end

    test "deep alone raises the pill even with the count at zero, and the two are independent",
         %{conn: conn} do
      # The discriminating pair. A build that collapsed `deep` back into `away`
      # passes every other test in this block; only the contrast between these
      # two rows separates the two-threshold rule from the one it replaced.
      %{view: view} = band_view(conn, "deep-vs-shallow")

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert chip?(view)
      assert count(view) == 0

      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => false})
      refute chip?(view)
    end

    test "an older client that sends no `deep` key degrades to the shallow bands",
         %{conn: conn} do
      # Mid-deploy a client bundle predating this stage still pushes `%{away:
      # ...}`. Crashing the LiveView on a missing key would take the whole
      # conversation down; defaulting to `false` costs that reader the deep
      # band until their bundle refreshes.
      %{view: view, space: space, other: other} = band_view(conn, "legacy-payload")

      render_hook(view, "jump_to_latest_distance", %{"away" => true})

      assert assigns(view)[:jump_away_from_bottom] == true
      assert assigns(view)[:jump_deep_in_history] == false
      refute chip?(view)

      # Positive control: the count half still works for that reader, so the
      # degradation is confined to visibility.
      _ = post_message(space, other, "arrives for a stale client")
      sync(view)
      assert count(view) == 1
      assert chip?(view)
    end

    test "switching conversations clears the position flags, not just the count",
         %{conn: conn} do
      # `deep` makes the control visible ON ITS OWN, so a stale `true` carried
      # into the next space offers a reader a way back to a tip they are
      # already sitting at. Zeroing the count alone no longer covers this.
      {conn, user} = authenticated_conn(conn)
      a = ensure_space("jump-band-switch-a-#{System.unique_integer([:positive])}")
      b = ensure_space("jump-band-switch-b-#{System.unique_integer([:positive])}")
      _ = post_message(a, user, "seed a")
      _ = post_message(b, user, "seed b")

      {:ok, view, _html} = live(conn, ~p"/chat/#{a.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
      assert chip?(view)

      view |> render_patch(~p"/chat/#{b.slug}")

      assert assigns(view)[:jump_deep_in_history] == false
      assert assigns(view)[:jump_away_from_bottom] == false
      refute chip?(view)
    end

    test "jump_chip_visible?/3 is the whole rule, and it is total over the five bands" do
      # Asserted directly as well as through the render, because the rendered
      # assertions above cannot distinguish "the predicate is right" from
      # "the template happens to agree with it today".
      refute MessagesHooks.jump_chip_visible?(false, false, 0)
      refute MessagesHooks.jump_chip_visible?(false, true, 0)
      assert MessagesHooks.jump_chip_visible?(false, true, 1)
      assert MessagesHooks.jump_chip_visible?(true, true, 0)
      assert MessagesHooks.jump_chip_visible?(true, true, 3)
      # Seeded state, before the client has reported anything at all.
      refute MessagesHooks.jump_chip_visible?(nil, nil, nil)
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
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})
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

  describe "jump-to-latest rendered surface (stage 3)" do
    # The painted pill and the hit area are two elements deliberately. A
    # single element cannot be both 28px painted and 44px tappable, and the
    # collapse back into one is invisible on screen — the only symptom is a
    # missed tap. So the nesting is pinned in the DOM here and the two
    # heights are pinned in the stylesheet below; the actual geometry is
    # measured in stage 5.
    test "the label and count are painted inside the pill, not on the button",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      other = other_user!()
      space = ensure_space("jump-chip-surface-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

      assert has_element?(view, "button.chat-jump-chip > span.chat-jump-chip-pill"),
             "the painted pill must be a child of the button — if the classes land " <>
               "on one element the 16px of transparent padding paints too and the " <>
               "28px pill silently becomes a 44px block"

      refute has_element?(view, "span.chat-jump-chip-pill.chat-jump-chip"),
             "one element carrying both classes is the collapse this split prevents"

      _ = post_message(space, other, "one arrives")
      sync(view)

      assert has_element?(
               view,
               "span.chat-jump-chip-pill > span.chat-jump-chip-count"
             ),
             "the count is inside the painted pill, so its arrival grows the pill " <>
               "sideways rather than adding a second painted box"

      assert has_element?(view, "span.chat-jump-chip-pill > span.truncate"),
             "positive control: the label span is also inside the pill, so the " <>
               "count assertion above is about nesting and not about the count"
    end

    # The gutter classes that positioned the OLD in-flow chip. Stage 1 removed
    # them from the button; this is the guard that they do not drift back.
    #
    # SCOPED TO THE PARSED BUTTON NODE, not asserted over the page HTML. Two
    # reasons, and the second is the one that bites:
    #
    # 1. A substring refute over a whole rendered page is position-dependent —
    #    it answers "does this string appear anywhere", which is a different
    #    question from "does this element carry this class". Any other element
    #    on the chat page picking up `mb-1` would fail this test with a message
    #    pointing at the jump chip.
    #
    # 2. MEASURED on the rendered page, not assumed, and the two classes fail
    #    an unscoped refute in OPPOSITE directions:
    #
    #      ml-5       absent from the rendered page entirely
    #      mb-1       absent from the rendered page entirely
    #      self-start PRESENT — on some other element, not this button
    #
    #    So `refute html =~ "ml-5"` would pass VACUOUSLY: the string is missing
    #    for reasons that have nothing to do with the chip, and it would go on
    #    passing if the class reappeared on a different element. And
    #    `refute html =~ "self-start"` would FAIL IMMEDIATELY, blaming the jump
    #    chip for a class another element legitimately carries. One unscoped
    #    refute is silently empty, the other is a false accusation. Neither
    #    tells you anything about the button, which is why the assertion is
    #    scoped to the parsed node and paired with positive assertions that
    #    prove the class list was actually read.
    #
    #    (The `ml-5`/`mb-1` mentions in `chat_live.html.heex` are inside an
    #    `<%!-- --%>` HEEX comment and are stripped from the output.)
    test "the button no longer carries the in-flow gutter classes", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      space = ensure_space("jump-chip-gutter-#{System.unique_integer([:positive])}")
      _ = post_message(space, user, "seed")

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_hook(view, "jump_to_latest_distance", %{"away" => true, "deep" => true})

      doc = view |> render() |> LazyHTML.from_document()
      buttons = LazyHTML.query(doc, "button.chat-jump-chip")

      # ANTI-VACUITY, first: a refute over an EMPTY node list passes trivially,
      # and "the chip did not render" is exactly how this test would go green
      # while proving nothing.
      assert Enum.count(buttons) == 1,
             "the chip must be rendered for the class assertions to mean anything"

      classes =
        buttons
        |> LazyHTML.attribute("class")
        |> List.first()
        |> String.split(~r/\s+/, trim: true)

      # POSITIVE: the classes that must be there. These prove the class list was
      # actually read off the button rather than defaulting to empty.
      assert "chat-jump-chip" in classes
      assert "focus-visible-ring" in classes

      # REFUTE: the in-flow gutter classes are gone.
      for gone <- ~w(ml-5 mb-1 self-start) do
        refute gone in classes,
               "`#{gone}` positioned the old in-flow chip. The promoted " <>
                 "`margin: 0` on `.chat-jump-anchor-row > .chat-jump-chip` " <>
                 "overrides it at every width, so leaving it on the button " <>
                 "describes a layout that no longer exists — and a class whose " <>
                 "stated reason is false is indistinguishable from a live one. " <>
                 "Class list was: #{Enum.join(classes, " ")}"
      end

      # The wrapper the overlay depends on is present and unconditional.
      assert Enum.count(LazyHTML.query(doc, "div.chat-jump-anchor-row")) == 1,
             "the absolutely-positioned centring row is what makes the chip an " <>
               "overlay; without it the button is back in the flex flow and the " <>
               "gutter classes above would be load-bearing again"
    end

    # A LiveView render test cannot see CSS, and every ruling on this stage is
    # a CSS ruling. These read the stylesheet directly. They are coarse on
    # purpose: they pin the decisions that are invisible on screen, and leave
    # appearance to the human gate and geometry to the stage-5 measurement.
    test "the 44px hit area is unconditional, not behind a hover/pointer query" do
      css = File.read!("assets/css/app.css")

      refute css =~ ~r/@media \(hover: none\) \{\s*\.chat-jump-chip\b/,
             "a 44px floor inside `@media (hover: none)` is untestable on the review " <>
               "hardware — `Emulation.setEmulatedMedia` is a no-op there, so every " <>
               "measurement reads the desktop rule and reports it as the touch rule. " <>
               "That false pass already shipped once on this component."

      assert css =~ ~r/\.chat-jump-chip \{[^}]*height: 44px;/,
             "the hit area belongs in the base rule, for every pointer type"

      assert css =~ ~r/\.chat-jump-chip \{[^}]*padding: 8px 0;/,
             "44px is reached with transparent vertical padding (8px + 28px + 8px), " <>
               "not by growing the painted pill"

      assert css =~ ~r/\.chat-jump-chip-pill \{[^}]*height: 28px;/,
             "the painted pill is exactly 28px"
    end

    test "the pill keeps its ground: translucent fill plus backdrop blur" do
      css = File.read!("assets/css/app.css")
      [pill] = Regex.run(~r/\.chat-jump-chip-pill \{[^}]*\}/, css)

      assert pill =~ "backdrop-filter: blur(",
             "the blur is the mechanism that makes a translucent pill legible over " <>
               "content whose colour we do not control. Translucent with no blur " <>
               "fails silently and looks correct in every screenshot taken while " <>
               "building it."

      assert pill =~ "-webkit-backdrop-filter: blur(",
             "older Mobile Safari needs the prefix, and this is a mobile-only surface"

      assert pill =~
               ~r/background: color-mix\(in srgb, var\(--color-base-100\) \d+%, transparent\)/,
             "the fill is translucent. An opaque fill is the weight this change removes."

      refute pill =~ ~r/box-shadow|border:/,
             "a border or drop shadow as the ground reinstates the frame that was " <>
               "explicitly ruled out"
    end

    test "the brand rulings are shipped, not the mock's raw values" do
      css = File.read!("assets/css/app.css")
      [pill] = Regex.run(~r/\.chat-jump-chip-pill \{[^}]*\}/, css)

      assert pill =~ "border-radius: var(--radius-selector);",
             "the brand token, not the mock's 999px — the mock draws 999px as a " <>
               "convenience for standalone rendering, and shipping it would promote " <>
               "a drawing convenience to a spec"

      refute pill =~ "border-radius: 999px",
             "999px is the value inherited by copying the mock"

      refute pill =~ "border-radius: 10px",
             "10px is the value this stage replaces"

      assert pill =~ "font-family: var(--font-sans);",
             ~s(the body face, "Public Sans" — no display type on this component)

      assert pill =~ "font-size: 14px;", "body scale"
    end

    test "the entrance is the pill's own fade-and-rise, with the properties declared" do
      css = File.read!("assets/css/app.css")
      [pill] = Regex.run(~r/\.chat-jump-chip-pill \{[^}]*\}/, css)
      [count] = Regex.run(~r/\.chat-jump-chip-count \{[^}]*\}/, css)

      refute pill =~ "icon-rail-badge-in",
             "the rail-badge keyframe was built to pop a small badge onto a rail icon"

      refute count =~ "icon-rail-badge-in",
             "the count enters with its own parent — a pill surfacing at 150ms " <>
               "ease-out around a count popping on the rail badge's 200ms curve is " <>
               "one object arriving in two motions"

      for {name, rule} <- [{"pill", pill}, {"count", count}] do
        assert rule =~ "animation: chat-jump-chip-in 150ms cubic-bezier(0, 0, 0.2, 1);",
               "#{name}: ~150ms ease-out, no spring and no scale"
      end

      [frames] = Regex.run(~r/@keyframes chat-jump-chip-in \{.*?\n\}/s, css)

      # The properties are asserted, not just the keyframe's existence: a
      # previous stage on this component left a rationale comment for an
      # animation it never declared, and the next stage declared it, so the
      # comment and the code disagreed for a whole stage.
      assert frames =~ "transform: translateY(8px);", "an 8px rise, up from 4px"
      assert frames =~ "transform: translateY(0);"
      assert frames =~ "opacity: 0;"
      assert frames =~ "opacity: 1;"

      refute frames =~ "scale(",
             "no scale: the pill should look like it surfaced, not like it landed"

      refute frames =~ "translateY(4px);", "4px is the rise this stage replaces"
    end
  end

  # The record is a wrapped comment, so a sentence can straddle a line
  # break. Collapse runs of whitespace before matching — the only thing
  # normalised away is the wrapping, which is exactly the thing no
  # assertion here is about.
  defp contrast_record(css) do
    [block] = Regex.run(~r/Opacity is 72% in both\..*?\*\//s, css)
    block |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  describe "jump-to-latest measurement record (task 01a0419a stage 5)" do
    # Stage 5 measured the shipped control in a browser. These tests do not
    # re-measure — a test cannot open Chrome — they guard the two ways the
    # measurement can be quietly falsified afterwards: the geometry drifting
    # out of the arithmetic that made 44px reachable, and the recorded
    # ratio's SURFACE being swapped for the one the design canvas names.

    test "the hit area is the arithmetic sum of the padding and the painted pill" do
      css = File.read!("assets/css/app.css")

      [_, hit] = Regex.run(~r/\.chat-jump-chip \{[^}]*height: (\d+)px;/, css)
      [_, pad] = Regex.run(~r/\.chat-jump-chip \{[^}]*padding: (\d+)px 0;/, css)
      [_, painted] = Regex.run(~r/\.chat-jump-chip-pill \{[^}]*height: (\d+)px;/, css)

      {hit, pad, painted} =
        {String.to_integer(hit), String.to_integer(pad), String.to_integer(painted)}

      # HONEST NOTE ON WHAT THIS ADDS, because the first version of this
      # comment claimed more than the probe supports. I mutated the
      # stylesheet with a coordinated edit (padding 8px -> 4px, pill 28px ->
      # 36px, hit rect left at 44px) expecting it to slip past stage 3's
      # three literal pins and be caught only here. It did not: stage 3's
      # pins are on the literals themselves, so they detected it too. Two
      # tests failed, not one.
      #
      # So this is NOT extra detection. What it adds is the DERIVATION —
      # 44 is not a third independent number, it is 8 + 28 + 8 — and a
      # failure message that carries the in-browser measurement, so whoever
      # breaks it is told what was actually observed rather than which
      # string stopped matching.
      assert painted + 2 * pad == hit,
             "the 44px hit rect must be #{pad}px + #{painted}px + #{pad}px. " <>
               "Measured in-browser at stage 5: button rect 44.00px, pill rect " <>
               "28.00px. If these three numbers stop summing, one of the two " <>
               "boxes is no longer the box that was measured."

      assert painted == 28, "the painted pill is 28px — the weight being removed"
      assert hit == 44, "the tappable floor is 44px, unconditionally"
    end

    test "the recorded contrast measurement names the surface it was taken on" do
      css = File.read!("assets/css/app.css")

      record = contrast_record(css)

      # THE GUARD THAT MATTERS MORE THAN THE NUMBER. The design canvas asks
      # for this ratio "on the own-message cyan bubble". No such bubble
      # exists — `chat_message.ex` tints own messages `bg-base-200/60`. A
      # ratio taken on the real ground but REPORTED in the canvas's words is
      # not a weaker result, it is an indistinguishable one: unlike a wrong
      # number it never gets re-derived, it gets quoted forward.
      refute record =~ ~r/(?:measured|sampled|verified|taken)[^.]{0,40}\bcyan bubble\b/i,
             "the record must not claim the ratio was taken on the cyan bubble. " <>
               "Note this fires on the phrase even when the surrounding prose is " <>
               "warning AGAINST it: a text scan cannot tell a warning from a " <>
               "claim, so the record states the rule without spelling the " <>
               "sentence it forbids."

      assert record =~ "bg-base-200/60",
             "the record must name the surface it was actually taken on"

      assert record =~ ~r/DOES NOT EXIST AND CANNOT BE BUILT/,
             "and must say plainly that the canvas's named fixture is unbuildable, " <>
               "so the next reader does not go looking for it"

      # Positive control, so the refute above cannot pass by matching an
      # empty record: the block really does carry ratios and the criterion.
      assert record =~ "4.5:1"
      assert record =~ ~r/18\.8:1/, "the worst sampled light ratio is recorded"
      assert record =~ ~r/14\.5:1/, "the worst sampled dark ratio is recorded"
    end

    test "the unexercised opacity rule is recorded as standing, not as satisfied" do
      css = File.read!("assets/css/app.css")
      record = contrast_record(css)

      # A rule exercised only where it is a no-op is a rule nobody has held.
      # Recording it as "verified" would be the same class of error as the
      # cyan-bubble substitution above, one level up.
      assert record =~ "RAISE THE FILL OPACITY, never darken the label"

      assert record =~ ~r/Recorded as standing, not as satisfied/,
             "4.5:1 was never missed, so the remedy was never run — say so"
    end
  end
end
