defmodule PlatformWeb.ChatLiveAdminEditTest do
  @moduledoc """
  Acme-admin "Move to organisation…" from the chat row menu: the two-step
  request/confirm flow and its server-side guards.

  Burrow redesign 22 stage 2 deleted the desktop channel rail, and with it the
  "Edit company default" mode (rename / recolor / reorder of org-default
  sections), the move confirmation toast, and the per-org section placement a
  confirmed move used to repaint. Those cases are deleted. The move flow
  survives behind the row menu (`row_actions_dialog/1`, opened by
  `open_row_actions`), so its cases are retargeted there.

  `Sidebar.reassign_channel/3` re-checks `Tenancy.root_admin?/1`, so a
  non-admin's forged events write nothing.
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

  defp destination_selector(section_id),
    do: ~s([data-role="move-to-org-destination"][data-section-id="#{section_id}"])

  defp trigger_selector(channel_id),
    do: ~s([data-role="move-to-org-trigger"][phx-value-channel_id="#{channel_id}"])

  # One row's menu (`row_actions_dialog/1`). At lg it opens on right-click of
  # a Chat list row, which the RowContextMenu hook turns into `open_row_actions`.
  #
  # `LazyHTML.query/2`, not `filter/2`: filter keeps ROOT nodes matching the
  # selector, and the roots of a rendered page are `<html>` and friends.
  defp open_row_menu(view, channel_id) do
    view
    |> render_hook("open_row_actions", %{"space_id" => channel_id})
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

  describe "admin move to organisation" do
    test "requesting a move opens the confirmation and writes nothing until it is confirmed",
         %{conn: conn} do
      admin = admin_user!("reassign")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("roamer", "acme")
      globex_section = section_id_for_org("globex")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
      globex_org_id = Tenancy.get_org_by_slug!("globex").id
      to_label = displayed_name(globex_section)
      from_label = displayed_name(section_id_for_org("acme"))

      {:ok, view, _html} = live_following_redirect(conn)

      # Driven through the REAL controls, not forged events: the row's trigger
      # renders the popover, the popover's Globex entry opens the confirmation.
      # A handler test alone would pass for a control nothing is wired to.
      open_move_menu(view, channel.id)

      # The chooser offers the other orgs and NOT the one the channel is
      # already in — a destination that writes nothing is not a destination.
      # Matched by selector rather than by substring, so the assertion does
      # not depend on the order HEEx happens to emit the attributes in.
      assert has_element?(view, destination_selector(globex_section))
      refute has_element?(view, destination_selector(section_id_for_org("acme")))

      html = pick_move_destination(view, channel.id, globex_section)

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

      assert Chat.get_space(channel.id).org_id == globex_org_id
    end

    test "cancelling a requested move leaves the channel where it was", %{conn: conn} do
      admin = admin_user!("reassign_cancel")
      conn = authenticated_conn(conn, admin)
      channel = create_channel("stayer", "acme")
      globex_section = section_id_for_org("globex")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, channel.id)
      pick_move_destination(view, channel.id, globex_section)

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
      globex_section = section_id_for_org("globex")
      initech_section = section_id_for_org("initech")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
      globex_org_id = Tenancy.get_org_by_slug!("globex").id

      {:ok, view, _html} = live_following_redirect(conn)

      # The admin approves ONE move: #approved to Globex.
      open_move_menu(view, approved.id)
      pick_move_destination(view, approved.id, globex_section)

      # The confirm event then arrives naming a DIFFERENT channel and a
      # DIFFERENT destination. This is the whole point of the two-step split:
      # `confirm_channel_reassign` reads its ids from `@reassign_confirm`, so
      # the payload is inert. The actor here is a genuine admin, which is what
      # makes this a mutation probe rather than an authorization test — an
      # authorization check would let this through.
      render_hook(view, "confirm_channel_reassign", %{
        "channel_id" => bystander.id,
        "target_section_id" => initech_section
      })

      # The approved move happened, exactly as approved.
      assert Chat.get_space(approved.id).org_id == globex_org_id
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

      {:ok, view, _html} = live_following_redirect(conn)

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
      assert has_element?(
               view,
               ~s(#chat-list-scroller a[data-role="chat-list-row"][data-space-id="#{unfiled.id}"])
             )

      forged =
        render_hook(view, "request_channel_reassign", %{
          "channel_id" => unfiled.id,
          "target_section_id" => section_id_for_org("globex")
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
      _blocker = create_channel("general", "globex")
      globex_section = section_id_for_org("globex")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id
      to_label = displayed_name(globex_section)

      {:ok, view, _html} = live_following_redirect(conn)

      open_move_menu(view, mover.id)
      pick_move_destination(view, mover.id, globex_section)

      html = view |> element(~s(button[data-role="move-to-org-confirm"])) |> render_click()

      assert html =~ "A channel in #{to_label} already uses that name."
      refute html =~ "Could not move the channel."
      # The write was refused, not half-applied.
      assert Chat.get_space(mover.id).org_id == acme_org_id
    end
  end

  describe "non-admins cannot move" do
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
      globex_section = section_id_for_org("globex")
      acme_org_id = Tenancy.get_org_by_slug!("acme").id

      {:ok, view, _html} = live_following_redirect(conn)

      # (1) The affordance is absent — asserted where it now LIVES.
      #
      # Anchored on the row menu's own contents, with the admin control above
      # proving the menu is a place the item CAN appear.
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
          "target_section_id" => globex_section
        })

      refute html =~ ~s(data-role="move-to-org-dialog")

      # (3) A forged step-2 writes nothing either — belt and braces, since
      # `Sidebar.reassign_channel/3` re-checks `root_admin?` underneath.
      render_hook(view, "confirm_channel_reassign", %{
        "channel_id" => channel.id,
        "target_section_id" => globex_section
      })

      assert Chat.get_space(channel.id).org_id == acme_org_id
    end
  end
end
