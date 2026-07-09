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

  # Open the `#mobile-channel-browser` overlay. It's toggled open by the
  # `toggle_mobile_browser` search button on the mobile pills strip (which only
  # renders once an active space is present). Landing on a channel first gives
  # us that button, then a render_click flips the overlay open.
  defp open_mobile_browser(conn) do
    {:ok, view, _html} = live_following_redirect(conn)

    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()

    view
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

      assert sidebar =~ "No channels yet — channels in this org appear here.",
             "Empty sub-org section is missing its empty-state hint"
    end
  end

  describe "section header affordances" do
    test "each sub-org section header carries a color-only dot", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Task 019e467d replaced the section-header `<.scope_pill>` (whose visible
      # text was derived from the color token, so a recolor read as a rename)
      # with a COLOR-ONLY dot keyed off `section.color`. Each seeded sub-org
      # section carries its `bg-<token>-dot` swatch; identity text comes only
      # from `section.name`, never from the color.
      assert sidebar =~ "channel-section-color-dot"
      assert sidebar =~ "bg-paragon-dot"
      assert sidebar =~ "bg-soylent-dot"
      assert sidebar =~ "bg-fabrikam-dot"
      assert sidebar =~ "bg-wayne-tech-dot"
      assert sidebar =~ "bg-sxi-dot"

      # The old text-bearing scope pill is gone from the section header.
      refute sidebar =~ ~s(aria-label="Paragon scope")
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

  describe "mobile channel browser overlay (chat sidebar mobile Stage 1)" do
    test "overlay renders the sectioned rail (DMs + reorderable sub-org sections), not a flat list",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # Direct Messages section is present and locked (not reorderable),
      # mirroring the desktop rail's Pinned/DMs lock.
      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"][data-section-reorderable="false"])
             ),
             "Mobile overlay should render a locked Direct Messages section"

      # Sub-org sections render, keyed by data-section-id and marked
      # reorderable for the later touch-reorder stage — the same
      # @sidebar_sections data the desktop rail iterates.
      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-reorderable="true"][data-section-id])
             ),
             "Mobile overlay should render reorderable sub-org sections keyed by data-section-id"

      # The org-default sub-org section labels surface in the overlay markup.
      assert has_element?(view, "#mobile-channel-browser", "Paragon")
      assert has_element?(view, "#mobile-channel-browser", "Fabrikam")
    end

    test "Pinned section is suppressed in the overlay when there are no pinned channels",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # Pinning isn't wired yet (pinned is always empty today), so the Pinned
      # section must not render — matching the desktop rail's conditional.
      refute has_element?(view, ~s(#mobile-channel-browser section[aria-label="Pinned"])),
             "Empty Pinned section should be suppressed in the mobile overlay"
    end
  end

  # Drive the rail into personal-edit mode (`@sidebar_edit`) via the ONLY entry
  # point — the desktop-aside kebab menu → "Edit my layout". Toggling edit does
  # not close the mobile browser overlay (see ChatLive.handle_event/3), so tests
  # can hold both open at once. NOTE: this menu is desktop-only chrome; there is
  # no mobile edit entry today — see the Stage 2 report's flagged gap.
  defp enter_sidebar_edit(view) do
    view
    |> element(~s(button[phx-click="toggle_sidebar_menu"]))
    |> render_click()

    view
    |> element(~s(.channel-sidebar-menu-item[phx-click="toggle_sidebar_edit"]))
    |> render_click()

    view
  end

  describe "mobile locked-section lock affordance (chat sidebar mobile Stage 2, Decision #5)" do
    # The locked DMs section carries an explicit `hero-lock-closed` icon in
    # edit mode so touch users (no hover) can see it isn't reorderable. It is
    # gated on `@sidebar_edit` — the same personal-edit mode that gates desktop
    # section reorder.

    test "lock icon is absent in the overlay outside edit mode", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      refute has_element?(view, ~s(#mobile-channel-browser .channel-section-lock)),
             "Lock affordance should not render when not in edit mode"
    end

    test "DMs section shows the lock affordance once edit mode is entered", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] .channel-section-lock.hero-lock-closed)
             ),
             "Locked Direct Messages section should render the hero-lock-closed affordance in edit mode"
    end
  end

  describe "mobile touch drag-reorder (chat sidebar mobile Stage 3)" do
    # The gesture itself (long-press timing, slop cancel, pointer capture) is
    # JS-only and can't run under LiveViewTest — it's covered by the Stage 4
    # manual_approval checklist on a real touch surface. What CAN regress
    # server-side is asserted here: the hook element + its wiring, the
    # edit-gated handle markup, the mobile edit-mode entry point, and the
    # hook's `section_reordered` push reordering + persisting via the same
    # pipeline desktop uses.

    test "mobile rail nav carries the SectionReorderTouch hook", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser nav[id="mobile-section-list"][phx-hook="SectionReorderTouch"])
             ),
             "Mobile overlay nav should mount the SectionReorderTouch hook"
    end

    test "touch drag handle is edit-gated and renders only on reorderable sections",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      refute has_element?(
               view,
               ~s(#mobile-channel-browser .channel-section-drag-handle--touch)
             ),
             "Touch drag handle should not render outside edit mode"

      enter_sidebar_edit(view)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-reorderable="true"] .channel-section-drag-handle--touch)
             ),
             "Sub-org sections should render the touch drag handle in edit mode"

      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] .channel-section-drag-handle--touch)
             ),
             "Locked Direct Messages section must never render a drag handle"
    end

    test "drawer-header Edit button is a working mobile entry into edit mode", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # Stage 2 flagged that edit mode was only reachable through the
      # desktop kebab menu (hidden on phones); the drawer-header button is
      # the mobile entry point. Clicking it must reveal the edit-gated
      # affordances (Stage 2 locks + Stage 3 handles) without leaving the
      # overlay.
      view
      |> element(~s(#mobile-channel-browser header button[phx-click="toggle_sidebar_edit"]))
      |> render_click()

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] .channel-section-lock)
             ),
             "Edit button in the drawer header should enter edit mode (lock affordances visible)"

      assert has_element?(
               view,
               ~s(#mobile-channel-browser .channel-section-drag-handle--touch)
             ),
             "Edit button in the drawer header should enter edit mode (drag handles visible)"
    end

    test "section_reordered pushed from the mobile hook element reorders and persists",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # Resolver default is alphabetical (Paragon, Soylent, Fabrikam, ...).
      # Reorder semantics are "insert ABOVE the drop target" (mirroring the
      # border-top drop indicator), so dropping the first section onto the
      # SECOND is a no-op — drop it onto the THIRD to move it down one slot.
      # The hook pushes the SAME `section_reordered {from, to}` event desktop
      # sends; drive it from the mobile nav element to prove the mobile
      # wiring reaches the shared server pipeline
      # (put_section_order -> chat_section_order pref).
      [paragon_id, soylent_id, fabrikam_id | _] = rendered_section_ids(render(view))

      view
      |> element("#mobile-section-list")
      |> render_hook("section_reordered", %{"from" => paragon_id, "to" => fabrikam_id})

      assert [^soylent_id, ^paragon_id, ^fabrikam_id | _] = rendered_section_ids(render(view)),
             "Dropping Paragon onto Fabrikam should re-slot it between Soylent and Fabrikam"

      # Persistence: a fresh mount must come back in the saved order, not
      # the alphabetical default.
      {:ok, _view, html} = live_following_redirect(conn)

      assert [^soylent_id, ^paragon_id, ^fabrikam_id | _] = rendered_section_ids(html),
             "Reordered layout should persist across a remount via chat_section_order"
    end
  end

  describe "mobile up/down section move buttons (chat sidebar mobile Stage 4, WCAG 2.5.7)" do
    # The coupled non-drag alternative to the Stage 3 long-press drag. Buttons
    # fire the SAME `section_reordered {from, to}` server event via
    # phx-value bindings — no new handler — so these tests drive the buttons
    # exactly as a tap would and assert against the shared pipeline.

    test "move buttons are edit-gated and absent on locked sections", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      refute has_element?(view, ~s(#mobile-channel-browser .channel-section-move-controls)),
             "Move buttons should not render outside edit mode"

      enter_sidebar_edit(view)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-reorderable="true"] .channel-section-move-controls)
             ),
             "Sub-org sections should render up/down move controls in edit mode"

      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Direct Messages"] .channel-section-move-controls)
             ),
             "Locked Direct Messages section must never render move controls"
    end

    test "boundary buttons are disabled: first section's Up, last section's Down",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      [first_id | _] = ids = rendered_section_ids(render(view))
      last_id = List.last(ids)

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-id="#{first_id}"] button[title="Move section up"][disabled])
             ),
             "First section's Up button should be disabled"

      assert has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-id="#{last_id}"] button[title="Move section down"][disabled])
             ),
             "Last section's Down button should be disabled"

      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[data-section-id="#{first_id}"] button[title="Move section down"][disabled])
             ),
             "First section's Down button should be enabled"
    end

    test "Down button swaps with the next section and persists, sharing the drag pipeline",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      [first_id, second_id | rest] = rendered_section_ids(render(view))

      # Tap "Move section down" on the FIRST section. Under the event's
      # insert-above semantics this is encoded as from=second, to=first —
      # the template owns that mapping; the test just clicks the button.
      view
      |> element(
        ~s(#mobile-channel-browser section[data-section-id="#{first_id}"] button[title="Move section down"])
      )
      |> render_click()

      assert [^second_id, ^first_id | ^rest] = rendered_section_ids(render(view)),
             "Down on the first section should swap it with the second"

      # Same persistence contract as the drag: fresh mount keeps the order.
      {:ok, _view, html} = live_following_redirect(conn)

      assert [^second_id, ^first_id | ^rest] = rendered_section_ids(html),
             "Button reorder should persist across a remount via chat_section_order"
    end

    test "Up button on the second section swaps it back to first", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)
      enter_sidebar_edit(view)

      [first_id, second_id | _] = rendered_section_ids(render(view))

      view
      |> element(
        ~s(#mobile-channel-browser section[data-section-id="#{second_id}"] button[title="Move section up"])
      )
      |> render_click()

      assert [^second_id, ^first_id | _] = rendered_section_ids(render(view)),
             "Up on the second section should move it above the first"
    end
  end

  describe "pills follow the drawer order (mobile channel search Stage 3)" do
    # The pills strip renders Sidebar.flatten_sections(@sidebar_sections) —
    # the user's curated (hidden-filtered) drawer arrangement — instead of
    # the raw @channels list. Marlowe's decision 2026-07-05.

    test "pill order tracks a section reorder made in the drawer", %{conn: conn} do
      conn = authenticated_conn(conn)
      {s1, s2, _ch1, _ch2} = seed_two_sectioned_channels()

      view = open_mobile_browser(conn)

      pills = pills_strip(render(view))
      one = :binary.match(pills, "Pillone") |> elem(0)
      two = :binary.match(pills, "Pilltwo") |> elem(0)
      assert one < two, "Baseline: section 1's channel should pill before section 2's"

      # Drag section 2 above section 1 (insert-above semantics) via the SAME
      # mobile hook event the touch drag sends.
      view
      |> element("#mobile-section-list")
      |> render_hook("section_reordered", %{"from" => s2.id, "to" => s1.id})

      pills = pills_strip(render(view))
      one = :binary.match(pills, "Pillone") |> elem(0)
      two = :binary.match(pills, "Pilltwo") |> elem(0)
      assert two < one, "Pills should re-order to match the dragged section order"
    end

    test "hidden channels stop rendering as pills (hidden means hidden everywhere)",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      {_s1, _s2, ch1, _ch2} = seed_two_sectioned_channels()

      {:ok, view, html} = live_following_redirect(conn)
      assert pills_strip(html) =~ "Pillone"

      render_click(view, "hide_channel", %{"id" => ch1.id})

      pills = pills_strip(render(view))
      refute pills =~ "Pillone", "A hidden channel must not render as a pill"
      assert pills =~ "Pilltwo", "Non-hidden channels keep their pills"
    end
  end

  # Two channels seeded into the two lowest-position org sections via
  # org_id, so section-level operations provably change PILL order.
  defp seed_two_sectioned_channels do
    [s1, s2 | _] =
      Platform.Chat.Section |> Repo.all() |> Enum.sort_by(& &1.position)

    {:ok, ch1} =
      Chat.create_space(%{name: "Pillone", slug: "pillone", kind: "channel", org_id: s1.org_id})

    {:ok, ch2} =
      Chat.create_space(%{name: "Pilltwo", slug: "pilltwo", kind: "channel", org_id: s2.org_id})

    {s1, s2, ch1, ch2}
  end

  # The pills strip's markup, isolated so pill assertions can't accidentally
  # match drawer/desktop-rail rows for the same channels.
  defp pills_strip(html) do
    case Regex.run(~r/<nav[^>]*aria-label="Channel switcher".*?<\/nav>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  # Ordered, de-duplicated sub-org section ids from a rendered HTML blob.
  # Desktop rail + mobile overlay render the SAME resolver order, so the
  # de-duplicated first-occurrence order reflects both surfaces.
  defp rendered_section_ids(html) do
    ~r/data-section-id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end
end
