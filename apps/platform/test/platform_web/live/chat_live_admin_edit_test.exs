defmodule PlatformWeb.ChatLiveAdminEditTest do
  @moduledoc """
  Acme-admin "Edit default" mode for the chat sidebar (Stage 6).

  A SEPARATE mode from the personal "Edit layout" (Stage 5): admin-edit routes
  the same gestures to the GLOBAL org default (Sidebar Stage 2 API) instead of
  the acting user's prefs, so an Acme admin curates the company-wide default
  sidebar that everyone sees.

  Covers, against real DB-backed channels + the migration-seeded org sections:

    * the "Edit company default" item renders in the sidebar overflow menu for
      an Acme admin and is ABSENT for a non-admin member;
    * each admin event (rename / recolor / reorder / reassign) persists via the
      Stage 2 `Sidebar.*` API;
    * a NON-admin attempting each event is rejected server-side — no mutation —
      because every handler re-checks authorization through `Sidebar.*`, which
      gates on `Tenancy.root_admin?/1` (the client toggle is an affordance, not
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
    membership!(user, Tenancy.get_org_by_slug!("acme"), "admin")
    user
  end

  defp member_user!(suffix) do
    user = create_user!(suffix)
    membership!(user, Tenancy.get_org_by_slug!("acme"), "member")
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

  # The header text a section renders (task 01a08212): its label override,
  # else its org's CURRENT name. A following section stores a nil `name`, so
  # reading the column would build an expectation of "".
  defp displayed_name(section_id) do
    Sidebar.list_default_sections()
    |> Enum.find(&(&1.id == section_id))
    |> Section.display_name()
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
  # out to personal-edit and (for Acme admins) admin-edit. Returns the rendered
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

  defp trigger_selector(channel_id),
    do: ~s([data-role="move-to-org-trigger"][phx-value-channel_id="#{channel_id}"])

  # One rail row, addressed by BOTH the channel it draws and the section it is
  # drawn under. `.channel-row-wrap` carries both attributes, so a single
  # selector answers "is this row in this section?" without slicing html.
  #
  # Scoped to `#chat-sidebar`: the mobile drawer emits the same two attributes
  # for the same rows, and this module is desktop-only by its own moduledoc, so
  # an unscoped selector would report the drawer's copy as the rail's.
  defp row_selector(channel_id, section_id),
    do: ~s(#chat-sidebar [data-channel-id="#{channel_id}"][data-section-id="#{section_id}"])

  # One section's collapse chevron, addressed by section and by the fold state
  # it is currently reporting. `aria-expanded` is the rendered truth of
  # `collapsed?` on that section, so this reads the resolver's stamp out of the
  # markup instead of re-reading the preference the test just wrote.
  defp collapse_toggle_selector(section_id, expanded?) do
    ~s(#chat-sidebar button[phx-click="toggle_section_collapsed"]) <>
      ~s([phx-value-section_id="#{section_id}"][aria-expanded="#{expanded?}"])
  end

  # One rail row's overflow menu (task 019ff8ba stage 1). The row's three
  # trailing controls, "Move to organisation…" among them, moved behind it, and
  # the menu renders at the TEMPLATE ROOT — outside `<aside id="chat-sidebar">`
  # and so outside every `desktop_sidebar/1` slice in this file.
  #
  # `LazyHTML.query/2`, not `filter/2`: filter keeps ROOT nodes matching the
  # selector, and the roots of a rendered page are `<html>` and friends.
  defp open_row_menu(view, channel_id) do
    view
    |> element(~s(button[data-role="row-actions-trigger"][data-space-id="#{channel_id}"]))
    |> render_click()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="row-actions-dialog"]))
    |> LazyHTML.to_html()
  end

  # "Move to organisation…" step 1a: open one row's destination chooser. Two
  # clicks since 019ff8ba stage 1 — the row's menu, then the item inside it.
  defp open_move_menu(view, channel_id) do
    _ = open_row_menu(view, channel_id)

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

  # The move confirmation at the foot of the rail (task 019ffcad stage 4). It
  # shares the hide toast's `.channel-undo-toast` surface and nothing else, so
  # each of the two lines is addressed by its own hook: this one by `data-role`,
  # the hide one by the message class it has carried since it shipped.
  #
  # Returns "" rather than raising when the element is absent, so a case can
  # assert the line is NOT there without reaching for a second helper.
  defp move_toast_selector,
    do: ~s(#chat-sidebar [data-role="channel-move-toast"])

  defp move_toast_html(view), do: rendered_or_blank(view, move_toast_selector())

  defp hide_toast_html(view),
    do: rendered_or_blank(view, ~s(#chat-sidebar .channel-undo-toast-message))

  defp rendered_or_blank(view, selector) do
    if has_element?(view, selector) do
      view |> element(selector) |> render()
    else
      ""
    end
  end

  # Hide one rail row through the two real controls, same shape as
  # `open_move_menu/2`: the row's overflow menu, then the item inside it.
  defp hide_channel_row(view, channel_id) do
    _ = open_row_menu(view, channel_id)

    view
    |> element(~s(button[data-role="rail-row-actions-hide"][data-space-id="#{channel_id}"]))
    |> render_click()
  end

  # ── (a) toggle visibility: admin sees it, member does not ───────────────

  describe "Edit default (admin) toggle visibility" do
    test "an Acme admin sees the 'Edit company default' item in the overflow menu",
         %{conn: conn} do
      admin = admin_user!("toggle_admin")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")

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
      create_channel("general", "acme")

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
      create_channel("general", "acme")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)
      # Normal mode: no admin-mode inline controls yet.
      refute sidebar =~ ~s(phx-submit="rename_section_default")
      refute sidebar =~ ~s(phx-click="recolor_section_default")

      html_after = enter_admin_edit(view)

      sidebar_after = desktop_sidebar(html_after)
      assert sidebar_after =~ ~s(phx-submit="rename_section_default")
      assert sidebar_after =~ ~s(phx-click="recolor_section_default")
      # The exit button is just "Done" now — the accented mode label
      # ("Editing company default") already says which mode is active, and the
      # rail can't fit "Done (admin)" alongside the label without overflowing.
      assert sidebar_after =~ "Done"
      assert sidebar_after =~ "Editing company default"
      # The overflow menu is gone in edit mode — only the "Done" exit shows.
      refute sidebar_after =~ ~s(phx-click="toggle_sidebar_menu")
    end

    test "admin-edit renders the move-to-org control and NO channel-row grab handle",
         %{conn: conn} do
      # The pair is the point (task 019fd76a stage 2). Refiling a channel used
      # to be a drag in this mode; it is now an explicit menu item with a
      # confirmation dialog. Asserting the handle's absence alone would also
      # pass if the capability had simply been deleted, so the replacement is
      # asserted in the same breath.
      admin = admin_user!("no_grab")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("wanderer", "acme")

      {:ok, view, _html} = live_following_redirect(conn)

      sidebar_admin = desktop_sidebar(enter_admin_edit(view))
      refute sidebar_admin =~ "channel-row-grab"

      # The replacement is asserted where it LIVES, which is no longer the
      # rail: task 019ff8ba stage 1 moved "Move to organisation…" into the
      # row's overflow menu, and that menu renders at the template root,
      # outside every `desktop_sidebar/1` slice in this file. Reading it out
      # of the sidebar would refute the pairing this test exists to prove.
      assert open_row_menu(view, channel.id) =~ ~s(data-role="move-to-org-trigger")

      # Personal-edit is where a row drag still means something, so the handle
      # is there — the gesture moved modes, it did not disappear from the app.
      # Switched by dispatching the other toggle, because an edit mode renders
      # only "Done" in the header: the overflow menu isn't there to click.
      sidebar_personal = desktop_sidebar(render_hook(view, "toggle_sidebar_edit", %{}))
      assert sidebar_personal =~ "channel-row-grab"
    end

    test "admin-edit and personal-edit are mutually exclusive", %{conn: conn} do
      admin = admin_user!("mutex")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")

      {:ok, view, _html} = live_following_redirect(conn)

      # Enter personal-edit via the overflow menu. In an edit mode the header
      # shows only "Done", so to SWITCH modes we dispatch the other toggle
      # directly (the server enforces mutual exclusivity regardless of entry
      # point): admin-edit must replace personal-edit.
      enter_personal_edit(view)
      html = render_hook(view, "toggle_sidebar_admin_edit", %{})
      sidebar = desktop_sidebar(html)

      # Admin-edit is identified by a control only it renders, rather than by
      # a mode flag on the wrapper: the flag was `data-admin-edit`, which went
      # away with the drag it fed (task 019fd76a stage 2).
      assert sidebar =~ ~s(phx-submit="rename_section_default")
      # Personal-edit-only affordances are gone (keyboard move controls render
      # only in personal-edit).
      refute sidebar =~ ~s(phx-click="move_channel")

      # Toggling personal-edit back on exits admin-edit.
      html2 = render_hook(view, "toggle_sidebar_edit", %{})
      sidebar2 = desktop_sidebar(html2)
      refute sidebar2 =~ ~s(phx-submit="rename_section_default")
      assert sidebar2 =~ ~s(phx-click="move_channel")
    end
  end

  # ── (b) admin writes persist via the Stage 2 API ────────────────────────

  describe "admin writes persist the org default" do
    test "rename_section_default renames the org-default section globally",
         %{conn: conn} do
      admin = admin_user!("rename")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "rename_section_default", %{
        "section_id" => acme_section,
        "name" => "Brand & Social"
      })

      assert Repo.get!(Section, acme_section).name == "Brand & Social"
    end

    # Task 01a08212 stage 2: the input is an optional sidebar-only label, so a
    # blank submit is "clear the label" (the header then follows the org),
    # not the silent no-op it was when `name` was the only copy of the name.
    test "a blank rename_section_default clears the label and the header follows the org",
         %{conn: conn} do
      admin = admin_user!("rename_blank")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")
      {:ok, _} = Sidebar.rename_section(admin, acme_section, "Brand & Social")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "rename_section_default", %{
        "section_id" => acme_section,
        "name" => "   "
      })

      assert Repo.get!(Section, acme_section).name == nil
      assert displayed_name(acme_section) == Tenancy.get_org_by_slug!("acme").name

      assert has_element?(
               view,
               ~s(#chat-sidebar section#section-#{acme_section}[aria-label="#{displayed_name(acme_section)} channels"])
             )
    end

    test "recolor_section_default sets the section color to a scope token",
         %{conn: conn} do
      admin = admin_user!("recolor")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => acme_section,
        "color" => "paragon"
      })

      assert Repo.get!(Section, acme_section).color == "paragon"
    end

    test "recolor with an unknown token is ignored (whitelist guard)",
         %{conn: conn} do
      admin = admin_user!("recolor_bad")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")
      original_color = Repo.get!(Section, acme_section).color

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => acme_section,
        "color" => "rainbow"
      })

      assert Repo.get!(Section, acme_section).color == original_color
    end

    test "section_reordered in admin-edit persists positions to the org default",
         %{conn: conn} do
      admin = admin_user!("reorder")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")

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
      channel = create_channel("roamer", "acme")
      sxi_section = section_id_for_org("sxi")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id
      to_label = displayed_name(sxi_section)
      from_label = displayed_name(section_id_for_org("acme"))

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
      refute has_element?(view, destination_selector(section_id_for_org("acme")))

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
      assert Chat.get_space(channel.id).org_id == acme_org_id

      # Step 2 writes.
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert Chat.get_space(channel.id).org_id == sxi_org_id
    end

    test "a confirmed move repaints the acting admin's rail: the row lands in the destination section and leaves the source",
         %{conn: conn} do
      # The user-reported defect (task 019ffcad): the move WRITES, and the
      # acting admin's rail keeps drawing the row under the source section until
      # they navigate or reload, so a move that worked reads as one that failed.
      #
      # The write is not what this measures. `Chat.get_space(id).org_id` flips
      # today, which is why the case above passes against the defect. What is
      # asserted here is the RE-RENDERED rail, driven through the same three
      # real controls a person clicks.
      admin = admin_user!("reassign_repaint")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("repainter", "acme")
      acme_section = section_id_for_org("acme")
      sxi_section = section_id_for_org("sxi")
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id

      {:ok, view, _html} = live_following_redirect(conn)

      # Positive control. Without this the two assertions at the end could both
      # be satisfied by a rail that never drew the row at all. A fresh admin has
      # no personal collapse prefs, so both sections render EXPANDED and a row's
      # absence can only mean the resolver filed it elsewhere.
      assert has_element?(view, row_selector(channel.id, acme_section)),
             "the row must start under its source section, or the assertions below are vacuous"

      refute has_element?(view, row_selector(channel.id, sxi_section))

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, sxi_section)
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      # Sanity, not the point: the write landed, so a failure below is a repaint
      # failure and cannot be misread as a failed move.
      assert Chat.get_space(channel.id).org_id == sxi_org_id

      # Both halves. Absence from the source alone would also pass for a rail
      # that dropped the row entirely, which is a worse bug than the one being
      # fixed.
      assert has_element?(view, row_selector(channel.id, sxi_section)),
             "after the move the row must render under the destination section without a reload"

      refute has_element?(view, row_selector(channel.id, acme_section)),
             "after the move the row must no longer render under the source section"
    end

    test "a confirmed move repaints the OTHER connected sessions' rails, not only the acting admin's",
         %{conn: conn} do
      # Task 019ffcad stage 2. `broadcast_sidebar_defaults_changed_from(self())`
      # excludes only the acting process, so every OTHER connected session runs
      # `handle_info(:sidebar_defaults_changed, ...)`. That handler re-resolved
      # from `socket.assigns.channels`, the list its own session cached, which
      # still carried the pre-move `org_id`. `Sidebar.resolve/3` buckets by the
      # `org_id` on the struct it is handed, so those sessions filed the moved
      # row straight back under the source section: the same defect stage 1
      # fixed for the acting tab, reached by a different route.
      admin = admin_user!("reassign_broadcast_admin")
      channel = create_channel("broadcaster", "acme")
      acme_section = section_id_for_org("acme")
      sxi_section = section_id_for_org("sxi")
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id

      # Session one: the admin who will perform the move.
      {:ok, actor_view, _html} = live_following_redirect(authenticated_conn(conn, admin))

      # Session two: mounted BEFORE the move and never re-mounted after it. A
      # session mounted afterwards re-fetches `@channels` on mount and would
      # render correctly against the defect, which is why the order matters.
      member = member_user!("reassign_broadcast_member")

      {:ok, observer_view, _html} =
        live_following_redirect(authenticated_conn(build_conn(), member))

      # Positive control on SESSION TWO, the rail under test here. Without it
      # both closing assertions could be satisfied by a rail that never drew
      # the row at all.
      assert has_element?(observer_view, row_selector(channel.id, acme_section)),
             "session two must start with the row under its source section, or the assertions below are vacuous"

      refute has_element?(observer_view, row_selector(channel.id, sxi_section))

      # Session one moves the channel through the same three real controls.
      open_move_menu(actor_view, channel.id)
      pick_move_destination(actor_view, channel.id, sxi_section)
      actor_view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      # Sanity, not the point: the write landed, so a failure below is a repaint
      # failure in session two and cannot be misread as a failed move.
      assert Chat.get_space(channel.id).org_id == sxi_org_id

      # Both halves, from session two's re-rendered markup, on the strength of
      # the broadcast alone.
      assert has_element?(observer_view, row_selector(channel.id, sxi_section)),
             "session two must draw the row under the destination section after the broadcast, with no re-mount"

      refute has_element?(observer_view, row_selector(channel.id, acme_section)),
             "session two must stop drawing the row under the source section after the broadcast"
    end

    test "a confirmed move expands a COLLAPSED destination section, so the row is actually visible",
         %{conn: conn} do
      # Task 019ffcad stage 3, and the case stages 1 and 2 cannot pass. Collapse
      # is a flag, never a filter: `Sidebar.resolve/3` stamps `collapsed?` and
      # the section keeps its resolved channels, so the rail can repaint
      # perfectly and still draw nothing. `section_channel_rows/3` renders only
      # the rows carrying unread when a section is collapsed, and a channel just
      # filed into an org has none, so the moved row is absent from the DOM
      # entirely. That is the reported bug reproduced by a fix that passes its
      # own test.
      admin = admin_user!("reassign_collapsed_dest")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("collapsed_lander", "acme")
      acme_section = section_id_for_org("acme")
      sxi_section = section_id_for_org("sxi")
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id

      # The precondition, written before the mount so the resolver reads it.
      # ONLY the destination is collapsed: the source stays expanded so the
      # positive control below still means something.
      {:ok, _} = Sidebar.set_section_collapsed(admin.id, sxi_section, true)

      {:ok, view, _html} = live_following_redirect(conn)

      # Precondition asserted from the markup, not from the write. If the
      # destination renders EXPANDED here the setup has failed and everything
      # after it is a stage-1 repaint test wearing a stage-3 name.
      assert has_element?(view, collapse_toggle_selector(sxi_section, false)),
             "the destination section must start collapsed, or this case is a duplicate of the repaint test"

      # The other half of the precondition: no unread on the moved channel. With
      # unread the collapsed section would peek the row anyway (the "ajar group")
      # and the case would pass without the fix.
      assert Chat.list_messages(channel.id) == [],
             "the moved channel must carry no unread, or a collapsed section peeks its row"

      # Positive control, same shape as the two cases above.
      assert has_element?(view, row_selector(channel.id, acme_section)),
             "the row must start under its source section, or the assertions below are vacuous"

      refute has_element?(view, row_selector(channel.id, sxi_section))

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, sxi_section)
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      # Sanity, not the point: the write landed, so a failure below is a
      # visibility failure and cannot be misread as a failed move.
      assert Chat.get_space(channel.id).org_id == sxi_org_id

      # Both halves, from the re-rendered markup. The destination half is the
      # one that fails without the expansion: the row is not merely folded out
      # of sight, it is not in the document.
      assert has_element?(view, row_selector(channel.id, sxi_section)),
             "after the move the row must render under the destination section even though it was collapsed"

      refute has_element?(view, row_selector(channel.id, acme_section)),
             "after the move the row must no longer render under the source section"

      # Corroboration on the mechanism: the destination is expanded, which is
      # why the row draws. The other way the assertion above could pass is a
      # collapsed section that started drawing quiet rows, which would be a
      # regression in `section_channel_rows/3` rather than this fix working.
      assert has_element?(view, collapse_toggle_selector(sxi_section, true)),
             "confirming the move must expand the destination section for the acting admin"
    end

    test "a confirmed move states the move at the foot of the rail, naming the channel AND the destination",
         %{conn: conn} do
      # Task 019ffcad stage 4, from the design canvas. Stages 1 to 3 put the row
      # in its new home and make it visible there. None of them says anything to
      # the admin, who is looking at the section they just filed a channel OUT
      # of, where the only observable event is a row disappearing.
      #
      # Both names or nothing. "Moved #Confirmer." leaves the reader hunting for
      # where it went, which is the work this line exists to save, and a test
      # asserting only "Moved" or only the channel name would pass for that copy.
      # So the assertion is the whole sentence, assembled from the two names read
      # from their own sources (the space row and the section row) rather than
      # from the markup under test.
      admin = admin_user!("reassign_confirmation")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("confirmer", "acme")
      sxi_section = section_id_for_org("sxi")
      sxi_org_id = Tenancy.get_org_by_slug!("sxi").id
      to_label = displayed_name(sxi_section)

      expected = "Moved ##{channel.name} to #{to_label}."

      {:ok, view, html} = live_following_redirect(conn)

      # Positive control. The sentence sitting on the page before the move would
      # make everything below it vacuous.
      refute desktop_sidebar(html) =~ expected

      refute has_element?(view, move_toast_selector()),
             "the rail must carry no move confirmation before a move"

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, sxi_section)
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      # Sanity, not the point: the write landed, so a failure below is a missing
      # confirmation and cannot be misread as a failed move.
      assert Chat.get_space(channel.id).org_id == sxi_org_id

      assert move_toast_html(view) =~ expected,
             "the rail must state the move in one sentence naming both the channel and the destination"

      # WCAG: the line is announced, and politely. A move is a routine filing
      # action, so it interrupts nothing.
      assert has_element?(
               view,
               ~s(#{move_toast_selector()}[role="status"][aria-live="polite"])
             ),
             "the confirmation must announce itself as role=status / aria-live=polite"

      # No action button. Undo is deliberately out of scope for this stage: the
      # move already carries a two-step confirmation and the row's menu moves it
      # back in one click. Robin's separate decision to offer an Undo here is
      # task 01a01052-3155-7c15-8c48-9ff8955b9b70, and this line is what that
      # task will change.
      refute has_element?(view, ~s(#{move_toast_selector()} button)),
             "the confirmation carries an action button, which this stage rules out"
    end

    test "a hide and a move each keep their own line: neither acknowledgement overwrites the other",
         %{conn: conn} do
      # The two lines sit on SEPARATE assigns on purpose. Sharing `@undo_toast`
      # would have whichever action came second silently blank the first, and a
      # case that only ever fires one of the two verbs cannot see that: each
      # would pass alone. So this fires both, in both orders, and asserts each
      # line survives the other.
      admin = admin_user!("reassign_two_toasts")
      conn = authenticated_conn(conn, admin)
      hidden_first = create_channel("hidden-first", "acme")
      moved = create_channel("moved-second", "acme")
      hidden_last = create_channel("hidden-last", "acme")
      sxi_section = section_id_for_org("sxi")
      to_label = displayed_name(sxi_section)

      expected_move = "Moved ##{moved.name} to #{to_label}."

      {:ok, view, _html} = live_following_redirect(conn)

      # Order one: hide, then move.
      hide_channel_row(view, hidden_first.id)

      assert hide_toast_html(view) =~ "##{hidden_first.name}",
             "the hide raised no line of its own, so the survival assertions below are vacuous"

      open_move_menu(view, moved.id)
      pick_move_destination(view, moved.id, sxi_section)
      view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert move_toast_html(view) =~ expected_move,
             "the move raised no line, so this case cannot measure the collision"

      assert hide_toast_html(view) =~ "##{hidden_first.name}",
             "the move overwrote the hide's line, so the two verbs share one assign"

      # Order two: a hide AFTER the move must leave the move's line standing.
      hide_channel_row(view, hidden_last.id)

      assert hide_toast_html(view) =~ "##{hidden_last.name}",
             "the second hide raised no line of its own"

      assert move_toast_html(view) =~ expected_move,
             "the hide overwrote the move's line, so the two verbs share one assign"
    end

    test "cancelling a requested move leaves the channel where it was", %{conn: conn} do
      admin = admin_user!("reassign_cancel")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("stayer", "acme")
      sxi_section = section_id_for_org("sxi")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, sxi_section)

      html = view |> element(~s(button[data-role="move-to-org-cancel"])) |> render_click()

      # The dialog is gone and the channel never moved.
      refute html =~ ~s(data-role="move-to-org-dialog")
      assert Chat.get_space(channel.id).org_id == acme_org_id
    end

    test "a forged confirm payload cannot re-point an approved move", %{conn: conn} do
      admin = admin_user!("reassign_repoint")
      conn = authenticated_conn(conn, admin)
      approved = create_channel("approved", "acme")
      bystander = create_channel("bystander", "acme")
      sxi_section = section_id_for_org("sxi")
      soylent_section = section_id_for_org("soylent")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
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
      assert Chat.get_space(bystander.id).org_id == acme_org_id
    end

    test "a forged request naming the org the channel is already in opens no confirmation",
         %{conn: conn} do
      admin = admin_user!("reassign_noop")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("stayput", "acme")
      acme_section = section_id_for_org("acme")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id

      {:ok, view, _html} = live_following_redirect(conn)

      # The chooser never offers the org a channel is already in, so this can
      # only arrive forged. "Move #stayput to Acme?" for a channel already in
      # Acme is a question with no answer, and confirming it would write a
      # no-op the admin had been told was a move.
      html =
        render_hook(view, "request_channel_reassign", %{
          "channel_id" => channel.id,
          "target_section_id" => acme_section
        })

      refute html =~ ~s(data-role="move-to-org-dialog")
      assert Chat.get_space(channel.id).org_id == acme_org_id
    end

    test "a channel filed under no organisation gets no move control", %{conn: conn} do
      admin = admin_user!("reassign_unfiled")
      conn = authenticated_conn(conn, admin)

      # No `assign_space_org`, so `org_id` stays nil. The resolver still
      # RENDERS the row (unfiled channels fall back to the lowest-position
      # section), so the row is present and only the control is absent.
      # Filing a channel for the first time is a different action from moving
      # it between two named orgs, and the confirmation copy has no honest way
      # to name the org it would be leaving.
      {:ok, unfiled} = Chat.create_space(%{name: "Unfiled", slug: "unfiled", kind: "channel"})
      filed = create_channel("filed", "acme")

      {:ok, view, html} = live_following_redirect(conn)

      # Positive control in the SAME session: a filed channel does get one, so
      # this is not passing because the control is broken everywhere. Since
      # task 019ff8ba stage 1 the item lives in the row's overflow menu, which
      # holds one row at a time, so the two rows are opened in turn rather
      # than read off a single render.
      _ = open_row_menu(view, filed.id)
      assert has_element?(view, trigger_selector(filed.id))

      unfiled_menu = open_row_menu(view, unfiled.id)

      assert unfiled_menu =~ ~s(data-role="row-actions-dialog"),
             "the unfiled row's menu did not open, so the refutation below is vacuous"

      refute has_element?(view, trigger_selector(unfiled.id))
      # ...and the row itself is on screen, so it is the control that is
      # missing rather than the channel.
      assert desktop_sidebar(html) =~ unfiled.id

      forged =
        render_hook(view, "request_channel_reassign", %{
          "channel_id" => unfiled.id,
          "target_section_id" => section_id_for_org("sxi")
        })

      refute forged =~ ~s(data-role="move-to-org-dialog")
      assert Chat.get_space(unfiled.id).org_id == nil
    end

    test "a name already taken in the destination org says so, not 'could not move'",
         %{conn: conn} do
      admin = admin_user!("reassign_collision")
      conn = authenticated_conn(conn, admin)

      # Two channels called "general" in two different orgs is the ORDINARY
      # shape of this data, so `chat_spaces_unique_org_slug` fires in routine
      # use rather than as an edge case.
      mover = create_channel("general", "acme")
      _blocker = create_channel("general", "sxi")
      sxi_section = section_id_for_org("sxi")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
      to_label = displayed_name(sxi_section)

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, mover.id)
      pick_move_destination(view, mover.id, sxi_section)

      html = view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert html =~ "A channel in #{to_label} already uses that name."
      refute html =~ "Could not move the channel."
      # The write was refused, not half-applied.
      assert Chat.get_space(mover.id).org_id == acme_org_id
    end
  end

  # ── (b3) recolor changes ONLY the color, never the name/label ────────────
  #
  # Regression for the user-reported BUG (task 019e467d): the section header
  # used to render a `<.scope_pill scope={section_scope_atom(section.color)}>`,
  # so the pill's VISIBLE TEXT was derived from the section's COLOR. Recoloring
  # a section (e.g. Acme → yellow/paragon) flipped the chip text to "Paragon"
  # even though the section's real name was still "Acme" — the recolor looked
  # like a rename. The fix renders a COLOR-ONLY dot keyed off `section.color`;
  # identity text comes solely from `section.name`. These tests assert on the
  # RENDERED header (not just the DB write the earlier reviews verified).

  describe "recolor changes only the color, never the section name/label" do
    test "recoloring a section keeps the rendered NAME and does not relabel it to the color's scope",
         %{conn: conn} do
      admin = admin_user!("recolor_render")
      conn = authenticated_conn(conn, admin)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")
      original_label = Repo.get!(Section, acme_section).name

      # The header text is the DISPLAYED name (task 01a08212): the label
      # override, else the org's current name. A following section's stored
      # `name` is nil, so the stored column alone says nothing about the text.
      original_name = displayed_name(acme_section)

      {:ok, view, _html} = live_following_redirect(conn)
      html_before = enter_admin_edit(view)
      sidebar_before = desktop_sidebar(html_before)

      # Before the recolor the root section header carries its own-org dot and
      # the rename input shows its real name. The root has no compiled dot
      # class since task 01a116de stage 3: the dot is coloured from the org
      # row through `data-scope`. (The recolor target — paragon — must NOT
      # already be the root dot's color.)
      assert sidebar_before =~
               ~r/class="channel-section-color-dot channel-section-color-dot--unassigned"\s+data-scope="acme"/

      assert sidebar_before =~ ~s(aria-label="Collapse #{original_name}")

      # Recolor Acme → paragon (the "yellow" swatch in the palette).
      html_after =
        render_hook(view, "recolor_section_default", %{
          "section_id" => acme_section,
          "color" => "paragon"
        })

      sidebar_after = desktop_sidebar(html_after)

      # The dot color changed to paragon…
      assert sidebar_after =~ "bg-paragon-dot",
             "Recoloring to paragon should change the section's color dot"

      refute sidebar_after =~
               ~r/class="channel-section-color-dot channel-section-color-dot--unassigned"\s+data-scope="acme"/

      # The palette still offers the root's OWN token, so the recolor is
      # reversible, and the server accepts it for this section.
      assert sidebar_after =~ ~s(phx-value-color="acme")

      render_hook(view, "recolor_section_default", %{
        "section_id" => acme_section,
        "color" => "acme"
      })

      assert Repo.get!(Section, acme_section).color == "acme"

      # …but the section's NAME is unchanged — the recolor did NOT rename it.
      assert Repo.get!(Section, acme_section).name == original_label

      assert sidebar_after =~ ~s(aria-label="Collapse #{original_name}"),
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
      create_channel("general", "acme")

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
      create_channel("general", "acme")

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
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")
      original = Repo.get!(Section, acme_section)

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "rename_section_default", %{
        "section_id" => acme_section,
        "name" => "Hijacked"
      })

      assert Repo.get!(Section, acme_section).name == original.name
    end

    test "recolor_section_default by a member does not mutate the section",
         %{conn: conn} do
      member = member_user!("recolor_reject")
      conn = authenticated_conn(conn, member)
      create_channel("general", "acme")
      acme_section = section_id_for_org("acme")
      original = Repo.get!(Section, acme_section)

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "recolor_section_default", %{
        "section_id" => acme_section,
        "color" => "paragon"
      })

      assert Repo.get!(Section, acme_section).color == original.color
    end

    test "section_reordered by a member does not change the global default order",
         %{conn: conn} do
      member = member_user!("reorder_reject")
      conn = authenticated_conn(conn, member)
      create_channel("general", "acme")

      {:ok, view, _html} = live_following_redirect(conn)

      before_ids = Sidebar.list_default_sections() |> Enum.map(& &1.id)
      [first | _] = sections = Sidebar.list_default_sections()
      last = List.last(sections)

      # A member can't even enter admin-edit (toggle is hidden + the handler
      # re-checks root_admin?), so we force the event directly. The handler
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

    test "an Acme admin's row menu carries the move item", %{conn: conn} do
      # The positive control for the refutation in the test below. Since task
      # 019ff8ba stage 1 the item lives in a menu that has to be opened, so a
      # build that dropped the item for EVERYONE would satisfy that refutation
      # on its own. This is what makes the role, rather than the move, the
      # thing being measured there.
      admin = admin_user!("reassign_positive")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("roamer", "acme")

      {:ok, view, _html} = live_following_redirect(conn)

      menu = open_row_menu(view, channel.id)

      assert menu =~ ~s(data-role="move-to-org-trigger"),
             "an admin's row menu is missing the move item"

      assert menu =~ ~s(phx-value-channel_id="#{channel.id}"),
             "the move item is not wired to this row's channel id"
    end

    test "a member gets no move control, no confirmation from a forged request, and no write from a forged confirm",
         %{conn: conn} do
      member = member_user!("reassign_reject")
      conn = authenticated_conn(conn, member)
      channel = create_channel("roamer", "acme")
      sxi_section = section_id_for_org("sxi")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id

      {:ok, view, _html} = live_following_redirect(conn)

      # (1) The affordance is absent — asserted where it now LIVES.
      #
      # This used to refute the trigger inside `desktop_sidebar(html)`. Task
      # 019ff8ba stage 1 moved it into the row's overflow menu, which renders
      # at the template root, so that refutation became true for every user of
      # any role and the test passed while proving nothing. Re-anchored on the
      # menu's own contents, with the admin control below proving the menu is
      # a place the item CAN appear.
      member_menu = open_row_menu(view, channel.id)

      assert member_menu =~ ~s(data-role="row-actions-dialog"),
             "the member's row menu did not open, so the refutation below is vacuous"

      refute member_menu =~ ~s(data-role="move-to-org-trigger"),
             "a non-admin's row menu offers the move item"

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
      # `Sidebar.reassign_channel/3` re-checks `root_admin?` underneath.
      render_hook(view, "confirm_channel_reassign", %{
        "channel_id" => channel.id,
        "target_section_id" => sxi_section
      })

      assert Chat.get_space(channel.id).org_id == acme_org_id
    end

    test "a member cannot enter admin-edit even by forging the toggle event",
         %{conn: conn} do
      member = member_user!("toggle_forge")
      conn = authenticated_conn(conn, member)
      create_channel("general", "acme")

      {:ok, view, _html} = live_following_redirect(conn)

      # Forge the toggle event a non-admin could never click (the button is
      # hidden). The handler re-checks @root_admin? and refuses to flip.
      html = render_hook(view, "toggle_sidebar_admin_edit", %{})
      sidebar = desktop_sidebar(html)

      refute sidebar =~ ~s(phx-submit="rename_section_default")
      refute sidebar =~ ~s(phx-click="recolor_section_default")
    end
  end
end
