defmodule PlatformWeb.Components.ChatVersionHistoryTest do
  @moduledoc """
  Version history (redesign rung 9 stage 4, task 01a1557a-9406; masters stub
  'Version history', direction canvas 01a1666e node m3 rule 7): '(edited)'
  opens a read-only phone sheet and a desktop popover from the one
  `@version_history` assign, newest FIRST, with a server-side word diff.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.Components.ChatVersionHistory

  describe "word_diff/2 (pure)" do
    test "a changed word is one removed run and one added run" do
      assert ChatVersionHistory.word_diff("ship it today", "ship it tomorrow") ==
               [{:eq, "ship it "}, {:del, "today"}, {:ins, "tomorrow"}]
    end

    test "joining the kept and removed runs rebuilds the old text, kept and added the new" do
      old = "The build is green.\nShip it  after lunch."
      new = "The build is red.\nShip it tomorrow after lunch, maybe."
      diff = ChatVersionHistory.word_diff(old, new)

      assert for({op, t} <- diff, op in [:eq, :del], into: "", do: t) == old
      assert for({op, t} <- diff, op in [:eq, :ins], into: "", do: t) == new
    end

    test "identical text is one kept run; empty or nil sides are pure adds or removes" do
      assert ChatVersionHistory.word_diff("same words", "same words") == [{:eq, "same words"}]
      assert ChatVersionHistory.word_diff(nil, "new") == [{:ins, "new"}]
      assert ChatVersionHistory.word_diff("gone", "") == [{:del, "gone"}]
    end

    test "it compares words, not characters" do
      assert ChatVersionHistory.word_diff("cat", "cart") == [{:del, "cat"}, {:ins, "cart"}]
    end
  end

  describe "rows/1" do
    test "orders newest first and labels Current, the times between, and Original" do
      at = ~U[2026-10-24 10:00:00Z]

      versions =
        for n <- [1, 3, 2],
            do: %{id: "v#{n}", version_number: n, content: "text #{n}", edited_at: at}

      rows = ChatVersionHistory.rows(versions)
      assert Enum.map(rows, & &1.id) == ["v3", "v2", "v1"]
      assert Enum.map(rows, & &1.label) == ["Current", nil, "Original"]
      assert "edited " <> _ = hd(rows).meta
      refute String.starts_with?(List.last(rows).meta, "edited")
      assert hd(rows).diff == ChatVersionHistory.word_diff("text 2", "text 3")
      assert List.last(rows).diff == [{:eq, "text 1"}]
    end
  end

  describe "in the chat" do
    setup %{conn: conn} do
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%User{
          email: "history_#{n}@example.com",
          name: "History Viewer",
          oidc_sub: "oidc-history-#{n}"
        })

      {:ok, space} =
        Chat.create_space(%{name: "History #{n}", slug: "history-#{n}", kind: "channel"})

      {:ok, viewer} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })

      {:ok, msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: viewer.id,
          content_type: "text",
          content: "ship it today"
        })

      {:ok, conn: init_test_session(conn, current_user_id: user.id), space: space, msg: msg}
    end

    defp edit(view, msg, body) do
      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})
      render_hook(view, "save_edit", %{"message_id" => msg.id, "body" => body})
    end

    test "two edits give three versions, newest first, in the sheet and the popover",
         %{conn: conn, space: space, msg: msg} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      edit(view, msg, "ship it tomorrow")
      edit(view, msg, "ship it tomorrow morning")

      assert has_element?(
               view,
               ~s([data-message-id="#{msg.id}"] [data-role="message-edited"]),
               "(edited)"
             )

      render_click(view, "show_version_history", %{"message-id" => msg.id})
      doc = view |> render() |> LazyHTML.from_document()

      for frame <- ["#version-history-sheet-list", "#version-history-popover-list"] do
        rows = LazyHTML.query(doc, ~s(#{frame} [data-role="version-row"]))
        assert Enum.count(rows) == 3, frame

        texts = Enum.map(rows, &(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ")))
        assert Enum.at(texts, 0) =~ "Current"
        assert Enum.at(texts, 0) =~ "edited "
        assert Enum.at(texts, 0) =~ "morning"
        assert Enum.at(texts, 1) =~ "tomorrow"
        refute Enum.at(texts, 1) =~ "morning"
        assert Enum.at(texts, 2) =~ "Original"
        assert Enum.at(texts, 2) =~ "ship it today"
      end
    end

    test "(edited) survives a reinsert of the row (a cancelled edit)",
         %{conn: conn, space: space, msg: msg} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      edit(view, msg, "ship it tomorrow")
      affix = ~s([data-message-id="#{msg.id}"] [data-role="message-edited"])
      assert has_element?(view, affix)

      render_hook(view, "edit_message_clicked", %{"message-id" => msg.id})
      render_hook(view, "cancel_edit", %{})

      assert has_element?(view, affix, "(edited)")
    end

    # A continuation row (same author as the row above) is marked
    # `.message-row--grouped` client-side by ScrollToBottom.applyGrouping(),
    # and app.css hides EVERY child of its `.message-header`. LiveView cannot
    # evaluate CSS, so this asserts the structure the rule depends on: the
    # affix on a continuation row is a real button and is not inside the
    # header the rule hides (failed e2e cases 7009 and 700a).
    test "(edited) on a continuation row sits outside the header a grouped row hides",
         %{conn: conn, space: space, msg: msg} do
      {:ok, follow_up} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: msg.participant_id,
          content_type: "text",
          content: "and the docs"
        })

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      edit(view, follow_up, "and the docs too")

      row = ~s([data-message-id="#{follow_up.id}"])

      assert has_element?(view, ~s(#{row} button[data-role="message-edited"]), "(edited)")
      assert has_element?(view, ~s(#{row} .message-header))
      refute has_element?(view, ~s(#{row} .message-header [data-role="message-edited"]))

      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
      assert css =~ ".message-row--grouped .message-header > * {\n  display: none;"
    end

    test "the sheet swipes and closes like every sheet; the popover is the desktop frame",
         %{conn: conn, space: space, msg: msg} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      edit(view, msg, "ship it tomorrow")
      render_click(view, "show_version_history", %{"message-id" => msg.id})

      assert has_element?(view, "#version-history-sheet[data-swipe-dismiss]")
      assert has_element?(view, "#version-history-sheet.lg\\:hidden")

      assert has_element?(
               view,
               ~s(#version-history-popover.hidden.lg\\:block[phx-click-away="close_version_history"])
             )

      assert has_element?(view, ~s(#version-history-popover[data-anchor-message-id="#{msg.id}"]))

      render_click(view, "close_version_history", %{})
      refute has_element?(view, "#version-history-sheet")
      refute has_element?(view, "#version-history-popover")
    end

    test "a changed word renders as del and ins; it is read-only",
         %{conn: conn, space: space, msg: msg} do
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      edit(view, msg, "ship it tomorrow")
      render_click(view, "show_version_history", %{"message-id" => msg.id})

      assert has_element?(
               view,
               "#version-history-sheet-list del.line-through.text-subtle",
               "today"
             )

      assert has_element?(
               view,
               "#version-history-sheet-list ins.bg-base-300.no-underline",
               "tomorrow"
             )

      assert has_element?(view, "#version-history-popover-list del", "today")
      assert has_element?(view, "#version-history-popover-list ins", "tomorrow")

      # Read-only: nothing in either frame edits, restores or submits.
      refute has_element?(view, "#version-history-sheet-list button")
      refute has_element?(view, "#version-history-popover button")
      refute has_element?(view, "#version-history-popover form")
    end
  end
end
