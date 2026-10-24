defmodule PlatformWeb.ChatLive.ReactionsAndThreadsTest do
  @moduledoc """
  Reactions and inline threads (redesign rung 9 stage 3, task 01a1557a-9406;
  masters canvas 01a1382f node `proto`, direction canvas 01a1666e nodes m1
  and m3).

    * Reaction pills are NEUTRAL: not mine is base-200 with the edge border,
      mine is base-300 with a base-content outline, never primary. A tap
      toggles through `react`.
    * A long-press on a pill pushes `open_reactors`, and the 'Reacted
      <emoji>' sheet lists who reacted, re-read from the DATABASE; the
      viewer's row carries 'you'.
    * The thread chip reads '↩ N replies · time'. Reply in thread
      (`open_inline_thread`) only ever OPENS; the chip and the footer
      'collapse' toggle.
    * The old thread side-panel events (`open_thread`, `close_thread`) are
      gone, so LiveView treats them as unhandled.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Reaction
  alias Platform.Repo

  import Ecto.Query

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "reactions_#{n}@example.com",
        name: "Reactions Viewer",
        oidc_sub: "oidc-reactions-#{n}",
        avatar_url: nil
      })

    {:ok, space} =
      Chat.create_space(%{name: "Reactions #{n}", slug: "reactions-#{n}", kind: "channel"})

    {:ok, viewer} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Reactions Viewer",
        joined_at: DateTime.utc_now()
      })

    {:ok, other} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Other Reactor #{n}",
        joined_at: DateTime.utc_now()
      })

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     space: space,
     viewer: viewer,
     other: other}
  end

  defp post_msg(space, participant, content, extra \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: content
          },
          extra
        )
      )

    msg
  end

  defp react!(msg, participant, emoji) do
    {:ok, _} =
      Chat.add_reaction(%{message_id: msg.id, participant_id: participant.id, emoji: emoji})
  end

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp pill(view, msg, emoji) do
    view
    |> doc()
    |> LazyHTML.query(~s([data-message-id="#{msg.id}"] .reaction-pill[data-emoji="#{emoji}"]))
  end

  defp pill_text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s/u, "")

  defp classes(node) do
    node |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split()
  end

  defp reaction_count(msg, emoji) do
    Repo.aggregate(
      from(r in Reaction,
        where: r.message_id == ^msg.id and r.emoji == ^emoji and is_nil(r.deleted_at)
      ),
      :count
    )
  end

  defp reactor_rows(view, frame) do
    view
    |> doc()
    |> LazyHTML.query(~s(#{frame} [data-role="reactor-row"]))
    |> Enum.map(fn row ->
      text = row |> LazyHTML.text() |> String.split() |> Enum.join(" ")
      text
    end)
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "reaction pills" do
    test "two reactors: one pill reads 2, mine is neutral raised, and a second tap removes mine",
         %{conn: conn, space: space, viewer: viewer, other: other} do
      msg = post_msg(space, other, "react to this")
      react!(msg, viewer, "👍")
      react!(msg, other, "👍")
      assert reaction_count(msg, "👍") == 2

      view = open_chat(conn, space)

      node = pill(view, msg, "👍")
      assert LazyHTML.attribute(node, "data-role") == ["reaction-pill"]
      assert pill_text(node) == "👍2"

      cls = classes(node)
      assert "bg-base-300" in cls
      assert "border-base-content" in cls
      assert "tabular-nums" in cls
      refute Enum.any?(cls, &String.contains?(&1, "primary")), inspect(cls)
      refute Enum.any?(cls, &String.starts_with?(&1, "hover:")), inspect(cls)

      render_click(view, "react", %{"message-id" => msg.id, "emoji" => "👍"})
      assert reaction_count(msg, "👍") == 1

      node = pill(view, msg, "👍")
      assert pill_text(node) == "👍1"
      cls = classes(node)
      assert "bg-base-200" in cls
      assert "border-edge" in cls
      refute "bg-base-300" in cls
      refute Enum.any?(cls, &String.contains?(&1, "primary")), inspect(cls)
    end

    test "no reaction pill on the page carries a primary class",
         %{conn: conn, space: space, viewer: viewer, other: other} do
      msg = post_msg(space, viewer, "mixed reactions")
      react!(msg, viewer, "🔥")
      react!(msg, other, "👀")
      view = open_chat(conn, space)

      pills = view |> doc() |> LazyHTML.query(~s([data-role="reaction-pill"]))
      assert Enum.count(pills) == 2

      for p <- pills do
        refute Enum.any?(classes(p), &String.contains?(&1, "primary")), inspect(classes(p))
      end
    end
  end

  describe "open_reactors" do
    test "lists both reactors from the database, with 'you' on the viewer",
         %{conn: conn, space: space, viewer: viewer, other: other} do
      msg = post_msg(space, other, "who reacted")
      react!(msg, viewer, "👍")
      react!(msg, other, "👍")
      view = open_chat(conn, space)

      refute has_element?(view, "#reactors-sheet")
      render_hook(view, "open_reactors", %{"message-id" => msg.id, "emoji" => "👍"})

      assert has_element?(view, ~s(#reactors-sheet[data-swipe-dismiss="true"]))
      assert has_element?(view, "#reactors-sheet .sheet-handle-button")
      assert has_element?(view, "#reactors-sheet.lg\\:hidden")
      assert has_element?(view, ~s(#reactors-sheet p[aria-hidden="true"]), "Reacted 👍")
      assert has_element?(view, "#reactors-popover.hidden.lg\\:block")

      rows = reactor_rows(view, "#reactors-sheet")
      assert "Reactions Viewer you" in rows
      assert Enum.any?(rows, &(&1 == other.display_name)), inspect(rows)
      assert length(rows) == 2
      assert reactor_rows(view, "#reactors-popover") == rows

      render_hook(view, "close_reactors", %{})
      refute has_element?(view, "#reactors-sheet")
      refute has_element?(view, "#reactors-popover")
    end

    test "the client's reactor list is never trusted: a forged payload shows the DB rows only",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "forged")
      react!(msg, other, "👍")
      view = open_chat(conn, space)

      render_hook(view, "open_reactors", %{
        "message-id" => msg.id,
        "emoji" => "👍",
        "reactors" => [%{"id" => Ecto.UUID.generate(), "name" => "Forged Name"}]
      })

      rows = reactor_rows(view, "#reactors-sheet")
      assert rows == [other.display_name]
      refute render(view) =~ "Forged Name"
    end

    test "an emoji nobody used renders an empty list without crashing",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "nobody")
      view = open_chat(conn, space)

      render_hook(view, "open_reactors", %{"message-id" => msg.id, "emoji" => "🦄"})

      assert has_element?(view, "#reactors-sheet")
      assert reactor_rows(view, "#reactors-sheet") == []
    end

    test "a message outside the open space opens nothing", %{conn: conn, space: space} do
      n = System.unique_integer([:positive])

      {:ok, elsewhere} =
        Chat.create_space(%{name: "Else #{n}", slug: "else-#{n}", kind: "channel"})

      {:ok, stranger} =
        Chat.add_participant(elsewhere.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Stranger #{n}",
          joined_at: DateTime.utc_now()
        })

      msg = post_msg(elsewhere, stranger, "secret")
      react!(msg, stranger, "👍")
      view = open_chat(conn, space)

      render_hook(view, "open_reactors", %{"message-id" => msg.id, "emoji" => "👍"})
      refute has_element?(view, "#reactors-sheet")
      refute render(view) =~ "Stranger #{n}"
    end

    test "opening the reactors closes the actions sheet: one sheet at a time",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "one sheet")
      react!(msg, other, "👍")
      view = open_chat(conn, space)

      render_click(view, "open_message_actions", %{"id" => msg.id})
      assert has_element?(view, "#message-actions-sheet")

      render_hook(view, "open_reactors", %{"message-id" => msg.id, "emoji" => "👍"})
      assert has_element?(view, "#reactors-sheet")
      refute has_element?(view, "#message-actions-sheet")
      refute has_element?(view, "#message-actions-popover")
    end
  end

  describe "threads" do
    test "the chip reads '↩ 2 replies · <time>' with no avatar circle",
         %{conn: conn, space: space, viewer: viewer, other: other} do
      parent = post_msg(space, viewer, "thread parent")
      {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)
      post_msg(space, other, "one", %{thread_id: thread.id})
      post_msg(space, other, "two", %{thread_id: thread.id})

      view = open_chat(conn, space)

      [chip] =
        view
        |> doc()
        |> LazyHTML.query(~s([data-message-id="#{parent.id}"] [data-role="thread-chip"]))
        |> Enum.to_list()

      text = chip |> LazyHTML.text() |> String.trim()
      assert text =~ ~r/\A↩ 2 replies · \S.*\z/u, inspect(text)
      assert LazyHTML.attribute(chip, "phx-click") == ["toggle_inline_thread"]
      refute render(view) =~ "thread-avatars"
    end

    test "the chip says 'reply' at one", %{conn: conn, space: space, viewer: viewer, other: other} do
      parent = post_msg(space, viewer, "single")
      {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)
      post_msg(space, other, "only", %{thread_id: thread.id})
      view = open_chat(conn, space)

      assert has_element?(view, ~s([data-role="thread-chip"]), ~r/↩ 1 reply ·/u)
    end

    test "open_inline_thread on an ALREADY expanded thread keeps it open; the footer collapses it",
         %{conn: conn, space: space, viewer: viewer, other: other} do
      parent = post_msg(space, viewer, "open only")
      {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)
      post_msg(space, other, "one", %{thread_id: thread.id})
      view = open_chat(conn, space)

      render_hook(view, "open_inline_thread", %{"message-id" => parent.id})
      assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
      assert has_element?(view, "#inline-thread-#{parent.id}")
      assert_push_event(view, "focus_inline_thread_compose", %{message_id: id})
      assert id == parent.id

      # The toggle regression: a second Reply in thread must not collapse it.
      render_hook(view, "open_inline_thread", %{"message-id" => parent.id})
      assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
      assert has_element?(view, "#inline-thread-#{parent.id}")
      assert has_element?(view, "#inline-thread-compose-#{parent.id}")

      # The footer 'collapse' collapses; the chip comes back and re-opens it.
      view
      |> element(~s(#inline-thread-#{parent.id} [data-role="thread-collapse"]), "collapse")
      |> render_click()

      refute MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
      refute has_element?(view, "#inline-thread-#{parent.id}")

      view
      |> element(~s([data-message-id="#{parent.id}"] [data-role="thread-chip"]))
      |> render_click()

      assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
    end

    test "Reply in thread on a message with no thread opens an empty one with its reply box",
         %{conn: conn, space: space, viewer: viewer} do
      msg = post_msg(space, viewer, "no thread yet")
      view = open_chat(conn, space)

      render_hook(view, "open_inline_thread", %{"message-id" => msg.id})

      assert has_element?(view, "#inline-thread-#{msg.id}")

      assert has_element?(
               view,
               ~s(#inline-thread-compose-#{msg.id}[data-placeholder="Reply in thread"])
             )

      assert has_element?(
               view,
               ~s(#inline-thread-composer-#{msg.id} button[aria-label="Send"]),
               "Send"
             )
    end

    test "the pill's ↩ and the sheet's Reply in thread both push open_inline_thread",
         %{conn: conn, space: space, viewer: viewer} do
      msg = post_msg(space, viewer, "reply routes")
      view = open_chat(conn, space)

      assert has_element?(
               view,
               ~s([data-message-id="#{msg.id}"] [data-role="message-pill"] button[aria-label="Reply in thread"][phx-click="open_inline_thread"])
             )

      render_click(view, "open_message_actions", %{"id" => msg.id})

      [row] =
        view
        |> doc()
        |> LazyHTML.query(~s(#message-actions-sheet [data-role="message-actions-reply"]))
        |> Enum.to_list()

      [js] = LazyHTML.attribute(row, "phx-click")
      assert js =~ ~s("open_inline_thread")
      refute js =~ "toggle_inline_thread"
    end

    test "Reply in thread for a message outside the open space opens nothing",
         %{conn: conn, space: space} do
      n = System.unique_integer([:positive])
      {:ok, elsewhere} = Chat.create_space(%{name: "Far #{n}", slug: "far-#{n}", kind: "channel"})

      {:ok, stranger} =
        Chat.add_participant(elsewhere.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Far Person #{n}",
          joined_at: DateTime.utc_now()
        })

      msg = post_msg(elsewhere, stranger, "far away")
      view = open_chat(conn, space)

      render_hook(view, "open_inline_thread", %{"message-id" => msg.id})
      refute MapSet.member?(lv_assigns(view).expanded_threads, msg.id)
      assert Chat.get_thread_for_message(msg.id) == nil
    end
  end

  # The side-panel events were deleted outright, with no alias. ChatLive has
  # no catch-all `handle_event/3`, so on LiveView 1.1 an unhandled event
  # raises FunctionClauseError in the LiveView process, which exits; a real
  # client then rejoins and remounts the page.
  describe "the old side-panel events are unhandled" do
    for event <- ["open_thread", "close_thread"] do
      @tag capture_log: true
      test "#{event} crashes the LiveView process (FunctionClauseError) instead of doing anything",
           %{conn: conn, space: space, viewer: viewer} do
        msg = post_msg(space, viewer, "old event")
        view = open_chat(conn, space)
        Process.flag(:trap_exit, true)
        ref = Process.monitor(view.pid)

        catch_exit(render_hook(view, unquote(event), %{"message-id" => msg.id}))

        assert_receive {:DOWN, ^ref, :process, _,
                        {:function_clause, [{PlatformWeb.ChatLive, :handle_event, args, _} | _]}}

        assert [unquote(event), _params, _socket] = args
      end
    end
  end
end
