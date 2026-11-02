defmodule PlatformWeb.ChatLiveSectionRenderTest do
  @moduledoc """
  Render-level tests for the desktop Chat list pane on `/chat/:slug`, against
  real DB-backed spaces.

  Burrow redesign 22 stage 2 deleted the desktop channel rail: its per-org
  section headers and order, empty-org hints, colour dots, drag handles, the
  rail's `hidden lg:flex` gate and the collapsed-section unread peek ("Show
  all (N)") are gone, so those cases are deleted. The behaviours that survive
  are retargeted at the Chat list (`#chat-list`):

    * Uncapped: every channel renders, no truncation toggle
    * Per-channel hide lives in the row menu (`open_row_actions`), not on the
      row, and not for a pinned row; hiding removes the row and persists
    * The Spaces section folds through `toggle_section_collapsed`, keeps its
      header, unfolds, and the fold persists across a remount
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo

  @spaces_fold "chat-list:spaces"

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    init_test_session(conn, current_user_id: user.id)
  end

  defp user_id(conn), do: Plug.Conn.get_session(conn, :current_user_id)

  # The row's menu (`row_actions_dialog/1`). At lg it opens on right-click of a
  # Chat list row; the RowContextMenu hook pushes `open_row_actions`.
  #
  # `LazyHTML.query/2`, not `filter/2`: filter keeps ROOT nodes matching the
  # selector, and the roots of a rendered page are `<html>` and friends.
  defp open_row_menu(view, space_id) do
    view
    |> render_hook("open_row_actions", %{"space_id" => space_id})
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="row-actions-dialog"]))
    |> LazyHTML.to_html()
  end

  defp insert_chat_user do
    Repo.insert!(%User{
      email: "section_render_test@example.com",
      name: "Section Render Test User",
      oidc_sub: "oidc-section-render-test",
      avatar_url: nil,
      preferences: %{"first_run_goal" => "existing"}
    })
  end

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    ch
  end

  # `/chat` is the phone Chat list and does not redirect. Land in the first
  # channel the way a desktop viewport does: the ViewportBreakpoint hook's
  # `below: false` report.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} ->
        live(conn, path)

      {:ok, view, _html} ->
        render_hook(view, "chat_viewport", %{"below" => false})
        {:ok, view, render(view)}
    end
  end

  # A Chat list row, scoped to the list's scroller: the search and popover
  # rows carry the same data-role.
  defp row_selector(space_id),
    do: ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{space_id}"])

  defp spaces_row_selector(space_id),
    do:
      ~s(#chat-list-scroller [data-role="chat-list-spaces"] a[data-role="chat-list-row"][data-space-id="#{space_id}"])

  defp spaces_toggle_selector(expanded?),
    do:
      ~s(#chat-list [data-role="chat-list-section-toggle"][data-section="#{@spaces_fold}"][aria-expanded="#{expanded?}"])

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "uncapped list" do
    test "20+ channels render every row; no truncation toggle", %{conn: conn} do
      conn = authenticated_conn(conn)

      channels = for n <- 1..20, do: create_channel("acme-test-#{n}")

      {:ok, view, html} = live_following_redirect(conn)

      for channel <- channels do
        assert has_element?(view, spaces_row_selector(channel.id)),
               "#{channel.name} should render; the list has no cap"
      end

      refute html =~ "channel-section-show-more"
      refute html =~ ~s(phx-click="toggle_section")
    end
  end

  describe "per-channel hide affordance" do
    test "the hide action is in a channel row's menu, not on the row, and not in a pinned row's menu",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      channel = create_channel("general")

      {:ok, view, _html} = live_following_redirect(conn)

      # Positive control: the row is in the list, and it carries no inline hide.
      assert has_element?(view, row_selector(channel.id))
      refute has_element?(view, ~s(#chat-list [phx-click="hide_channel"]))

      menu = open_row_menu(view, channel.id)

      assert menu =~ ~s(phx-click="hide_channel"),
             "The channel row's menu does not carry the hide action"

      assert menu =~ ~s(phx-value-id="#{channel.id}"),
             "The menu's hide action is not wired to this row's space id"

      # A pinned row must not offer hide: the hidden list reverses by CHANNEL,
      # and a pinned row has no way back.
      {:ok, _} = Sidebar.set_space_pinned(user_id(conn), channel.id, true)
      {:ok, pinned_view, _html} = live_following_redirect(conn)

      pinned_menu = open_row_menu(pinned_view, channel.id)
      assert pinned_menu =~ ~s(data-role="pin-control"), "the pinned row's menu did not open"

      refute pinned_menu =~ ~s(phx-click="hide_channel"),
             "A Pinned row's menu offers hide, which has no way back for that row"
    end

    test "hiding from the menu removes the row from the rendered list", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("hide-me")
      other = create_channel("keep-me")

      {:ok, view, _html} = live_following_redirect(conn)

      assert has_element?(view, row_selector(target.id)),
             "The target's row is missing before the hide"

      assert has_element?(view, row_selector(other.id))

      _ = open_row_menu(view, target.id)

      view
      |> element(~s(button[data-role="rail-row-actions-hide"][data-space-id="#{target.id}"]))
      |> render_click()

      refute has_element?(view, row_selector(target.id)),
             "Hidden channel's row should be removed from the Chat list"

      assert has_element?(view, row_selector(other.id)),
             "Unrelated channel should still render after hiding the target"
    end

    test "hidden state survives a remount (preference is persisted)", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("persist-me")
      other = create_channel("stay-me")

      {:ok, view, _} = live_following_redirect(conn)

      _ = open_row_menu(view, target.id)

      view
      |> element(~s(button[data-role="rail-row-actions-hide"][data-space-id="#{target.id}"]))
      |> render_click()

      {:ok, view2, _html} = live_following_redirect(conn)

      assert has_element?(view2, row_selector(other.id))

      refute has_element?(view2, row_selector(target.id)),
             "Hidden channel's row should remain absent after remount (preference persisted)"
    end
  end

  describe "Spaces section fold" do
    # Fold is NOT hide: the header and its toggle stay; only the rows go.
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      _landing = create_channel("landing")
      channel = create_channel("collapsible")
      {:ok, view, _html} = live_following_redirect(conn)
      %{conn: conn, view: view, channel: channel}
    end

    test "expanded by default: rows render and the toggle reports aria-expanded=true",
         %{view: view, channel: channel} do
      assert has_element?(view, spaces_row_selector(channel.id))
      assert has_element?(view, spaces_toggle_selector(true))
    end

    test "collapsing removes the section's rows but KEEPS its header",
         %{view: view, channel: channel} do
      view |> element(spaces_toggle_selector(true)) |> render_click()

      refute has_element?(view, spaces_row_selector(channel.id)),
             "Collapsing a section must fold away its rows"

      # Anti-vacuity: the section and its toggle are still there.
      assert count(view, ~s(#chat-list [data-role="chat-list-spaces"])) == 1
      assert has_element?(view, spaces_toggle_selector(false))
    end

    test "expanding again restores the rows", %{view: view, channel: channel} do
      view |> element(spaces_toggle_selector(true)) |> render_click()
      view |> element(spaces_toggle_selector(false)) |> render_click()

      assert has_element?(view, spaces_row_selector(channel.id))
      assert has_element?(view, spaces_toggle_selector(true))
    end

    test "collapse state survives a remount of the LiveView",
         %{conn: conn, view: view, channel: channel} do
      view |> element(spaces_toggle_selector(true)) |> render_click()

      {:ok, view2, _html} = live_following_redirect(conn)

      assert has_element?(view2, spaces_toggle_selector(false))

      refute has_element?(view2, spaces_row_selector(channel.id)),
             "Collapse is a persisted preference, so a fresh mount must come back collapsed"
    end
  end
end
