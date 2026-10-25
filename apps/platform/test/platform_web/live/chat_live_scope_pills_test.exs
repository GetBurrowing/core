defmodule PlatformWeb.ChatLiveScopePillsTest do
  @moduledoc """
  Render + event tests for the chat-rail and chat-header scope-pills
  (chat plan v2 Stage 4).

  Coverage:
    * Active channel row does NOT render a per-channel `.channel-row-scope-pill`
      (removed in task 019e464d), while the section-header scope-pill is retained.
    * Chat header renders a prominent `<.scope_pill>` (size variant via
      `.chat-header-scope-pill` wrapper) when a channel is active.
    * Clicking the header pill pushes a `scope_filter` event with the
      channel's scope and the pill reads as the active filter
      (`aria-pressed="true"`); a second click clears it.
    * Header pill not rendered when no channel is active (e.g. on a DM /
      group conversation surface).

  Burrow redesign 22 stage 2 deleted the desktop channel rail: its sub-org
  section headers and colour dots, and the rail narrowing that
  `scope_filter` used to drive. The section-dot test is deleted; the row test
  is retargeted to the Chat list; the filter tests now read the header
  pill's own pressed state, which is what `@scope_filter` still drives.

  Burrow redesign 22 stage 4 deleted the desktop header pill (coverage row
  49: the header is title + people subtitle). The desktop filter is the
  details panel's Scope page switch, the same `scope_filter` event and
  `phx-value-scope` payload; these tests read that switch's `aria-checked`.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    init_test_session(conn, current_user_id: user.id)
  end

  defp insert_chat_user do
    Repo.insert!(%User{
      email: "scope_pills_test@example.com",
      name: "Scope Pills Test User",
      oidc_sub: "oidc-scope-pills-test",
      avatar_url: nil
    })
  end

  # Post-019fa0ac the chat-header scope-pill resolves its scope from the
  # space's `org_id` (mirroring the sidebar rail), NOT the channel slug — so a
  # channel must actually belong to the org whose pill we expect to render.
  # The seeded root orgs (priv/repo/migrations/20260519143620_seed_root_orgs.exs)
  # use slugs acme/initech/vandelay_ind/globex/hooli — the same tokens these tests
  # pass in — so resolve the matching org and stamp its id. (Sidebar *section*
  # bucketing is still slug-based via `channel_scope/1`, so the
  # `channel-section-label` assertions are unaffected by the added org_id.)
  defp create_channel(slug) do
    org = Platform.Tenancy.get_org_by_slug(slug)

    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: org && org.id
      })

    ch
  end

  # Mirror of the helper in chat_live_section_render_test.exs — `GET /chat`
  # redirects to the first channel as soon as one exists. Tests in this
  # module always land on a real channel slug so the active-channel and
  # chat-header surfaces both render.
  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  defp chat_list(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat-list-scroller")
    |> LazyHTML.to_html()
  end

  @header_pill ~s(#details-panel button[data-role="details-scope-switch"][phx-click="scope_filter"][phx-value-scope="initech"])

  # Opens the details panel's Scope page, where the desktop filter lives.
  defp open_scope(view) do
    render_click(view, "details_open", %{"page" => "scope"})
    view
  end

  defp header_pill_pressed(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@header_pill)
    |> LazyHTML.attribute("aria-checked")
  end

  describe "per-channel-row scope-pill removal (task 019e464d)" do
    # Before task 019e464d the active channel row rendered a
    # `.channel-row-scope-pill` "you are here" provenance marker next to the
    # channel name. That per-channel pill was redundant with the section
    # header's own org-scope cue and has been removed. These tests lock in the
    # removal AND prove the section header keeps a grouping cue.
    #
    # Task 019e467d then replaced the section-header *scope_pill* (whose visible
    # TEXT was derived from the color token, so a recolor looked like a rename)
    # with a color-ONLY dot. The grouping cue is retained as the dot; the text
    # identity is now exclusively `section.name`.

    test "active channel row does NOT render a per-channel scope-pill", %{conn: conn} do
      conn = authenticated_conn(conn)
      # Slug "hooli" is classified into the Hooli sub-org bucket and
      # becomes the active space — the surface that used to grow a pill.
      create_channel("hooli")

      {:ok, _view, html} = live_at(conn, ~p"/chat/hooli")
      list = chat_list(html)

      # Positive control: the active row is in the list being refuted over.
      assert list =~ ~s(aria-current="page")

      refute list =~ "channel-row-scope-pill",
             "Active channel row should no longer render the per-channel scope-pill wrapper"

      refute list =~ "scope-pill"
    end

    # "the section-header color dot is retained" was deleted: Burrow redesign
    # 22 stage 2 deleted the desktop channel rail and its section headers.
  end

  describe "desktop scope filter (the details panel's Scope page)" do
    test "the header has no pill; the panel's Scope page carries the clickable filter",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("initech")

      {:ok, view, html} = live_at(conn, ~p"/chat/initech")

      refute html =~ "chat-header-scope-pill"

      html = view |> open_scope() |> render()
      assert has_element?(view, @header_pill)
      assert html =~ ~s(phx-click="scope_filter")
    end

    test "header pill click pushes scope_filter and the pill reads as the active filter",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("acme")
      create_channel("hooli")
      create_channel("initech")

      {:ok, view, _html} = live_at(conn, ~p"/chat/initech")
      open_scope(view)

      assert header_pill_pressed(view) == ["false"]

      # Click the chat-header scope-pill — it pushes `scope_filter` with the
      # channel's scope ("initech"), and `@scope_filter` marks the pill
      # active.
      view |> element(@header_pill) |> render_click()

      assert header_pill_pressed(view) == ["true"]
    end

    test "header pill is not rendered when no channel is active (DM surface)", %{conn: conn} do
      conn = authenticated_conn(conn)
      # No channels at all — `/chat` lands on the empty state with
      # @active_space == nil, so neither the desktop header nor the
      # header-pill wrapper should render.
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "chat-header-scope-pill",
             "Chat-header scope-pill should NOT render when @active_space is nil"
    end
  end

  describe "mobile chat-header compact scope-pill (chat sidebar mobile Stage 2)" do
    # The compact mobile header pill was deleted in task 01a1557a-8a6d stage
    # 3. The phone reaches the same `scope_filter` event, with the same
    # payload, through the space sheet's Scope switch.
    test "the phone header has no compact pill; the sheet's Scope switch fires scope_filter",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("initech")

      {:ok, view, html} = live_at(conn, ~p"/chat/initech")

      refute html =~ "chat-header-scope-pill-mobile"
      refute html =~ "chat-header-scope-pill"

      view |> element(~s(button[data-role="space-title"])) |> render_click()
      # The title opens on the All segment; the Scope row is on Space.
      view |> element(~s(#space-sheet button[data-seg="space"])) |> render_click()
      view |> element(~s(#space-sheet button[data-role="space-sheet-scope"])) |> render_click()

      switch = ~s(#space-sheet button[data-role="space-sheet-scope-switch"])
      assert view |> element(switch) |> render() =~ ~s(phx-value-scope="initech")

      view |> element(switch) |> render_click()
      assert render(view) =~ ~s(aria-checked="true")
    end

    test "mobile header pill is suppressed on a DM/group surface (no org-scope)",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      # No channels — `/chat` lands with @active_space == nil, so the whole
      # header (and thus the mobile pill) is suppressed. `space_scope_atom/1`
      # also returns nil for DMs/groups, so the pill never renders there.
      {:ok, _view, html} = live(conn, ~p"/chat")

      refute html =~ "chat-header-scope-pill-mobile",
             "Mobile chat-header scope-pill should NOT render without an active channel"
    end
  end

  describe "scope_filter event toggle semantics" do
    test "clicking the same scope twice clears the filter", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("hooli")
      create_channel("initech")

      {:ok, view, _} = live_at(conn, ~p"/chat/initech")
      open_scope(view)

      # First click → the Initech filter is on.
      view |> element(@header_pill) |> render_click()
      assert header_pill_pressed(view) == ["true"], "After first click, the filter should be on"

      # Second click on the same pill → clears the filter.
      view |> element(@header_pill) |> render_click()

      assert header_pill_pressed(view) == ["false"],
             "After second click on the same pill, the filter should be cleared"
    end
  end
end
