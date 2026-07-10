defmodule PlatformWeb.ChatLiveRowReorderTest do
  @moduledoc """
  Render-level tests for mobile channel-row reorder Stage 1 —
  select-to-reveal ▲▼ buttons in the Conversations drawer's edit mode.

  Coverage:
    * edit-mode rows are not navigation links (mis-tap can no longer
      eject the user from edit mode)
    * every edit-mode row shows its ▲▼ pair persistently (Marlowe a11y
      request 2026-07-09, reversing the July 6 select-to-reveal design)
    * ▼/▲ reorder within the section via the EXISTING move_channel
      pipeline and persist across a remount (chat_channel_order pref)
    * boundary buttons disabled (first row's ▲, last row's ▼)
    * search guard rail: row edit chrome vanishes while filtering and the
      selection is dropped
    * DM section: edit-mode-only "Sorted by recent activity" caption; DM
      rows carry no reorder chrome
    * browse mode unchanged: rows are still navigation links
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "row_reorder_test@example.com",
        name: "Row Reorder Tester",
        oidc_sub: "oidc-row-reorder",
        avatar_url: nil
      })

    init_test_session(conn, current_user_id: user.id)
  end

  # Two channels in the SAME (first) org section, so within-section moves
  # are exercised for real. org_id pins the section deterministically.
  defp seed_two_rows_one_section do
    [s1 | _] = Platform.Chat.Section |> Repo.all() |> Enum.sort_by(& &1.position)

    {:ok, ch1} =
      Chat.create_space(%{name: "Rowone", slug: "rowone", kind: "channel", org_id: s1.org_id})

    {:ok, ch2} =
      Chat.create_space(%{name: "Rowtwo", slug: "rowtwo", kind: "channel", org_id: s1.org_id})

    {s1, ch1, ch2}
  end

  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp open_mobile_browser(conn) do
    {:ok, view, _html} = live_following_redirect(conn)

    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()

    view
  end

  defp enter_sidebar_edit(view) do
    view
    |> element(~s(#mobile-channel-browser header button[phx-click="toggle_sidebar_edit"]))
    |> render_click()

    view
  end

  # Rendered channel-id order inside the mobile drawer only (the drawer
  # renders AFTER the desktop rail in the DOM, so split-last isolates it).
  defp drawer_row_ids(html) do
    drawer = html |> String.split(~s(id="mobile-channel-browser")) |> List.last()

    ~r/data-channel-id="([^"]+)"/
    |> Regex.scan(drawer)
    |> Enum.map(fn [_, id] -> id end)
  end

  defp row_selector(ch), do: ~s(#mobile-channel-browser div[data-channel-id="#{ch.id}"])

  describe "edit-mode row interaction" do
    test "rows are not links and every row shows its ▲▼ pair", %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, ch1, ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      refute has_element?(
               view,
               ~s(#mobile-channel-browser a[href="/chat/#{ch1.slug}"])
             ),
             "Edit-mode rows must not be navigation links"

      # ▲▼ are persistent on every row — no tap-to-reveal step (Marlowe a11y
      # request 2026-07-09; matches the section headers' always-on chevrons).
      assert has_element?(view, ~s(#{row_selector(ch1)} .channel-row-move-controls--touch)),
             "First row must show its move buttons without any interaction"

      assert has_element?(view, ~s(#{row_selector(ch2)} .channel-row-move-controls--touch)),
             "Every row shows its move buttons, not just one"
    end

    test "boundary buttons are disabled on first/last rows", %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, ch1, ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      assert has_element?(view, ~s(#{row_selector(ch1)} button[title="Move up"][disabled]))
      refute has_element?(view, ~s(#{row_selector(ch1)} button[title="Move down"][disabled]))
      assert has_element?(view, ~s(#{row_selector(ch2)} button[title="Move down"][disabled]))
    end

    test "▼ swaps the row with its neighbour and persists across remount", %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, ch1, ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      assert drawer_row_ids(render(view)) == [ch1.id, ch2.id]

      view
      |> element(~s(#{row_selector(ch1)} button[title="Move down"]))
      |> render_click()

      assert drawer_row_ids(render(view)) == [ch2.id, ch1.id],
             "Move down should swap the two rows"

      # Same persistence contract as desktop: fresh mount keeps the order.
      # (Row ids only render in edit mode, so re-enter it first.)
      {:ok, view2, _html} = live_following_redirect(conn)

      view2
      |> element(~s(button[phx-click="toggle_mobile_browser"]))
      |> render_click()

      enter_sidebar_edit(view2)

      assert drawer_row_ids(render(view2)) == [ch2.id, ch1.id],
             "Row order should persist via chat_channel_order"
    end
  end

  describe "guard rails" do
    test "row edit chrome vanishes while searching", %{conn: conn} do
      conn = authenticated_conn(conn)
      seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)
      assert has_element?(view, "#mobile-channel-browser .channel-row-move-controls--touch")

      view
      |> element(~s(#mobile-channel-browser form[phx-change="drawer_search"]))
      |> render_change(%{"value" => "row"})

      refute has_element?(view, ~s(#mobile-channel-browser div[data-channel-id])),
             "Filtered rows must render as plain rows/links, without edit chrome"

      refute has_element?(view, "#mobile-channel-browser .channel-row-move-controls--touch"),
             "Move buttons are hidden while the list is filtered"
    end

    test "browse mode keeps rows as navigation links", %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, ch1, _ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)

      refute has_element?(view, ~s(#mobile-channel-browser div[data-channel-id="#{ch1.id}"]))

      assert has_element?(view, ~s(#mobile-channel-browser a), "Rowone"),
             "Browse-mode rows stay links"
    end

    test "DM section: edit-only recency caption, no reorder chrome on DM rows", %{conn: conn} do
      conn = authenticated_conn(conn)
      seed_two_rows_one_section()

      view = open_mobile_browser(conn)

      refute has_element?(view, "#mobile-channel-browser", "Sorted by recent activity"),
             "Caption is edit-mode chrome only"

      enter_sidebar_edit(view)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"]),
               "Sorted by recent activity"
             )

      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] [data-channel-id])
             ),
             "DM rows must carry no reorder identity/chrome"
    end
  end

  describe "touch drag wiring (Stage 2)" do
    # The gesture itself (400ms hold, slop, clamping) is client-side JS and
    # is verified by browser-level touch emulation at review; these tests pin
    # the server-rendered wiring the hook depends on and the server pipeline
    # the drop pushes into.

    test "RowReorderTouch wrapper wraps the drawer list with the search guard", %{conn: conn} do
      conn = authenticated_conn(conn)
      seed_two_rows_one_section()

      view = open_mobile_browser(conn)

      assert has_element?(
               view,
               ~s(#mobile-section-list #mobile-row-reorder-scope[phx-hook="RowReorderTouch"][data-search-active="false"])
             ),
             "Row hook needs its own element nested under the section hook's nav"

      enter_sidebar_edit(view)
      view |> element(~s(#mobile-channel-browser form)) |> render_change(%{"value" => "row"})

      assert has_element?(
               view,
               ~s(#mobile-row-reorder-scope[data-search-active="true"])
             ),
             "Search guard must mirror onto the row hook's own root"
    end

    test "edit-mode rows render a live drag handle; browse mode and search do not",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, ch1, _ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)

      refute has_element?(view, "#mobile-channel-browser .channel-row-drag-handle"),
             "Browse mode renders no row drag handles"

      enter_sidebar_edit(view)

      assert has_element?(
               view,
               ~s(#{row_selector(ch1)} button.channel-row-drag-handle[aria-label="Reorder #Rowone — touch and hold, then drag"][tabindex="-1"])
             )

      view |> element(~s(#mobile-channel-browser form)) |> render_change(%{"value" => "row"})

      refute has_element?(view, "#mobile-channel-browser .channel-row-drag-handle"),
             "Handles must vanish while the list is filtered"
    end

    test "edit-mode explainer teaches the drag gesture", %{conn: conn} do
      conn = authenticated_conn(conn)
      seed_two_rows_one_section()

      view = open_mobile_browser(conn)

      refute has_element?(view, "#mobile-row-reorder-scope", "Reorder with the arrows"),
             "Explainer is edit-mode chrome only"

      enter_sidebar_edit(view)

      assert has_element?(view, "#mobile-row-reorder-scope", "Reorder with the arrows")

      view |> element(~s(#mobile-channel-browser form)) |> render_change(%{"value" => "row"})

      refute has_element?(view, "#mobile-row-reorder-scope", "Reorder with the arrows"),
             "Explainer hides while searching (reorder is disabled there)"
    end

    test "channel_moved from the drawer reorders within the section and persists",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {s1, ch1, ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      html = render(view)
      assert drawer_row_ids(html) |> Enum.filter(&(&1 in [ch1.id, ch2.id])) == [ch1.id, ch2.id]

      # The payload RowReorderTouch pushes on drop — target section is always
      # the row's OWN section (within-section clamp).
      render_hook(view, "channel_moved", %{
        "channel_id" => ch2.id,
        "target_section_id" => s1.id,
        "ordered_ids" => [ch2.id, ch1.id]
      })

      html = render(view)
      assert drawer_row_ids(html) |> Enum.filter(&(&1 in [ch1.id, ch2.id])) == [ch2.id, ch1.id]

      # Persists across a full remount (per-user chat_channel_order pref).
      view2 = open_mobile_browser(conn)
      enter_sidebar_edit(view2)
      html2 = render(view2)
      assert drawer_row_ids(html2) |> Enum.filter(&(&1 in [ch1.id, ch2.id])) == [ch2.id, ch1.id]
    end

    test "reorder announces to the aria-live region for both input paths", %{conn: conn} do
      conn = authenticated_conn(conn)
      {s1, ch1, ch2} = seed_two_rows_one_section()

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      # Region exists (empty) before any move — aria-live only announces
      # changes to a region already in the DOM.
      assert has_element?(view, ~s(#mobile-channel-browser [aria-live="polite"]))

      # Arrow path announces with direction.
      view
      |> element(~s(#{row_selector(ch1)} button[title="Move down"]))
      |> render_click()

      assert has_element?(
               view,
               ~s(#mobile-channel-browser [aria-live="polite"]),
               "Moved #Rowone down"
             )

      # Drag path (channel_moved) announces without direction.
      render_hook(view, "channel_moved", %{
        "channel_id" => ch2.id,
        "target_section_id" => s1.id,
        "ordered_ids" => [ch2.id, ch1.id]
      })

      assert has_element?(
               view,
               ~s(#mobile-channel-browser [aria-live="polite"]),
               "Moved #Rowtwo"
             )
    end
  end
end
