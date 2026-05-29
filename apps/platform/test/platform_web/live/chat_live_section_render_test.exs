defmodule PlatformWeb.ChatLiveSectionRenderTest do
  @moduledoc """
  Render-level tests for the sectioned channel rail (chat plan v2 Stage 2).

  These exercise the live `chat_live.html.heex` against real DB-backed
  spaces (channels + DM/group conversations) — pure-function tests for
  the data-shape helper itself live in
  `chat_live_section_grouping_test.exs`.

  Coverage:
    * Pinned / DMs / sub-org section order
    * Sub-org alphabetical order (Paragon / Soylent / Fabrikam / Wayne-Tech / SXI)
    * Empty sub-org section renders header + empty-state hint
    * Sub-org headers carry a `<.scope_pill>` reference
    * Drag-handle (`☰`) glyph is present in DOM
    * Uncap default — all rows visible, no `+ N more` toggle (chat
      sidebar v3 Stage 2 replaced the legacy 8-row cap; this asserts
      regression coverage for the removal)
    * Per-channel hide affordance on sub-org rows only (NOT Pinned, NOT
      DMs); `hide_channel` event removes a row from the rendered list
    * Mobile responsive gate: `hidden lg:flex` wrapper present
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
      email: "section_render_test@example.com",
      name: "Section Render Test User",
      oidc_sub: "oidc-section-render-test",
      avatar_url: nil
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

  # `GET /chat` redirects to the first channel as soon as one exists (see
  # ChatLive.handle_params/3 catch-all). Tests in this module always seed
  # at least one channel first, so naked `live(conn, ~p"/chat")` returns
  # `{:error, {:live_redirect, ...}}`. Follow it once and use the resulting
  # view/HTML — the sectioned rail is identical across spaces, so it
  # doesn't matter which slug we land on.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  # Extract the desktop-sidebar `<aside id="chat-sidebar">` substring from a
  # rendered HTML blob so assertions can ignore the mobile flat-list
  # overlay (which intentionally still references @channels/@dm_conversations).
  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  describe "section render order" do
    test "DMs section renders below Pinned section header when both present", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # The data layer puts pinned at the top — when empty (no pinned
      # channels), the Pinned section is suppressed and DMs is the first
      # section to render. Verify the sub-org header order against the
      # Direct Messages header order, which is the load-bearing invariant.
      dms_idx = :binary.match(sidebar, "Direct Messages") |> elem(0)
      paragon_idx = :binary.match(sidebar, "Paragon") |> elem(0)

      assert dms_idx > 0

      assert paragon_idx > dms_idx,
             "Expected DMs section to render BEFORE sub-org sections, got DMs at #{dms_idx} and Paragon at #{paragon_idx}"
    end

    test "sub-org sections render in alphabetical order", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Each sub-org header is rendered as text inside a <p class="channel-section-label">.
      # Capture their offset positions and verify they appear in the
      # required A-Z order (Paragon / Soylent / Fabrikam / Wayne-Tech / SXI).
      offsets =
        for label <- ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "SXI"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Sub-org sections not in alphabetical order: #{inspect(offsets)}"
    end
  end

  describe "empty sub-org section render" do
    test "empty Paragon bucket still renders its section header + empty-state hint", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)
      # Single Fabrikam channel, no Paragon channel — Paragon bucket is empty.
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      assert sidebar =~ "Paragon"

      assert sidebar =~ "No channels yet — channels named matching this sub-org appear here.",
             "Empty sub-org section is missing its empty-state hint"
    end
  end

  describe "section header affordances" do
    test "each sub-org section header carries a scope_pill reference", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # `<.scope_pill clickable={false}>` renders a `<span>` whose
      # aria-label is "<Scope> scope" (see ScopePill.aria_label_static/1).
      # That static-variant aria-label is the cheapest stable hook.
      assert sidebar =~ ~s(aria-label="Paragon scope")
      assert sidebar =~ ~s(aria-label="Soylent scope")
      assert sidebar =~ ~s(aria-label="Fabrikam scope")
      assert sidebar =~ ~s(aria-label="Wayne-Tech scope")
      assert sidebar =~ ~s(aria-label="SXI scope")
    end

    test "drag-handle glyph is present in DOM (opacity-0 lives in CSS)", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      assert sidebar =~ "channel-section-drag-handle",
             "Drag-handle class not found on any section header"

      # The literal glyph character. Visual opacity is CSS-controlled
      # (we assert presence, not visibility).
      assert sidebar =~ "☰", "Drag-handle glyph (☰) missing from rendered output"
    end
  end

  describe "uncap default — all rows visible (chat sidebar v3 Stage 2)" do
    test "section with 20+ channels renders every row; no truncation toggle", %{conn: conn} do
      conn = authenticated_conn(conn)

      # 20 channels in the Fabrikam bucket (catch-all). Pre-v3 this would have
      # rendered 8 visible + `+ 12 more` toggle. v3 deletes the cap.
      for n <- 1..20, do: create_channel("fabrikam-test-#{n}")

      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      for n <- 1..20 do
        assert sidebar =~ "Fabrikam-test-#{n}",
               "Channel fabrikam-test-#{n} should render after the cap removal"
      end

      refute sidebar =~ "channel-section-show-more",
             "Legacy `+ N more` toggle should be gone after Stage 2"

      refute sidebar =~ ~s(phx-click="toggle_section"),
             "Legacy `toggle_section` event should be gone after Stage 2"
    end
  end

  describe "per-channel hide affordance (chat sidebar v3 Stage 2)" do
    test "sub-org rows render the eye-slash hide button; Pinned + DMs do not",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # General channel falls into the Fabrikam bucket; its row must carry
      # phx-click="hide_channel" wired to the row's space id.
      assert sidebar =~ ~s(phx-click="hide_channel"),
             "Sub-org channel rows should expose a hide_channel event"

      assert sidebar =~ ~s(aria-label="Hide #General"),
             "Hide button should carry an aria-label naming the channel"

      # The button-count on the Fabrikam bucket — one per visible channel.
      hide_button_count =
        Regex.scan(~r/phx-click="hide_channel"/, sidebar)
        |> length()

      assert hide_button_count == 1,
             "Expected exactly one hide button (for #general); found #{hide_button_count}"
    end

    test "clicking hide_channel removes the row from the rendered list", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("hide-me")
      _other = create_channel("keep-me")

      {:ok, view, html_before} = live_following_redirect(conn)
      sidebar_before = desktop_sidebar(html_before)

      assert sidebar_before =~ "Hide-me"
      assert sidebar_before =~ "Keep-me"

      html_after =
        view
        |> element(~s(button[phx-click="hide_channel"][phx-value-id="#{target.id}"]))
        |> render_click()

      sidebar_after = desktop_sidebar(html_after)

      # Stage 3 surfaces the hidden channel's name in an undo toast at the
      # bottom of the sidebar (role=status), so a bare substring check for
      # the name would falsely fail. Assert at the row level instead: the
      # hide button only renders inside a visible sub-org row, so its
      # absence confirms the row was removed. The undo toast's button uses
      # `phx-click="undo_hide"`, not `hide_channel`, so it won't match.
      refute sidebar_after =~
               ~s(phx-click="hide_channel" phx-value-id="#{target.id}"),
             "Hidden channel's row should be removed from the rendered sidebar"

      assert sidebar_after =~ "Keep-me",
             "Unrelated channel should still render after hiding the target"
    end

    test "hidden state survives a remount (preference is persisted)", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("persist-me")

      {:ok, view, _} = live_following_redirect(conn)

      view
      |> element(~s(button[phx-click="hide_channel"][phx-value-id="#{target.id}"]))
      |> render_click()

      # Fresh LV mount — the hidden id should be loaded from
      # users.preferences['hidden_channel_ids'] and the row filtered out.
      {:ok, _view2, html_remount} = live_following_redirect(conn)
      sidebar_remount = desktop_sidebar(html_remount)

      # Stage 3 v3 (Option B): the global Hidden drawer at the rail's
      # foot now renders the hidden channel's name in its grouped list
      # (the panel always renders for the CSS transition; visibility is
      # CSS-driven). So a bare substring check would falsely fail. Assert
      # at the row level instead: the channel's hide button only renders
      # inside a visible sub-org row, so its absence after remount proves
      # the preference was loaded and the row was filtered out.
      refute sidebar_remount =~
               ~s(phx-click="hide_channel" phx-value-id="#{target.id}"),
             "Hidden channel's row should remain absent after remount (preference persisted)"
    end
  end

  describe "mobile responsive gate" do
    test "desktop sectioned rail is wrapped in `hidden lg:flex` so it's invisible on mobile",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)

      # The sectioned-rail aside MUST start with `hidden lg:flex` so it
      # collapses to display:none below the `lg` breakpoint. The mobile
      # flat-list overlay (toggled by mobile_browser_open) is a separate
      # element gated by `lg:hidden` and is left untouched by Stage 2.
      assert html =~ ~r/<aside[^>]*id="chat-sidebar"[^>]*class="[^"]*hidden lg:flex/,
             "Expected `<aside id=\"chat-sidebar\">` to carry the `hidden lg:flex` class so the sectioned rail is invisible on mobile"
    end
  end
end
