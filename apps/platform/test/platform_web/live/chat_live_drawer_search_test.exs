defmodule PlatformWeb.ChatLiveDrawerSearchTest do
  @moduledoc """
  Render-level tests for the mobile Conversations-drawer search
  (mobile channel search Stage 1).

  Coverage:
    * search input renders in the drawer (stable id, find-verb placeholder)
    * filter-as-you-type: matching channel rows stay, zero-match sections
      drop out entirely (including their empty-state hints)
    * DM rows filter on their computed display name; the DM section hides
      when no DM matches; the "No conversations yet" copy never doubles as
      a no-match state
    * dedicated "No matches" state + Clear search restores the full list
    * guard rails: reorder affordances (drag handle + move buttons) vanish
      while a filter is active; entering edit mode clears the search
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp insert_user(email, name, sub) do
    Repo.insert!(%User{email: email, name: name, oidc_sub: sub, avatar_url: nil})
  end

  defp authenticated_conn(conn) do
    user =
      insert_user("drawer_search_test@example.com", "Drawer Search Tester", "oidc-drawer-search")

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_channel(slug) do
    {:ok, ch} = Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})
    ch
  end

  # `GET /chat` live-redirects to the first channel once one exists; follow it.
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

  # Drive the search form's phx-change — the binding that real typing,
  # paste, dictation, and the native type=search clear all funnel through.
  defp search(view, query) do
    view
    |> element(~s(#mobile-channel-browser form[phx-change="drawer_search"]))
    |> render_change(%{"value" => query})

    view
  end

  defp enter_sidebar_edit(view) do
    view
    |> element(~s(#mobile-channel-browser header button[phx-click="toggle_sidebar_edit"]))
    |> render_click()

    view
  end

  describe "search field" do
    test "renders in the drawer with stable id and find-verb placeholder", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser input#drawer-search-input[placeholder="Find a channel or DM"])
             ),
             "Drawer should render the search input with its stable id"
    end
  end

  describe "filter-as-you-type" do
    test "matching channels stay; zero-match sections drop out with their empty hints",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # Baseline: empty org sections render their headers + empty hints.
      assert has_element?(view, "#mobile-channel-browser", "Paragon")
      assert has_element?(view, "#mobile-channel-browser", "No channels yet")

      search(view, "gener")

      # The match stays, under its section header.
      assert has_element?(view, ~s(#mobile-channel-browser nav a), "General"),
             "Matching channel row should stay visible"

      # Zero-match sections vanish entirely — headers AND empty hints.
      refute has_element?(view, ~s(#mobile-channel-browser section[aria-label="SXI channels"])),
             "Zero-match section should drop out"

      refute has_element?(view, "#mobile-channel-browser nav", "No channels yet"),
             "Empty-section hints must not render while filtering"
    end

    test "clearing the search restores the full sectioned list", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      search(view, "zzz-no-match")

      refute has_element?(view, ~s(#mobile-channel-browser section[aria-label="SXI channels"]))

      view
      |> element(~s(#mobile-channel-browser button[aria-label="Clear search"]))
      |> render_click()

      assert has_element?(view, ~s(#mobile-channel-browser section[aria-label="SXI channels"])),
             "Clear must restore the full sectioned browse list"
    end
  end

  describe "DM filtering" do
    test "DMs filter on display name; DM section hides when nothing matches", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      create_channel("general")
      partner = insert_user("dm_partner@example.com", "Zelda Partner", "oidc-dm-partner")
      {:ok, _dm} = Chat.find_or_create_dm(user.id, "user", partner.id)

      view = open_mobile_browser(conn)

      # DM row shows the partner's display name.
      assert has_element?(view, "#mobile-channel-browser", "Zelda Partner")

      # Display-name match keeps the DM section + row.
      search(view, "zelda")

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] a),
               "Zelda Partner"
             )

      # A channel-only match hides the whole DM section — and the
      # "No conversations yet" copy must NOT appear as a fake no-match state.
      search(view, "gener")

      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"])
             ),
             "DM section should hide when no DM matches"

      refute has_element?(view, "#mobile-channel-browser", "No conversations yet"),
             "Genuinely-empty DM copy must never render for a no-match filter"
    end
  end

  describe "no-matches state" do
    test "renders the dedicated copy with New conversation + Clear search", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      search(view, "zzz-no-match")

      assert has_element?(view, "#mobile-channel-browser", "No matches for"),
             "No-match search should show the dedicated empty state"

      assert has_element?(view, ~s(#mobile-channel-browser button), "New conversation")
      assert has_element?(view, ~s(#mobile-channel-browser button), "Clear search")
    end
  end

  describe "search-forward entry (Stage 2)" do
    test "magnifying glass declares search intent and the input mounts the focus hook",
         %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      {:ok, view, _html} = live_following_redirect(conn)

      # The opener carries the intent...
      assert has_element?(
               view,
               ~s(button[phx-click="toggle_mobile_browser"][phx-value-intent="search"])
             ),
             "Pills-strip magnifying glass should declare search intent"

      view
      |> element(~s(button[phx-click="toggle_mobile_browser"]))
      |> render_click(%{"intent" => "search"})

      # ...and the drawer's input advertises it to the DrawerSearchFocus hook.
      assert has_element?(
               view,
               ~s(#drawer-search-input[phx-hook="DrawerSearchFocus"][data-search-intent="true"])
             ),
             "Search-intent open should mount the input with data-search-intent=true"
    end

    test "an open without search intent renders a browse-first drawer", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      {:ok, view, _html} = live_following_redirect(conn)

      # The only current opener (magnifying glass) always carries the
      # intent, so the browse-first contract is exercised at the event
      # level — the path any future intent-less opener would take.
      render_click(view, "toggle_mobile_browser", %{})

      assert has_element?(view, ~s(#drawer-search-input[data-search-intent="false"])),
             "Intent-less open must not request focus"
    end

    test "the DM + people picker uses people vocabulary, not find vocabulary", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # The DM "+" opens the new-conversation picker (and closes the drawer).
      view
      |> element(~s(#mobile-channel-browser button[aria-label="New conversation"]))
      |> render_click()

      assert has_element?(view, ~s(input[placeholder="Search people…"])),
             "People picker should say Search people — never share the drawer's find-verbs"
    end
  end

  describe "reorder guard rails" do
    test "drag handle and move buttons vanish while a filter is active", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      assert has_element?(view, "#mobile-channel-browser .channel-section-drag-handle--touch")
      assert has_element?(view, "#mobile-channel-browser .channel-section-move-controls")

      search(view, "gener")

      refute has_element?(view, "#mobile-channel-browser .channel-section-drag-handle--touch"),
             "Drag handles must be omitted while filtering"

      refute has_element?(view, "#mobile-channel-browser .channel-section-move-controls"),
             "Move buttons must be omitted while filtering"

      # The rail advertises the active filter so SectionReorderTouch
      # short-circuits even against a stale DOM.
      assert has_element?(view, ~s(#mobile-section-list[data-search-active="true"]))
    end

    test "entering edit mode clears an active search", %{conn: conn} do
      {conn, _user} = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      search(view, "gener")

      refute has_element?(view, ~s(#mobile-channel-browser section[aria-label="SXI channels"]))

      enter_sidebar_edit(view)

      # Query cleared server-side: full list back, reorder affordances usable.
      assert has_element?(view, ~s(#mobile-channel-browser section[aria-label="SXI channels"])),
             "Edit mode must clear the search so the FULL list is editable"

      assert has_element?(view, "#mobile-channel-browser .channel-section-drag-handle--touch")
      assert has_element?(view, ~s(#mobile-section-list[data-search-active="false"]))
    end
  end
end
