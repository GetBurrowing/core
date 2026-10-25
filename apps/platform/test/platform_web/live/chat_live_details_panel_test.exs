defmodule PlatformWeb.ChatLiveDetailsPanelTest do
  @moduledoc """
  The desktop details panel (Burrow redesign 22 stage 3, master-desktop.html
  `#details` L603): the space sheet's sections in a right-hand aside at lg,
  rendered from the same `SpaceSheet.sections/1` as the phone sheet.

  LiveViewTest has no viewport, so "at lg" is read off the classes the
  breakpoint keys on (`hidden lg:flex`). Every refute sits beside a positive
  control on the same render.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Pin
  alias Platform.Repo

  @panel "#details-panel"

  # ── fixtures ──────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "details-#{tag}-#{n}@example.com",
      name: "Details #{tag} #{n}",
      oidc_sub: "oidc-details-#{tag}-#{n}"
    })
  end

  defp space!(kind, name) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "#{name} #{n}", slug: "details-#{kind}-#{n}", kind: kind})

    space
  end

  defp seat(space, user_id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content, thread_id \\ nil) do
    {:ok, m} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        thread_id: thread_id,
        content_type: "text",
        content: content
      })

    m
  end

  # A channel with one pinned message ("pin me") and one thread with two
  # replies, plus a second channel.
  defp world(conn) do
    user = user!("w")
    alpha = space!("channel", "Alpha")
    beta = space!("channel", "Beta")
    p = seat(alpha, user.id, user.name)
    seat(beta, user.id, user.name)

    pinned = post!(alpha, p, "pin me")
    Repo.insert!(%Pin{space_id: alpha.id, message_id: pinned.id, pinned_by: p.id})

    parent = post!(alpha, p, "the thread parent")
    {:ok, thread} = Chat.create_thread(alpha.id, %{parent_message_id: parent.id})
    post!(alpha, p, "reply one", thread.id)
    post!(alpha, p, "reply two", thread.id)

    {:ok, view, _} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat/#{alpha.slug}")

    %{view: view, user: user, alpha: alpha, beta: beta, pinned: pinned, parent: parent}
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(view, selector), do: view |> doc() |> LazyHTML.query(selector)
  defp count(view, selector), do: view |> q(selector) |> Enum.count()
  defp text(view, selector), do: view |> q(selector) |> LazyHTML.text() |> String.trim()

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_panel(view, params \\ %{"page" => "space"}),
    do: render_click(view, "details_open", params)

  defp roles(view, selector) do
    view |> q(selector) |> LazyHTML.attribute("data-role")
  end

  # ── opening ───────────────────────────────────────────────────────────

  describe "details_open at lg" do
    test "shows #details-panel on the Space segment with masters' row order", %{conn: conn} do
      w = world(conn)
      assert count(w.view, @panel) == 0

      open_panel(w.view)

      assert count(w.view, @panel) == 1
      assert count(w.view, ~s(#{@panel}[aria-label="Details"])) == 1

      classes =
        w.view |> q(@panel) |> LazyHTML.attribute("class") |> List.first() |> String.split()

      for c <-
            ~w(hidden lg:flex lg:w-[320px] lg:max-[1100px]:w-[280px] bg-base-200 lg:border-l lg:border-edge) do
        assert c in classes, "panel lacks #{c}"
      end

      assert text(w.view, "#{@panel} [data-role='details-title']") == "#" <> w.alpha.name
      assert count(w.view, ~s(#details-close[aria-label="Close details"])) == 1

      # Segments: All .. Space, Space selected.
      assert w.view |> q("#details-segs button[role='tab']") |> LazyHTML.attribute("data-seg") ==
               ~w(all canvas file site video space)

      assert count(w.view, ~s(#details-segs button[data-seg="space"][aria-selected="true"])) == 1
      assert count(w.view, ~s(#details-segs button[aria-selected="true"])) == 1

      # Rows in order; no Search in space; Hide channel last.
      assert roles(w.view, "#{@panel} [data-page='space'] > button") == [
               "details-canvases",
               "details-members",
               "details-threads",
               "details-pinned",
               "details-settings",
               "details-hide"
             ]

      assert text(w.view, "#{@panel} [data-role='details-hide']") == "Hide channel"
      assert count(w.view, "#{@panel} [data-role='details-search']") == 0
      # Counts: one thread, one pin; zero canvases renders no count.
      assert text(w.view, "#{@panel} [data-role='details-threads']") =~ ~r/Threads\s+1/
      assert text(w.view, "#{@panel} [data-role='details-pinned']") =~ ~r/Pinned\s+1/
      assert text(w.view, "#{@panel} [data-role='details-canvases']") == "Canvases in this space"

      assert_push_event(w.view, "details:changed", %{open: true})
    end

    # Stage 3's interim title button left in stage 4; the main-pane header's
    # Details toggle is the way in (chat_live_main_head_test.exs covers the
    # rest of the header).
    test "the header Details button opens it on the Space segment", %{conn: conn} do
      w = world(conn)
      assert count(w.view, ~s(button[data-role="desktop-space-title"])) == 0

      w.view |> element("#chat-details") |> render_click()

      assert lv_assigns(w.view).details_panel == :space
      assert count(w.view, @panel) == 1
    end

    test "a DM ends with Close conversation and has no Members row", %{conn: conn} do
      user = user!("dm")
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})
      seat(dm, user.id, user.name)
      seat(dm, Ecto.UUID.generate(), "Moore")

      {:ok, view, _} =
        conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat/#{dm.slug || dm.id}")

      open_panel(view)
      rows = roles(view, "#{@panel} [data-page='space'] > button")
      assert List.last(rows) == "details-close-dm"
      assert text(view, "#{@panel} [data-role='details-close-dm']") == "Close conversation"
      refute "details-members" in rows
      refute "details-hide" in rows
      assert "details-settings" in rows
    end

    test "with no open space it is ignored", %{conn: conn} do
      user = user!("none")

      {:ok, view, _} =
        conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat")

      open_panel(view)
      assert lv_assigns(view).details_panel == nil
      assert count(view, @panel) == 0
      assert count(view, "#details-panel-state") == 1
    end
  end

  # ── pages ─────────────────────────────────────────────────────────────

  describe "pages" do
    test "Pinned lists the pinned message, Back returns to Space", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)

      w.view |> element("#{@panel} [data-role='details-pinned']") |> render_click()

      assert lv_assigns(w.view).details_panel == :pinned

      assert count(
               w.view,
               "#{@panel} [data-role='details-pin'][data-message-id='#{w.pinned.id}']"
             ) == 1

      assert text(w.view, "#{@panel} [data-role='details-pin-open']") =~ "pin me"

      w.view |> element("#{@panel} [data-role='details-back']") |> render_click()
      assert lv_assigns(w.view).details_panel == :space
      assert count(w.view, "#{@panel} [data-page='space']") == 1
    end

    test "Threads lists the thread with 2 replies", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)

      w.view |> element("#{@panel} [data-role='details-threads']") |> render_click()

      assert count(
               w.view,
               "#{@panel} [data-role='details-thread'][data-message-id='#{w.parent.id}']"
             ) ==
               1

      assert text(w.view, "#{@panel} [data-role='details-thread']") =~ "2 replies"
    end

    test "a links segment shows the empty copy", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)

      w.view |> element(~s(#details-segs button[data-seg="file"])) |> render_click()

      assert lv_assigns(w.view).details_panel == {:links, :file}

      assert text(w.view, "#{@panel} [data-role='details-links-empty']") ==
               "Nothing shared here yet."
    end

    test "Space settings opens #chat-settings and the panel stays open", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      refute render(w.view) =~ "Channel Settings"

      html = w.view |> element("#{@panel} [data-role='details-settings']") |> render_click()

      assert html =~ "Channel Settings"
      assert count(w.view, ~s(#chat-settings [role="dialog"][aria-modal="true"])) == 1
      assert lv_assigns(w.view).details_panel == :space
      assert count(w.view, @panel) == 1
    end

    test "Hide channel hides it and the panel stays open", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)

      w.view |> element("#{@panel} [data-role='details-hide']") |> render_click()

      assert MapSet.member?(lv_assigns(w.view).hidden_channel_ids, w.alpha.id)
      assert count(w.view, @panel) == 1
    end

    test "no panel row pushes close_space_sheet; every sheet action row still does", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      render_click(w.view, "open_space_sheet", %{})
      render_click(w.view, "space_sheet_page", %{"page" => "space"})

      panel_clicks = w.view |> q("#{@panel} [phx-click]") |> LazyHTML.attribute("phx-click")
      assert length(panel_clicks) >= 6
      refute Enum.any?(panel_clicks, &(&1 =~ "close_space_sheet"))

      settings =
        w.view
        |> q("#space-sheet [data-role='space-sheet-settings']")
        |> LazyHTML.attribute("phx-click")

      assert [click] = settings
      assert click =~ "close_space_sheet"
      assert click =~ "settings_open"
    end
  end

  # ── staying open ──────────────────────────────────────────────────────

  describe "switching conversation" do
    test "keeps the panel open on the same segment with the new name", %{conn: conn} do
      w = world(conn)
      open_panel(w.view, %{"page" => "links", "seg" => "all"})

      render_patch(w.view, ~p"/chat/#{w.beta.slug}")

      assert lv_assigns(w.view).details_panel == {:links, :all}
      assert text(w.view, "#{@panel} [data-role='details-title']") == "#" <> w.beta.name
      assert lv_assigns(w.view).details_space_id == w.beta.id
    end

    test "a pushed page goes back to the Space segment, with the new space's data", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      render_click(w.view, "details_page", %{"page" => "pinned"})
      assert length(lv_assigns(w.view).details_pins) == 1

      render_patch(w.view, ~p"/chat/#{w.beta.slug}")

      assert lv_assigns(w.view).details_panel == :space
      assert lv_assigns(w.view).details_pins == []
      assert lv_assigns(w.view).details_threads == []
      assert text(w.view, "#{@panel} [data-role='details-title']") == "#" <> w.beta.name
    end
  end

  describe "closing" do
    test "details_close removes the panel and pushes details:changed false", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      assert count(w.view, @panel) == 1

      w.view |> element("#details-close") |> render_click()

      assert count(w.view, @panel) == 0
      assert lv_assigns(w.view).details_panel == nil
      assert_push_event(w.view, "details:changed", %{open: false})
      # The state node outlives the panel, with the viewer and the state.
      assert count(
               w.view,
               ~s(#details-panel-state[data-user-id="#{w.user.id}"][data-open="false"])
             ) ==
               1
    end

    test "details_restore opens a closed panel on Space and no-ops on an open one", %{conn: conn} do
      w = world(conn)
      assert count(w.view, ~s(#details-panel-state[data-open="false"])) == 1

      render_click(w.view, "details_restore", %{})
      assert lv_assigns(w.view).details_panel == :space
      assert count(w.view, ~s(#details-panel-state[data-open="true"])) == 1

      render_click(w.view, "details_page", %{"page" => "threads"})
      render_click(w.view, "details_restore", %{})
      assert lv_assigns(w.view).details_panel == :threads
    end
  end

  # ── ids and messages ──────────────────────────────────────────────────

  describe "the sheet and the panel together" do
    test "no DOM id appears twice on any page with both open", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      render_click(w.view, "open_space_sheet", %{})

      for page <- ~w(space search pinned threads goal scope) do
        render_click(w.view, "space_sheet_page", %{"page" => page})
        render_click(w.view, "details_page", %{"page" => page})
        assert count(w.view, "#space-sheet[data-open='true']") == 1
        assert count(w.view, @panel) == 1

        ids = w.view |> q("[id]") |> LazyHTML.attribute("id")
        assert length(ids) > 50
        dups = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
        assert dups == [], "duplicate ids on #{page}: #{inspect(dups)}"
      end

      # Search page on both: the prefixed form ids are both present.
      render_click(w.view, "space_sheet_page", %{"page" => "search"})
      render_click(w.view, "details_page", %{"page" => "search"})
      assert count(w.view, "#space-sheet-search-form") == 1
      assert count(w.view, "#details-search-form") == 1
    end

    test "an unknown message with the panel open is absorbed", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      send(w.view.pid, {:details_panel_unknown, :boom})
      send(w.view.pid, :details_panel_unknown)
      assert count(w.view, @panel) == 1
      assert Process.alive?(w.view.pid)
    end

    test "a pin broadcast re-reads an open Pinned page", %{conn: conn} do
      w = world(conn)
      open_panel(w.view)
      render_click(w.view, "details_page", %{"page" => "pinned"})
      assert length(lv_assigns(w.view).details_pins) == 1

      Repo.delete_all(Pin)
      send(w.view.pid, {:pin_removed, %{space_id: w.alpha.id, message_id: w.pinned.id}})

      assert count(w.view, "#{@panel} [data-role='details-pins-empty']") == 1
      assert lv_assigns(w.view).details_pins == []
    end
  end
end
