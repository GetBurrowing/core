defmodule PlatformWeb.ChatLiveAdminEditTest do
  @moduledoc """
  Fabrikam-admin "Edit default" mode for the chat sidebar (Stage 6).

  A SEPARATE mode from the personal "Edit layout" (Stage 5): admin-edit routes
  the same gestures to the GLOBAL org default (Sidebar Stage 2 API) instead of
  the acting user's prefs, so a Fabrikam admin curates the company-wide default
  sidebar that everyone sees.

  Covers, against real DB-backed channels + the migration-seeded org sections:

    * the "Edit company default" item renders in the sidebar overflow menu for
      a Fabrikam admin and is ABSENT for a non-admin member;
    * each admin event (rename / recolor / reorder / reassign) persists via the
      Stage 2 `Sidebar.*` API;
    * a NON-admin attempting each event is rejected server-side — no mutation —
      because every handler re-checks authorization through `Sidebar.*`, which
      gates on `Tenancy.fabrikam_admin?/1` (the client toggle is an affordance, not
      the gate).

  Desktop only — mobile is out of scope for this stack. Sidebar assertions read
  the desktop `<aside id="chat-sidebar">` substring.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Test-data helpers (mirrors sidebar_test.exs admin/member fixtures) ──

  defp create_user!(suffix) do
    Repo.insert!(%User{
      email: "admin_edit_#{suffix}@example.com",
      name: "Admin Edit #{suffix}",
      oidc_sub: "oidc-admin-edit-#{suffix}",
      avatar_url: nil
    })
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp admin_user!(suffix) do
    user = create_user!(suffix)
    membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "admin")
    user
  end

  defp member_user!(suffix) do
    user = create_user!(suffix)
    membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")
    user
  end

  defp authenticated_conn(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug, org_slug) do
    {:ok, ch} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

    {:ok, ch} = Chat.assign_space_org(ch, Tenancy.get_org_by_slug!(org_slug).id)
    ch
  end

  defp section_id_for_org(org_slug) do
    org_id = Tenancy.get_org_by_slug!(org_slug).id
    section = Enum.find(Sidebar.list_default_sections(), &(&1.org_id == org_id))
    section.id
  end

  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  # Open the sidebar overflow ("More") menu — the single entry point that fans
  # out to personal-edit and (for Fabrikam admins) admin-edit. Returns the rendered
  # html so callers can assert on the open menu.
  defp open_sidebar_menu(view) do
    view |> element(~s(button[phx-click="toggle_sidebar_menu"])) |> render_click()
  end

  # Enter admin-edit via the overflow menu: open the menu, then click the
  # "Edit company default" item (admin-only). Choosing it closes the menu.
  defp enter_admin_edit(view) do
    open_sidebar_menu(view)

    view
    |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_admin_edit"]))
    |> render_click()
  end

  # Enter personal-edit via the overflow menu.
  defp enter_personal_edit(view) do
    open_sidebar_menu(view)

    view
    |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_edit"]))
    |> render_click()
  end

  # The ordered list of section `color` slugs as RENDERED in the sub-org rail
  # (data-section-slug), so a reorder assertion runs against the same order the
  # server handler reads from @sidebar_sections.
  defp rendered_section_slugs(html) do
    sidebar = desktop_sidebar(html)

    Regex.scan(~r/data-section-slug="([^"]+)"/, sidebar)
    |> Enum.map(fn [_, slug] -> slug end)
  end

  defp section_id_for_slug(slug) do
    section = Enum.find(Sidebar.list_default_sections(), &(&1.color == slug))
    section.id
  end

  defp destination_selector(section_id),
    do: ~s([data-role="move-to-org-destination"][data-section-id="#{section_id}"])

  # "Move to organisation…" step 1a: open one row's destination chooser.
  defp open_move_menu(view, channel_id) do
    view
    |> element(~s(button[data-role="move-to-org-trigger"][phx-value-channel_id="#{channel_id}"]))
    |> render_click()
  end

  # Step 1b: pick a destination out of the open popover. Clicking the real
  # entry (rather than pushing `request_channel_reassign` directly) is what
  # proves the popover is wired to the handler at all.
  defp pick_move_destination(view, channel_id, section_id) do
    view
    |> element(
      ~s(button[data-role="move-to-org-destination"][phx-value-channel_id="#{channel_id}"][data-section-id="#{section_id}"])
    )
    |> render_click()
  end

  # ── (a) toggle visibility: admin sees it, member does not ───────────────

  describe "Edit default (admin) toggle visibility" do
    test "a Fabrikam admin sees the 'Edit company default' item in the overflow menu",
         %{conn: conn} do
      admin = admin_user!("toggle_admin")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)
      # Both edit entry points now live behind ONE overflow button; the admin
      # item is NOT in the DOM until the menu is opened.
      assert sidebar =~ ~s(phx-click="toggle_sidebar_menu")
      refute sidebar =~ "Edit company default"

      # Open the menu — the admin sees BOTH the personal and the admin item.
      sidebar_open = desktop_sidebar(open_sidebar_menu(view))
      assert sidebar_open =~ ~s(phx-click="toggle_sidebar_admin_edit")
      assert sidebar_open =~ "Edit company default"
      assert sidebar_open =~ ~s(phx-click="toggle_sidebar_edit")
      assert sidebar_open =~ "Edit my layout"
    end

    test "a non-admin member does NOT see the admin item in the overflow menu",
         %{conn: conn} do
      member = member_user!("toggle_member")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)
      # The member still has the overflow button (for the personal entry point).
      assert sidebar =~ ~s(phx-click="toggle_sidebar_menu")

      # Open the menu — the admin item is ABSENT; the personal item is present.
      sidebar_open = desktop_sidebar(open_sidebar_menu(view))
      refute sidebar_open =~ ~s(phx-click="toggle_sidebar_admin_edit")
      refute sidebar_open =~ "Edit company default"
      assert sidebar_open =~ ~s(phx-click="toggle_sidebar_edit")
      assert sidebar_open =~ "Edit my layout"
    end

    test "entering admin-edit reveals rename inputs + recolor palette", %{conn: conn} do
      admin = admin_user!("toggle_reveal")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)
      # Normal mode: no admin-mode inline controls yet.
      refute sidebar =~ ~s(phx-submit="rename_section_default")
      refute sidebar =~ ~s(phx-click="recolor_section_default")

      html_after = enter_admin_edit(view)

      sidebar_after = desktop_sidebar(html_after)
      assert sidebar_after =~ ~s(phx-submit="rename_section_default")
      assert sidebar_after =~ ~s(phx-click="recolor_section_default")
      assert sidebar_after =~ ~s(data-admin-edit="true")
      # The exit button is just "Done" now — the accented mode label
      # ("Editing company default") already says which mode is active, and the
      # rail can't fit "Done (admin)" alongside the label without overflowing.
      assert sidebar_after =~ "Done"
      assert sidebar_after =~ "Editing company default"
      # The overflow menu is gone in edit mode — only the "Done" exit shows.
      refute sidebar_after =~ ~s(phx-click="toggle_sidebar_menu")
    end

    test "admin-edit and personal-edit are mutually exclusive", %{conn: conn} do
      admin = admin_user!("mutex")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      # Enter personal-edit via the overflow menu. In an edit mode the header
      # shows only "Done", so to SWITCH modes we dispatch the other toggle
      # directly (the server enforces mutual exclusivity regardless of entry
      # point): admin-edit must replace personal-edit.
      enter_personal_edit(view)
      html = render_hook(view, "toggle_sidebar_admin_edit", %{})
      sidebar = desktop_sidebar(html)

      assert sidebar =~ ~s(data-admin-edit="true")
      # Personal-edit-only affordances are gone (keyboard move controls render
      # only in personal-edit).
      refute sidebar =~ ~s(phx-click="move_channel")

      # Toggling personal-edit back on exits admin-edit.
      html2 = render_hook(view, "toggle_sidebar_edit", %{})
      sidebar2 = desktop_sidebar(html2)
      assert sidebar2 =~ ~s(data-admin-edit="false")
      assert sidebar2 =~ ~s(phx-click="move_channel")
    end
  end

  # ── (b) admin writes persist via the Stage 2 API ────────────────────────

  describe "admin writes persist the org default" do
    test "rename_section_default renames the org-default section globally",
         %{conn: conn} do
      admin = admin_user!("rename")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "rename_section_default", %{
        "section_id" => fabrikam_section,
        "name" => "Brand & Social"
      })

      assert Repo.get!(Section, fabrikam_section).name == "Brand & Social"
    end

    test "recolor_section_default sets the section color to a scope token",
         %{conn: conn} do
      admin = admin_user!("recolor")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => fabrikam_section,
        "color" => "paragon"
      })

      assert Repo.get!(Section, fabrikam_section).color == "paragon"
    end

    test "recolor with an unknown token is ignored (whitelist guard)",
         %{conn: conn} do
      admin = admin_user!("recolor_bad")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")
      original_color = Repo.get!(Section, fabrikam_section).color

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => fabrikam_section,
        "color" => "rainbow"
      })

      assert Repo.get!(Section, fabrikam_section).color == original_color
    end

    test "section_reordered in admin-edit persists positions to the org default",
         %{conn: conn} do
      admin = admin_user!("reorder")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")

      {:ok, view, html} = live_following_redirect(conn)

      # Enter admin-edit (via the overflow menu) so the section_reordered
      # handler routes to the global default (reorder_sections) not per-user.
      enter_admin_edit(view)

      # The handler builds the new order from the RENDERED `@sidebar_sections`
      # and resolves `from`/`to` by section ID (Stage 6 — drag identity is the
      # stable, unique section id, no longer the now-mutable `color` slug). For
      # a fresh admin with no personal order the rendered order follows
      # `Section.position`, so derive from/to ids from the rendered slug order
      # (first → last) and assert against the path the handler takes.
      rendered_slugs = rendered_section_slugs(html)
      before_ids = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      from_id = section_id_for_slug(hd(rendered_slugs))
      to_id = section_id_for_slug(List.last(rendered_slugs))

      # Drag the first-rendered section onto the last-rendered section's slot.
      render_hook(view, "section_reordered", %{"from" => from_id, "to" => to_id})

      after_ids = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      # The global default order changed, and the dragged section now sits
      # immediately before its drop target (standard drag-reorder semantics:
      # `from` lands in `to`'s slot, pushing `to` one position later).
      refute after_ids == before_ids

      assert Enum.find_index(after_ids, &(&1 == from_id)) ==
               Enum.find_index(after_ids, &(&1 == to_id)) - 1
    end

    test "requesting a move opens the confirmation and writes nothing until it is confirmed",
         %{conn: conn} do
      admin = admin_user!("reassign")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("roamer", "fabrikam")
      sxi_section = section_id_for_org("sxi")
      fabrikam_org_id = Tenancy.get_org_by_slug!("fabrikam").id
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id
      to_label = Repo.get!(Section, sxi_section).name
      from_label = Repo.get!(Section, section_id_for_org("fabrikam")).name

      {:ok, view, _html} = live_following_redirect(conn)

      # Driven through the REAL controls, not forged events: the row's trigger
      # renders the popover, the popover's SXI entry opens the confirmation.
      # A handler test alone would pass for a control nothing is wired to.
      open_move_menu(view, channel.id)

      # The chooser offers the other orgs and NOT the one the channel is
      # already in — a destination that writes nothing is not a destination.
      # Matched by selector rather than by substring, so the assertion does
      # not depend on the order HEEx happens to emit the attributes in.
      assert has_element?(view, destination_selector(sxi_section))
      refute has_element?(view, destination_selector(section_id_for_org("fabrikam")))

      html = pick_move_destination(view, channel.id, sxi_section)

      # All four lines, verbatim. The canvas line in particular is a verified
      # fact about `CanvasAccess.org_readable_space?/2` and an earlier draft of
      # this dialog stated its opposite, so it is asserted rather than trusted.
      assert html =~ "Move ##{channel.name} to #{to_label}?"
      assert html =~ "Everyone sees this channel filed under #{to_label}."
      assert html =~ "Nobody is added to or removed from the channel."

      assert html =~
               "People in #{to_label} will be able to open this channel&#39;s canvases by direct link, and people in #{from_label} will not."

      assert html =~ "Personal layouts are not affected."

      # Step 1 wrote NOTHING.
      assert Chat.get_space(channel.id).org_id == fabrikam_org_id

      # Step 2 writes.
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert Chat.get_space(channel.id).org_id == sxi_org_id
    end

    test "cancelling a requested move leaves the channel where it was", %{conn: conn} do
      admin = admin_user!("reassign_cancel")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("stayer", "fabrikam")
      sxi_section = section_id_for_org("sxi")
      fabrikam_org_id = Tenancy.get_org_by_slug!("fabrikam").id

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, sxi_section)

      html = view |> element(~s(button[data-role="move-to-org-cancel"])) |> render_click()

      # The dialog is gone and the channel never moved.
      refute html =~ ~s(data-role="move-to-org-dialog")
      assert Chat.get_space(channel.id).org_id == fabrikam_org_id
    end

    test "a forged confirm payload cannot re-point an approved move", %{conn: conn} do
      admin = admin_user!("reassign_repoint")
      conn = authenticated_conn(conn, admin)
      approved = create_channel("approved", "fabrikam")
      bystander = create_channel("bystander", "fabrikam")
      sxi_section = section_id_for_org("sxi")
      soylent_section = section_id_for_org("soylent")
      fabrikam_org_id = Tenancy.get_org_by_slug!("fabrikam").id
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id

      {:ok, view, _html} = live_following_redirect(conn)

      # The admin approves ONE move: #approved to SXI.
      open_move_menu(view, approved.id)
      pick_move_destination(view, approved.id, sxi_section)

      # The confirm event then arrives naming a DIFFERENT channel and a
      # DIFFERENT destination. This is the whole point of the two-step split:
      # `confirm_channel_reassign` reads its ids from `@reassign_confirm`, so
      # the payload is inert. The actor here is a genuine admin, which is what
      # makes this a mutation probe rather than an authorization test — an
      # authorization check would let this through.
      render_hook(view, "confirm_channel_reassign", %{
        "channel_id" => bystander.id,
        "target_section_id" => soylent_section
      })

      # The approved move happened, exactly as approved.
      assert Chat.get_space(approved.id).org_id == sxi_org_id
      # The channel named in the forged payload did not move.
      assert Chat.get_space(bystander.id).org_id == fabrikam_org_id
    end

    test "a name already taken in the destination org says so, not 'could not move'",
         %{conn: conn} do
      admin = admin_user!("reassign_collision")
      conn = authenticated_conn(conn, admin)

      # Two channels called "general" in two different orgs is the ORDINARY
      # shape of this data, so `chat_spaces_unique_org_slug` fires in routine
      # use rather than as an edge case.
      mover = create_channel("general", "fabrikam")
      _blocker = create_channel("general", "sxi")
      sxi_section = section_id_for_org("sxi")
      fabrikam_org_id = Tenancy.get_org_by_slug!("fabrikam").id
      to_label = Repo.get!(Section, sxi_section).name

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, mover.id)
      pick_move_destination(view, mover.id, sxi_section)

      html = view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert html =~ "A channel in #{to_label} already uses that name."
      refute html =~ "Could not move the channel."
      # The write was refused, not half-applied.
      assert Chat.get_space(mover.id).org_id == fabrikam_org_id
    end
  end

  # ── (b3) recolor changes ONLY the color, never the name/label ────────────
  #
  # Regression for the user-reported BUG (task 019e467d): the section header
  # used to render a `<.scope_pill scope={section_scope_atom(section.color)}>`,
  # so the pill's VISIBLE TEXT was derived from the section's COLOR. Recoloring
  # a section (e.g. Fabrikam → yellow/paragon) flipped the chip text to "Paragon"
  # even though the section's real name was still "Fabrikam" — the recolor looked
  # like a rename. The fix renders a COLOR-ONLY dot keyed off `section.color`;
  # identity text comes solely from `section.name`. These tests assert on the
  # RENDERED header (not just the DB write the earlier reviews verified).

  describe "recolor changes only the color, never the section name/label" do
    test "recoloring a section keeps the rendered NAME and does not relabel it to the color's scope",
         %{conn: conn} do
      admin = admin_user!("recolor_render")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")
      original_name = Repo.get!(Section, fabrikam_section).name

      {:ok, view, _html} = live_following_redirect(conn)
      html_before = enter_admin_edit(view)
      sidebar_before = desktop_sidebar(html_before)

      # Before the recolor the Fabrikam section header carries the fabrikam dot and the
      # rename input shows its real name. (The recolor target — paragon — must
      # NOT already be the fabrikam dot's color.)
      assert sidebar_before =~ "bg-fabrikam-dot"
      assert sidebar_before =~ ~s(value="#{original_name}")

      # Recolor Fabrikam → paragon (the "yellow" swatch in the palette).
      html_after =
        render_hook(view, "recolor_section_default", %{
          "section_id" => fabrikam_section,
          "color" => "paragon"
        })

      sidebar_after = desktop_sidebar(html_after)

      # The dot color changed to paragon…
      assert sidebar_after =~ "bg-paragon-dot",
             "Recoloring to paragon should change the section's color dot"

      # …but the section's NAME is unchanged — the recolor did NOT rename it.
      assert Repo.get!(Section, fabrikam_section).name == original_name

      assert sidebar_after =~ ~s(value="#{original_name}"),
             "Recolor must not change the rendered section name"

      # And crucially the header NEVER renders the color-derived scope label
      # ("Paragon scope") — the bug was that the pill text tracked the color.
      refute sidebar_after =~ ~s(aria-label="Paragon scope"),
             "Section header must not render a color-derived scope label after recolor"
    end
  end

  # ── (b2) admin reorder is VISIBLE in the rendered rail for other users ───
  #
  # Regression for the Stage 6 CRITICAL finding: `reorder_sections_default`
  # correctly wrote `channel_sections.position`, but the rail's render order was
  # re-sorted by section NAME (the alphabetical default `@section_order`) for
  # every user who had not personally reordered — so the admin reorder was
  # functionally dead in the UI. These tests assert on the RENDERED
  # `data-section-slug` order (not just the DB), including for a SECOND fresh
  # user, so a render-order regression fails the suite.

  describe "admin reorder is visible in the rendered rail" do
    test "a fresh user sees the admin's new section order in the rendered rail",
         %{conn: _conn} do
      admin = admin_user!("reorder_visible_admin")
      create_channel("general", "fabrikam")

      # Admin reorders the global default: move the first-rendered section to the
      # last slot via the admin path.
      admin_conn = authenticated_conn(build_conn(), admin)
      {:ok, admin_view, admin_html} = live_following_redirect(admin_conn)
      enter_admin_edit(admin_view)

      slugs_before = rendered_section_slugs(admin_html)
      from_id = section_id_for_slug(hd(slugs_before))
      to_id = section_id_for_slug(List.last(slugs_before))
      render_hook(admin_view, "section_reordered", %{"from" => from_id, "to" => to_id})

      # The DB default order changed (sanity — the write landed).
      default_slugs_after =
        Sidebar.list_default_sections() |> Enum.map(& &1.color)

      refute default_slugs_after == slugs_before

      # A SECOND, fresh user (no personal arrangement) mounts and must see the
      # rail rendered in the admin's NEW position order — NOT alphabetical.
      member = member_user!("reorder_visible_member")
      member_conn = authenticated_conn(build_conn(), member)
      {:ok, _member_view, member_html} = live_following_redirect(member_conn)

      assert rendered_section_slugs(member_html) == default_slugs_after,
             "A fresh user's rendered section order must honor Section.position " <>
               "after an admin reorder, not the alphabetical name default."
    end

    test "a fresh user's default rendered order is the seeded position order",
         %{conn: conn} do
      # Before any admin reorder, the seeded position order IS alphabetical-by-
      # name, so this passes either way — it guards against a future regression
      # where the resolver stops honoring position for the default case.
      member = member_user!("default_position")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")

      {:ok, _view, html} = live_following_redirect(conn)

      assert rendered_section_slugs(html) ==
               Sidebar.list_default_sections() |> Enum.map(& &1.color)
    end
  end

  # ── (c) non-admin is rejected server-side: NO mutation ──────────────────

  describe "non-admin events are rejected server-side" do
    test "rename_section_default by a member does not mutate the section",
         %{conn: conn} do
      member = member_user!("rename_reject")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")
      original = Repo.get!(Section, fabrikam_section)

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "rename_section_default", %{
        "section_id" => fabrikam_section,
        "name" => "Hijacked"
      })

      assert Repo.get!(Section, fabrikam_section).name == original.name
    end

    test "recolor_section_default by a member does not mutate the section",
         %{conn: conn} do
      member = member_user!("recolor_reject")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")
      original = Repo.get!(Section, fabrikam_section)

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => fabrikam_section,
        "color" => "paragon"
      })

      assert Repo.get!(Section, fabrikam_section).color == original.color
    end

    test "section_reordered by a member does not change the global default order",
         %{conn: conn} do
      member = member_user!("reorder_reject")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      before_ids = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      [first | _] = sections = Sidebar.list_default_sections()
      last = List.last(sections)

      # A member can't even enter admin-edit (toggle is hidden + the handler
      # re-checks fabrikam_admin?), so we force the event directly. The handler
      # falls back to the PERSONAL reorder path (sidebar_admin_edit is false),
      # which writes the member's own prefs — NOT the global default. Either
      # way the global channel_sections.position order is untouched. Keyed by
      # section id (Stage 6 — drag identity is the section id, not color).
      render_hook(view, "section_reordered", %{
        "from" => first.id,
        "to" => last.id
      })

      assert Sidebar.list_default_sections() |> Enum.map(& &1.id) == before_ids
    end

    test "a member gets no move control, no confirmation from a forged request, and no write from a forged confirm",
         %{conn: conn} do
      member = member_user!("reassign_reject")
      conn = authenticated_conn(conn, member)
      channel = create_channel("roamer", "fabrikam")
      sxi_section = section_id_for_org("sxi")
      fabrikam_org_id = Tenancy.get_org_by_slug!("fabrikam").id

      {:ok, view, html} = live_following_redirect(conn)

      # (1) The affordance is absent.
      refute desktop_sidebar(html) =~ ~s(data-role="move-to-org-trigger")

      # (2) A forged step-1 assigns NO confirmation. This is what stops a
      # non-admin from getting a populated `@reassign_confirm` that a later
      # confirm could then act on.
      html =
        render_hook(view, "request_channel_reassign", %{
          "channel_id" => channel.id,
          "target_section_id" => sxi_section
        })

      refute html =~ ~s(data-role="move-to-org-dialog")

      # (3) A forged step-2 writes nothing either — belt and braces, since
      # `Sidebar.reassign_channel/3` re-checks `fabrikam_admin?` underneath.
      render_hook(view, "confirm_channel_reassign", %{
        "channel_id" => channel.id,
        "target_section_id" => sxi_section
      })

      assert Chat.get_space(channel.id).org_id == fabrikam_org_id
    end

    test "a member cannot enter admin-edit even by forging the toggle event",
         %{conn: conn} do
      member = member_user!("toggle_forge")
      conn = authenticated_conn(conn, member)
      create_channel("general", "fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      # Forge the toggle event a non-admin could never click (the button is
      # hidden). The handler re-checks @fabrikam_admin? and refuses to flip.
      html = render_hook(view, "toggle_sidebar_admin_edit", %{})
      sidebar = desktop_sidebar(html)

      assert sidebar =~ ~s(data-admin-edit="false")
      refute sidebar =~ ~s(phx-submit="rename_section_default")
    end
  end
end
