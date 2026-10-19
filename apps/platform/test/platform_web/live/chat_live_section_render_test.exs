defmodule PlatformWeb.ChatLiveSectionRenderTest do
  @moduledoc """
  Render-level tests for the sectioned channel rail (chat plan v2 Stage 2).

  These exercise the live `chat_live.html.heex` against real DB-backed
  spaces (channels + DM/group conversations) — pure-function tests for
  the data-shape helper itself live in
  `chat_live_section_grouping_test.exs`.

  Coverage:
    * Pinned / DMs / sub-org section order
    * Sub-org alphabetical order (Acme / Globex / Hooli / Initech / Vandelay-Ind)
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
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp authenticated_conn(conn) do
    user = insert_chat_user()
    init_test_session(conn, current_user_id: user.id)
  end

  defp user_id(conn), do: Plug.Conn.get_session(conn, :current_user_id)

  # The row's overflow menu (task 019ff8ba stage 1). It renders at the template
  # root, outside `<aside id="chat-sidebar">`, so `desktop_sidebar/1` never
  # contains it and every row action now costs an open step.
  #
  # `LazyHTML.query/2`, not `filter/2`: filter keeps ROOT nodes matching the
  # selector, and the roots of a rendered page are `<html>` and friends.
  defp open_row_menu(view, space_id) do
    view
    |> element(~s(button[data-role="row-actions-trigger"][data-space-id="#{space_id}"]))
    |> render_click()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="row-actions-dialog"]))
    |> LazyHTML.to_html()
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
      hooli_idx = :binary.match(sidebar, "Hooli") |> elem(0)

      assert dms_idx > 0

      assert hooli_idx > dms_idx,
             "Expected DMs section to render BEFORE sub-org sections, got DMs at #{dms_idx} and Hooli at #{hooli_idx}"
    end

    test "sub-org sections render in alphabetical order", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Each sub-org header is rendered as text inside a <p class="channel-section-label">.
      # Capture their offset positions and verify they appear in the
      # required A-Z order (Acme / Globex / Hooli / Initech / Vandelay-Ind).
      offsets =
        for label <- ["Acme", "Globex", "Hooli", "Initech", "Vandelay-Ind"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Sub-org sections not in alphabetical order: #{inspect(offsets)}"
    end
  end

  describe "empty sub-org section render" do
    test "empty Hooli bucket still renders its section header + empty-state hint", %{
      conn: conn
    } do
      conn = authenticated_conn(conn)
      # Single Acme channel, no Hooli channel — Hooli bucket is empty.
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      assert sidebar =~ "Hooli"

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
      assert sidebar =~ ~r/channel-section-color-dot--scope"\s+data-scope="hooli"/
      assert sidebar =~ ~r/channel-section-color-dot--scope"\s+data-scope="initech"/
      assert sidebar =~ ~r/channel-section-color-dot--scope"\s+data-scope="vandelay_ind"/
      # The root org has no compiled dot class (task 01a116de stage 3): its
      # dot reads the org row's colour through `data-scope`.
      assert sidebar =~
               ~r/class="channel-section-color-dot channel-section-color-dot--unassigned"\s+data-scope="acme"/

      assert sidebar =~ ~r/channel-section-color-dot--scope"\s+data-scope="globex"/

      # The old text-bearing scope pill is gone from the section header.
      refute sidebar =~ ~s(aria-label="Hooli scope")
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

      # 20 channels in the Acme bucket (catch-all). Pre-v3 this would have
      # rendered 8 visible + `+ 12 more` toggle. v3 deletes the cap.
      for n <- 1..20, do: create_channel("acme-test-#{n}")

      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      for n <- 1..20 do
        assert sidebar =~ "Acme-test-#{n}",
               "Channel acme-test-#{n} should render after the cap removal"
      end

      refute sidebar =~ "channel-section-show-more",
             "Legacy `+ N more` toggle should be gone after Stage 2"

      refute sidebar =~ ~s(phx-click="toggle_section"),
             "Legacy `toggle_section` event should be gone after Stage 2"
    end
  end

  # Task 019ff8ba stage 1 moved hide off the row and into the row's overflow
  # menu, which renders at the TEMPLATE ROOT — outside `<aside id="chat-sidebar">`
  # and therefore outside every `desktop_sidebar/1` slice below.
  #
  # That breaks two of these tests in a way worth stating rather than patching
  # quietly. Both used to prove a row had been REMOVED by refuting
  # `phx-click="hide_channel" phx-value-id=<id>` inside the sidebar slice.
  # After the move that refutation is true of every row, hidden or not, so both
  # tests would still pass while proving nothing at all. They are re-anchored on
  # a locator that survives on a VISIBLE row: the row wrapper's own
  # `data-space-id` inside the client section.
  describe "per-channel hide affordance (chat sidebar v3 Stage 2)" do
    test "the hide action is in a sub-org row's menu, and not in a pinned row's",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      channel = create_channel("general")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # One trigger, one row. Counted rather than merely asserted present, so
      # a build that renders a trigger per row AND leaves the old buttons
      # behind does not pass.
      trigger_count = Regex.scan(~r/data-role="row-actions-trigger"/, sidebar) |> length()

      assert trigger_count == 1,
             "Expected exactly one row-actions trigger (for #general); found #{trigger_count}"

      refute sidebar =~ ~s(phx-click="hide_channel"),
             "The eye-slash hide button is still on the row: Option C takes it off"

      menu = open_row_menu(view, channel.id)

      assert menu =~ ~s(phx-click="hide_channel"),
             "The sub-org row's menu does not carry the hide action"

      assert menu =~ ~s(phx-value-id="#{channel.id}"),
             "The menu's hide action is not wired to this row's space id"

      # The scope half, which is the reason this test names Pinned and DMs.
      # `hide_channel` writes a preference the Hidden drawer reverses by
      # CHANNEL, so a pinned row (and a DM) must not offer it.
      {:ok, _} = Sidebar.set_space_pinned(user_id(conn), channel.id, true)
      {:ok, pinned_view, _html} = live_following_redirect(conn)

      refute open_row_menu(pinned_view, channel.id) =~ ~s(phx-click="hide_channel"),
             "A Pinned-block row's menu offers hide, which has no way back for that row"
    end

    test "hiding from the menu removes the row from the rendered list", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("hide-me")
      _other = create_channel("keep-me")

      {:ok, view, html_before} = live_following_redirect(conn)
      sidebar_before = desktop_sidebar(html_before)

      assert sidebar_before =~ ~s(data-space-id="#{target.id}"),
             "The target's row is missing before the hide"

      assert sidebar_before =~ "Keep-me"

      _ = open_row_menu(view, target.id)

      html_after =
        view
        |> element(~s(button[data-role="rail-row-actions-hide"][data-space-id="#{target.id}"]))
        |> render_click()

      sidebar_after = desktop_sidebar(html_after)

      # Anchored on the ROW's own `data-space-id`, not on the hide button.
      # The button moved out of this slice entirely, so refuting it here would
      # be true whether or not the row went anywhere.
      refute sidebar_after =~ ~s(data-space-id="#{target.id}"),
             "Hidden channel's row should be removed from the rendered sidebar"

      assert sidebar_after =~ "Keep-me",
             "Unrelated channel should still render after hiding the target"
    end

    test "hidden state survives a remount (preference is persisted)", %{conn: conn} do
      conn = authenticated_conn(conn)
      target = create_channel("persist-me")

      {:ok, view, _} = live_following_redirect(conn)

      _ = open_row_menu(view, target.id)

      view
      |> element(~s(button[data-role="rail-row-actions-hide"][data-space-id="#{target.id}"]))
      |> render_click()

      # Fresh LV mount — the hidden id should be loaded from
      # users.preferences['hidden_channel_ids'] and the row filtered out.
      {:ok, _view2, html_remount} = live_following_redirect(conn)
      sidebar_remount = desktop_sidebar(html_remount)

      # Same re-anchor as above, and for the same reason. The rail's Hidden
      # drawer names the channel in its own list, so a bare name check would
      # falsely fail; the row wrapper's `data-space-id` is what distinguishes
      # a visible row from a listed-as-hidden one.
      refute sidebar_remount =~ ~s(data-space-id="#{target.id}"),
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
      assert has_element?(view, "#mobile-channel-browser", "Hooli")
      assert has_element?(view, "#mobile-channel-browser", "Acme")
    end

    test "Pinned section is suppressed in the overlay when there are no pinned channels",
         %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      view = open_mobile_browser(conn)

      # This user has pinned nothing, so the section must not render, matching
      # the desktop rail's conditional. The old comment here said pinning
      # "isn't wired yet"; it has been wired since stage 1 of 019fd80f. The
      # test still holds because this fixture pins nothing, not because the
      # feature is absent.
      #
      # The selector tracks the section's accessible name, which is the bare
      # "Pinned" again now that one block holds pinned channels, DMs and task
      # conversations together (task 019feec6-73d9). A selector left pointing
      # at a name the section no longer carries would go on passing forever.
      # The POSITIVE case proving this selector fires when a pin does exist is
      # "the mobile drawer's section carries the same label" in
      # chat_live_pinned_block_test.exs.
      refute has_element?(
               view,
               ~s(#mobile-channel-browser section[aria-label="Pinned"])
             ),
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

      # Resolver default is alphabetical (Acme, Hooli, Initech, ...).
      # Reorder semantics are "insert ABOVE the drop target" (mirroring the
      # border-top drop indicator), so dropping the first section onto the
      # SECOND is a no-op — drop it onto the THIRD to move it down one slot.
      # The hook pushes the SAME `section_reordered {from, to}` event desktop
      # sends; drive it from the mobile nav element to prove the mobile
      # wiring reaches the shared server pipeline
      # (put_section_order -> chat_section_order pref).
      [hooli_id, initech_id, acme_id | _] = rendered_section_ids(render(view))

      view
      |> element("#mobile-section-list")
      |> render_hook("section_reordered", %{"from" => hooli_id, "to" => acme_id})

      assert [^initech_id, ^hooli_id, ^acme_id | _] = rendered_section_ids(render(view)),
             "Dropping Hooli onto Acme should re-slot it between Initech and Acme"

      # Persistence: a fresh mount must come back in the saved order, not
      # the alphabetical default.
      {:ok, _view, html} = live_following_redirect(conn)

      assert [^initech_id, ^hooli_id, ^acme_id | _] = rendered_section_ids(html),
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
    # the raw @channels list. Robin's decision 2026-07-05.

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

  describe "section collapse toggle (019fd80f stage 2)" do
    # The header-mounted accordion. Collapse is NOT hide: the section, its
    # header and its toggle all stay on screen — only the channel rows fold
    # away. Every assertion below is scoped to the DESKTOP rail so the mobile
    # overlay, which renders the same sections, can't satisfy one by accident.
    setup %{conn: conn} do
      conn = authenticated_conn(conn)
      {section, channel} = seed_channel_in_first_section()
      {:ok, view, _html} = live_following_redirect(conn)
      %{conn: conn, view: view, section: section, channel: channel}
    end

    test "expanded by default: rows render and the toggle reports aria-expanded=true",
         %{view: view, section: section, channel: channel} do
      sidebar = desktop_sidebar(render(view))

      assert sidebar =~ channel.name,
             "A section is expanded by default, so its channel rows must render"

      assert collapse_toggle_attr(sidebar, section.id, "aria-expanded") == "true"

      assert collapse_toggle_attr(sidebar, section.id, "aria-label") ==
               "Collapse #{Section.display_name(section)}",
             "The accessible name must name the section, not read a bare \"Collapse\""
    end

    test "collapsing removes the section's channel rows but KEEPS its header",
         %{view: view, section: section, channel: channel} do
      sidebar = desktop_sidebar(click_collapse(view, section, true))

      refute sidebar =~ channel.name,
             "Collapsing a section must fold away its channel rows"

      # Anti-vacuity. An implementation that dropped the whole section would
      # pass the refute above while shipping Hide under a new name, so pin the
      # header, its label text and the toggle itself as still present.
      assert sidebar =~ ~s(data-section-id="#{section.id}"),
             "A collapsed section must still render — collapse is not hide"

      assert sidebar =~
               ~r/<span[^>]*class="channel-section-label"[^>]*>\s*#{Section.display_name(section)}/,
             "A collapsed section must still render its header label"

      assert collapse_toggle_attr(sidebar, section.id, "aria-expanded") == "false"

      assert collapse_toggle_attr(sidebar, section.id, "aria-label") ==
               "Expand #{Section.display_name(section)}",
             "A collapsed toggle must offer to expand, and name its section"
    end

    test "expanding again restores the rows", %{view: view, section: section, channel: channel} do
      _ = click_collapse(view, section, true)
      sidebar = desktop_sidebar(click_collapse(view, section, false))

      assert sidebar =~ channel.name, "Expanding must bring the channel rows back"
      assert collapse_toggle_attr(sidebar, section.id, "aria-expanded") == "true"
    end

    test "collapse state survives a remount of the LiveView",
         %{conn: conn, view: view, section: section, channel: channel} do
      _ = click_collapse(view, section, true)

      {:ok, _view2, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      refute sidebar =~ channel.name,
             "Collapse is a persisted preference, so a fresh mount must come back collapsed"

      assert collapse_toggle_attr(sidebar, section.id, "aria-expanded") == "false"
    end
  end

  describe "collapsed section peeks unread channels (019fd80f stage 3)" do
    # The load-bearing state of the feature. A COLLAPSED section renders its
    # header plus ONLY the channels carrying unread; an EXPANDED one renders all
    # of them. Three states, not two: expanded, collapsed-with-activity, and
    # collapsed-quiet. A collapse that hides everything is a worse Hide, which is
    # exactly what these tests exist to prevent.
    #
    # The unread counts here are REAL, and that is deliberate.
    # `Chat.unread_counts_for_user/1` counts undeleted, non-thread messages
    # posted by ANOTHER participant after the reader's last_read_message_id, and
    # drops zero counts from the map entirely. On a database with no messages
    # every count is zero, so "a collapsed section still shows its unread rows"
    # would pass vacuously against an implementation that shows nothing at all.
    # The setup asserts a non-zero count BEFORE any render assertion runs.
    setup %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)

      # Sidebar list, not a bare Repo.all: the struct must carry `org_name`
      # for `Section.display_name/1` (task 01a08212).
      [section, quiet_section | _] =
        Sidebar.list_default_sections() |> Enum.sort_by(& &1.position)

      noisy = create_channel_in("Noisy", "noisy", section)
      quiet = create_channel_in("Quiet", "quiet", section)
      lonely = create_channel_in("Lonely", "lonely", quiet_section)

      seed_unread(noisy, user.id, 3)

      # Data gate. Everything below reads @unread_counts, which is this map.
      assert Chat.unread_counts_for_user(user.id) == %{noisy.id => 3},
             "The peek tests are meaningless unless the reader really has unread messages"

      # Land on `lonely`, which sits in NEITHER of the two channel rows under
      # test: opening a space clears its unread from the socket assign, so
      # landing on `noisy` would silently zero the count the whole describe
      # block depends on.
      {:ok, view, _html} = live(conn, ~p"/chat/#{lonely.slug}")

      %{
        view: view,
        section: section,
        quiet_section: quiet_section,
        noisy: noisy,
        quiet: quiet
      }
    end

    test "collapsing a section hides the channels with ZERO unread",
         %{view: view, section: section, quiet: quiet} do
      rows = view |> click_collapse(section, true) |> section_rows(section.id)

      refute {quiet.name, ""} in rows,
             "A collapsed section must fold away the channels with nothing new in them, got #{inspect(rows)}"
    end

    test "a channel in that SAME collapsed section WITH unread still renders",
         %{view: view, section: section, noisy: noisy} do
      rows = view |> click_collapse(section, true) |> section_rows(section.id)

      # The anti-vacuity assertion of the stage. The pill text rides along
      # because a peeked row whose count is not on screen would not be evidence
      # of anything: it is the count that justifies peeking the row at all.
      assert rows == [{noisy.name, "3"}],
             "A collapsed section must keep showing the channels that have new activity, got #{inspect(rows)}"
    end

    test "expanding shows everything again",
         %{view: view, section: section, noisy: noisy, quiet: quiet} do
      _ = click_collapse(view, section, true)
      rows = view |> click_collapse(section, false) |> section_rows(section.id)

      assert Enum.sort(rows) == Enum.sort([{noisy.name, "3"}, {quiet.name, ""}]),
             "Expanding must restore the quiet rows alongside the noisy one"
    end

    test "a collapsed section with no unread anywhere renders its header and no rows",
         %{view: view, quiet_section: quiet_section} do
      html = click_collapse(view, quiet_section, true)

      assert section_rows(html, quiet_section.id) == []

      # Asserting the section's WHOLE visible text rather than refuting a
      # marker: collapsed-quiet is an ordinary accordion, so the header label and
      # the drag handle are the only text it may render. No peeked rows and no
      # "Show all" line.
      assert section_text(html, quiet_section.id) == "#{Section.display_name(quiet_section)} ☰",
             "A collapsed section with nothing new is a plain header"
    end

    test ~S|"Show all (N)" is a real control that names the count and the section, and expands|,
         %{view: view, section: section, noisy: noisy, quiet: quiet} do
      html = click_collapse(view, section, true)
      button = show_all_button(html, section.id)

      assert LazyHTML.tag(button) == ["button"],
             "\"Show all\" must be a focusable control, not decorative text, got #{inspect(LazyHTML.tag(button))}"

      # N is the section's TOTAL channel count (2 here: one peeked, one hidden),
      # so the line answers "where did the rest go". The accessible name carries
      # that count and the section, because the left rule that groups the peeked
      # rows communicates nothing to a screen reader.
      assert LazyHTML.attribute(button, "aria-label") ==
               ["Show all 2 channels in #{Section.display_name(section)}"]

      assert button |> LazyHTML.text() |> String.trim() == "Show all (2)"

      rows =
        view
        |> element(~s(section[data-section-id="#{section.id}"] button.channel-ajar-show-all))
        |> render_click()
        |> section_rows(section.id)

      assert Enum.sort(rows) == Enum.sort([{noisy.name, "3"}, {quiet.name, ""}]),
             "The \"Show all\" line doubles as the expand control"
    end
  end

  # Click a section's HEADER collapse toggle, posting the DESIRED next state
  # (the server takes the value rather than flipping), and return the new
  # render. Scoped by class because the stage-3 "Show all (N)" line posts the
  # same event for the same section, so the bare event selector matches two
  # elements once a section is ajar.
  defp click_collapse(view, section, collapsed?) do
    view
    |> element(~s(button.channel-section-collapse-toggle[phx-value-section_id="#{section.id}"]))
    |> render_click(%{"section_id" => section.id, "collapsed" => to_string(collapsed?)})
  end

  # {channel name, unread pill text} for every row rendered inside ONE section
  # of the DESKTOP rail, in DOM order. Scoped to the section element on purpose:
  # a channel name also appears in the mobile overlay and can appear in another
  # section, so a whole-blob match would satisfy a presence assertion without
  # the row being anywhere near the section under test. The pill text rides
  # along so a row can't be counted as "peeked" while showing no count.
  defp section_rows(html, section_id) do
    html
    |> desktop_sidebar()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      ~s(section[data-section-id="#{section_id}"] .channel-row-wrap a.channel-row)
    )
    |> Enum.map(fn row ->
      {node_text(row, "span.truncate"), node_text(row, "span.channel-row-unread-pill")}
    end)
  end

  defp node_text(node, selector) do
    node |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  # The whole visible text of one desktop-rail section, whitespace collapsed.
  defp section_text(html, section_id) do
    html
    |> desktop_sidebar()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(section[data-section-id="#{section_id}"]))
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp show_all_button(html, section_id) do
    html
    |> desktop_sidebar()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(section[data-section-id="#{section_id}"] button.channel-ajar-show-all))
  end

  defp authenticated_conn_with_user(conn) do
    user = insert_chat_user()
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_channel_in(name, slug, section) do
    {:ok, ch} =
      Chat.create_space(%{name: name, slug: slug, kind: "channel", org_id: section.org_id})

    ch
  end

  # Real unread for `user_id` in `space`: join the reader, join a second
  # participant, and post `count` messages as that second participant. The
  # reader never marks the space read, so last_read_message_id stays nil and
  # every one of those messages counts (`count_unread/3` caps that branch at
  # 10, so keep `count` well under it).
  defp seed_unread(space, user_id, count) do
    {:ok, _reader} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    {:ok, other} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    for n <- 1..count do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: other.id,
          content_type: "text",
          content: "unread #{n}"
        })
    end

    :ok
  end

  # Read one attribute off a given section's collapse toggle. Returns nil when
  # the toggle isn't rendered at all, so a missing control fails loudly rather
  # than matching an expected string by omission.
  defp collapse_toggle_attr(html, section_id, attr) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      ~s(section[data-section-id="#{section_id}"] button[phx-click="toggle_section_collapsed"])
    )
    |> LazyHTML.attribute(attr)
    |> List.first()
  end

  # One channel filed into the lowest-position org section, returned with that
  # section so a test can address the exact header it collapsed.
  defp seed_channel_in_first_section do
    # Through the Sidebar list (not a bare Repo.all) so the struct carries
    # `org_name`: the header text is `Section.display_name/1` (task 01a08212).
    section = Sidebar.list_default_sections() |> Enum.min_by(& &1.position)

    {:ok, channel} =
      Chat.create_space(%{
        name: "Collapsible",
        slug: "collapsible",
        kind: "channel",
        org_id: section.org_id
      })

    {section, channel}
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

  # ── The colourless case (task 01a00910 stage 4) ─────────────────────────
  #
  # Stages 2 and 3 made it possible for the rail to render an org whose colour
  # token the vocabulary has never heard of: every org now gets a
  # `channel_sections` row, and buckets derive from the orgs table rather than
  # a hardcoded six-slug map. `section_dot_class/1` returns nil for such a
  # token BY DESIGN — there is deliberately no seventh clause — and the
  # template used to omit the dot entirely on nil, sliding that header's text
  # one dot-width left and ragged-edging the column.
  #
  # These tests assert the span EXISTS. An assertion that only checked for the
  # modifier class name would have been green against the old omit-the-dot
  # behaviour AND green after the fix, proving nothing.

  # The dot span rendered inside one specific section element, or "".
  # Queried by section id, NOT by `data-section-slug`: that attribute IS the
  # colour token, which is exactly the thing under test (absent or
  # unrecognised here), so it cannot also be the handle we grab the section by.
  defp section_dot_html(html, section_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(section[id="section-#{section_id}"] .channel-section-color-dot))
    |> LazyHTML.to_html()
  end

  defp acme_admin_conn(conn) do
    conn = authenticated_conn(conn)
    uid = user_id(conn)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: uid,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    {conn, Repo.get!(User, uid)}
  end

  describe "section header dot — an org with no colour token" do
    test "an unrecognised colour token renders a hollow dot, not no dot", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      create_channel("general")

      # Goes through the REAL org-creation path, so the section row is the one
      # stage 2's `ensure_default_section/1` writes, carrying colour
      # "newclient", the token of an org with no colour set.
      {:ok, org} = Tenancy.create_org(admin, %{name: "NewClient", slug: "newclient"})

      section = Repo.get_by!(Section, org_id: org.id)
      assert section.color == "newclient"
      # The token names this org's own row, but the row has no colour, so the
      # dot keeps the hollow modifier (task 01a14dd9 stage 2).
      refute org.color_hue

      assert PlatformWeb.ChatLive.section_dot_modifier(
               section,
               Tenancy.scope_token_index(Tenancy.list_orgs())
             ) == "channel-section-color-dot--unassigned"

      {:ok, _view, html} = live_following_redirect(conn)
      dot = section_dot_html(desktop_sidebar(html), section.id)

      assert dot != "",
             """
             The NewClient section header rendered NO colour dot at all.
             That is the ragged-edge failure this stage exists to prevent:
             without the reserved slot the header text slides one dot-width
             plus the gap to the left, so the newest org is the one that
             looks misaligned in a list where alignment is the only signal
             that these sections are peers.
             """

      assert dot =~ "channel-section-color-dot--unassigned"
      assert dot =~ ~s(aria-hidden="true")
      refute dot =~ "bg-newclient-dot"
    end

    test "a nil colour renders a hollow dot, not no dot", %{conn: conn} do
      {conn, admin} = acme_admin_conn(conn)
      create_channel("general")

      {:ok, org} = Tenancy.create_org(admin, %{name: "Colourless", slug: "colourless"})
      section = Repo.get_by!(Section, org_id: org.id)

      # The other half of `section_dot_class/1`'s nil return: a section whose
      # colour was never assigned at all, rather than one whose token is
      # simply unknown.
      {1, _} =
        Repo.update_all(
          from(s in Section, where: s.id == ^section.id),
          set: [color: nil]
        )

      {:ok, _view, html} = live_following_redirect(conn)
      dot = section_dot_html(desktop_sidebar(html), section.id)

      assert dot != "", "a section with color: nil rendered no colour dot at all"
      assert dot =~ "channel-section-color-dot--unassigned"
      assert dot =~ ~s(aria-hidden="true")
    end

    test "a known colour token still renders its swatch and NOT the modifier", %{conn: conn} do
      conn = authenticated_conn(conn)
      create_channel("general")

      globex_section = Repo.get_by!(Section, org_id: Tenancy.get_org_by_slug!("globex").id)

      {:ok, _view, html} = live_following_redirect(conn)
      dot = section_dot_html(desktop_sidebar(html), globex_section.id)

      assert dot =~ ~r/channel-section-color-dot--scope"\s+data-scope="globex"/

      refute dot =~ "channel-section-color-dot--unassigned",
             "Globex has a colour token; a hollow ring there would assert " <>
               "'not yet assigned' about an org that IS assigned"
    end
  end
end
