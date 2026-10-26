defmodule PlatformWeb.ChatLive.ThreadActivityHooksTest do
  @moduledoc """
  The main log's "↳ N new replies to …" rows (task 01a174f5 stage 2):
  `PlatformWeb.ChatLive.ThreadActivityHooks` and
  `PlatformWeb.Components.ThreadActivityRow`, through a real `/chat` LiveView.

  Each named mutation in the stage spec (M-dup, M-move, M-unread, M-tap,
  M-removed, M-cap, M-orig, M-own, M-expanded) has a test below that fails
  under it, and every absence is paired with a presence from the same
  fixture, so a region that never rendered could not pass.

  Every thread is seeded with one reply from the VIEWER before mount: the
  thread chip renders only for a parent with at least one reply
  (`Chat.thread_previews_for_messages/1`), and the viewer's own reply never
  counts as activity, so the seed starts each thread with no row.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Participant, ThreadRead}
  alias Platform.Repo

  @row "[data-role=thread-activity-row]"

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "thread_activity_#{label}_#{n}@example.com",
      name: "Thread Activity #{label}",
      oidc_sub: "oidc-thread-activity-#{label}-#{n}"
    })
  end

  defp member!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    p
  end

  setup %{conn: conn} do
    viewer_user = user!("viewer")
    other_user = user!("other")
    slug = "thread-activity-#{System.unique_integer([:positive])}"
    {:ok, space} = Chat.create_space(%{name: "Thread activity", slug: slug, kind: "channel"})
    viewer = member!(space, viewer_user)
    other = member!(space, other_user)

    %{
      conn: init_test_session(conn, current_user_id: viewer_user.id),
      viewer_user: viewer_user,
      space: space,
      viewer: viewer,
      other: other
    }
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  # A parent by `other` with a thread seeded by one viewer reply.
  defp thread!(ctx, content) do
    parent = post!(ctx.space, ctx.other, content)
    {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, parent.id)
    _ = reply!(thread, ctx.viewer, "seed")
    {parent, thread}
  end

  defp reply!(thread, participant, content \\ "a reply") do
    {:ok, msg} = Chat.reply_to_thread(thread.id, participant.id, %{content: content})
    msg
  end

  defp mount!(ctx) do
    {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.space.slug}")
    view
  end

  # `render/1` is a call into the LiveView, so it is served only after every
  # broadcast already in its mailbox.
  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp row_ids(view),
    do: doc(view) |> LazyHTML.query(@row) |> LazyHTML.attribute("data-thread-id")

  defp row_count_text(view, thread) do
    doc(view)
    |> LazyHTML.query(
      ~s(#{@row}[data-thread-id="#{thread.id}"] [data-role=thread-activity-count])
    )
    |> LazyHTML.text()
    |> String.trim()
  end

  defp message_list_ids(view),
    do: doc(view) |> LazyHTML.query("#message-list > *") |> LazyHTML.attribute("id")

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "rows" do
    test "M-dup: two replies in one thread are ONE row reading '2 new replies'", ctx do
      {_parent, thread} = thread!(ctx, "Can we try the viewer")
      view = mount!(ctx)
      assert row_ids(view) == []

      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]
      assert row_count_text(view, thread) == "1 new reply to"

      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]
      assert row_count_text(view, thread) == "2 new replies to"
    end

    test "M-move: T1, T2, T1 leaves T1 last, reading '2 new replies'", ctx do
      {_p1, t1} = thread!(ctx, "first parent")
      {_p2, t2} = thread!(ctx, "second parent")
      view = mount!(ctx)

      _ = reply!(t1, ctx.other)
      _ = reply!(t2, ctx.other)
      assert row_ids(view) == [t1.id, t2.id]

      _ = reply!(t1, ctx.other)
      assert row_ids(view) == [t2.id, t1.id]
      assert row_count_text(view, t1) == "2 new replies to"
    end

    test "the row shows the parent excerpt and is announced as a link", ctx do
      {parent, thread} = thread!(ctx, "Can we try the viewer")
      view = mount!(ctx)
      _ = reply!(thread, ctx.other)

      html = doc(view)
      row = LazyHTML.query(html, ~s(#{@row}[data-thread-id="#{thread.id}"]))

      assert LazyHTML.attribute(row, "role") == ["link"]
      assert LazyHTML.attribute(row, "phx-click") == ["space_sheet_open_thread"]
      assert LazyHTML.attribute(row, "phx-key") == ["Enter"]
      assert LazyHTML.attribute(row, "phx-value-message-id") == [parent.id]

      assert row |> LazyHTML.query("[data-role=thread-activity-excerpt]") |> LazyHTML.text() =~
               "Can we try the viewer"

      [label] = LazyHTML.attribute(row, "aria-label")
      assert label =~ "1 new reply in thread: Can we try the viewer. Latest from"
    end

    test "M-own: the viewer's own reply from another session creates no row", ctx do
      {_parent, thread} = thread!(ctx, "own parent")
      view = mount!(ctx)

      _ = reply!(thread, ctx.viewer, "mine, sent from another device")
      assert row_ids(view) == []

      # Positive control, same view and thread.
      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]
    end

    test "M-unread: a thread reply leaves the jump count and the space cursor alone", ctx do
      {_parent, thread} = thread!(ctx, "unread parent")
      view = mount!(ctx)
      render_hook(view, "jump_to_latest_distance", %{"away" => true})
      before = Repo.get!(Participant, ctx.viewer.id).last_read_message_id

      _ = reply!(thread, ctx.other)

      assert row_ids(view) == [thread.id]
      assert assigns(view)[:jump_new_message_count] == 0
      assert Repo.get!(Participant, ctx.viewer.id).last_read_message_id == before
    end
  end

  describe "the cap" do
    test "M-cap: 4 threads show the summary FIRST and then 3 rows; 5 say '2 more'", ctx do
      threads = for i <- 1..5, do: elem(thread!(ctx, "parent #{i}"), 1)
      [t1, t2, t3, t4, t5] = threads
      view = mount!(ctx)

      for t <- [t1, t2, t3], do: reply!(t, ctx.other)
      assert row_ids(view) == [t1.id, t2.id, t3.id]
      refute has_element?(view, "[data-role=thread-activity-summary]")

      _ = reply!(t4, ctx.other)
      assert row_ids(view) == [t2.id, t3.id, t4.id]

      children = doc(view) |> LazyHTML.query("#thread-activity-region > *")
      assert LazyHTML.attribute(children, "id") == ["thread-activity-summary", "thread-activity"]

      assert doc(view)
             |> LazyHTML.query("[data-role=thread-activity-summary] button.lg\\:hidden")
             |> LazyHTML.text() =~ "1 more thread with new replies"

      _ = reply!(t5, ctx.other)
      assert row_ids(view) == [t3.id, t4.id, t5.id]

      assert doc(view)
             |> LazyHTML.query("[data-role=thread-activity-summary] button.lg\\:hidden")
             |> LazyHTML.text() =~ "2 more threads with new replies"
    end
  end

  describe "removed on open" do
    test "M-removed: the chip removes the row, across a remount and a second view, until the next reply",
         ctx do
      {parent, thread} = thread!(ctx, "removed parent")
      view = mount!(ctx)
      second = mount!(ctx)

      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]
      assert row_ids(second) == [thread.id]

      view
      |> element(~s([data-role=thread-chip][phx-value-message-id="#{parent.id}"]))
      |> render_click()

      assert row_ids(view) == []

      # The other LiveView of the same viewer, with no reload.
      assert row_ids(second) == []

      # A remount derives the same from the cursor.
      remounted = mount!(ctx)
      assert row_ids(remounted) == []

      # Collapse in the first view (the chip's toggle, the footer's event) so
      # the next reply is not "seen" there.
      render_click(view, "toggle_inline_thread", %{"message-id" => parent.id})
      refute MapSet.member?(assigns(view).expanded_threads, parent.id)

      _ = reply!(thread, ctx.other)
      assert row_ids(remounted) == [thread.id]
      assert row_count_text(remounted, thread) == "1 new reply to"
      assert row_ids(view) == [thread.id]
      assert row_count_text(view, thread) == "1 new reply to"
    end

    test "M-expanded: a reply to an expanded thread shows no row and advances the cursor", ctx do
      {parent, thread} = thread!(ctx, "expanded parent")
      {_p2, other_thread} = thread!(ctx, "control parent")
      view = mount!(ctx)

      render_click(view, "toggle_inline_thread", %{"message-id" => parent.id})
      assert MapSet.member?(assigns(view).expanded_threads, parent.id)

      reply = reply!(thread, ctx.other)
      _ = reply!(other_thread, ctx.other)

      assert row_ids(view) == [other_thread.id]

      assert Repo.get_by!(ThreadRead, participant_id: ctx.viewer.id, thread_id: thread.id).last_read_message_id ==
               reply.id
    end

    test "M-tap: tapping the row expands the parent's inline thread (in the window)", ctx do
      {parent, thread} = thread!(ctx, "tap parent")
      view = mount!(ctx)
      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]

      view |> element(~s(#{@row}[data-thread-id="#{thread.id}"])) |> render_click()

      assert MapSet.member?(assigns(view).expanded_threads, parent.id)
      assert has_element?(view, "#inline-thread-#{parent.id}")
      assert row_ids(view) == []
    end

    test "M-tap: tapping the row of a parent OUTSIDE the window takes the anchored path", ctx do
      {parent, thread} = thread!(ctx, "old parent")
      for i <- 1..55, do: post!(ctx.space, ctx.other, "later #{i}")
      view = mount!(ctx)
      refute MapSet.member?(assigns(view).rendered_message_ids, parent.id)

      _ = reply!(thread, ctx.other)
      assert row_ids(view) == [thread.id]

      view |> element(~s(#{@row}[data-thread-id="#{thread.id}"])) |> render_click()
      assert_patch(view)

      assert MapSet.member?(assigns(view).rendered_message_ids, parent.id)
      assert MapSet.member?(assigns(view).expanded_threads, parent.id)
      assert has_element?(view, "#inline-thread-#{parent.id}")
      assert row_ids(view) == []
    end
  end

  describe "the main log" do
    test "M-orig: #message-list children are unchanged by replies and a tap, and none is a row",
         ctx do
      {_p1, t1} = thread!(ctx, "orig one")
      {_p2, t2} = thread!(ctx, "orig two")
      _ = post!(ctx.space, ctx.other, "a top-level message after both")
      view = mount!(ctx)
      before = message_list_ids(view)
      assert length(before) == 3

      _ = reply!(t1, ctx.other)
      _ = reply!(t2, ctx.other)
      _ = reply!(t1, ctx.other)
      assert row_ids(view) == [t2.id, t1.id]
      assert message_list_ids(view) == before

      view |> element(~s(#{@row}[data-thread-id="#{t2.id}"])) |> render_click()
      assert message_list_ids(view) == before

      refute doc(view) |> LazyHTML.query("#message-list #{@row}") |> Enum.any?()
      assert doc(view) |> LazyHTML.query("#thread-activity #{@row}") |> Enum.any?()
    end

    test "pass-through: thread replies and other messages still reach MessagesHooks", ctx do
      {parent, thread} = thread!(ctx, "pass parent")
      view = mount!(ctx)

      _ = reply!(thread, ctx.other)
      sync = row_ids(view)
      assert sync == [thread.id]

      # The thread reply reached MessagesHooks: the chip's count moved.
      assert assigns(view).thread_previews[parent.id].reply_count == 2

      # A probe (a top-level message, the catch-all clause) reaches it too.
      probe = post!(ctx.space, ctx.other, "probe")
      assert has_element?(view, "#message-list #messages-#{probe.id}")
    end
  end
end
