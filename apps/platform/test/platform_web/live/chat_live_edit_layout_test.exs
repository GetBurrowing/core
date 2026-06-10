defmodule PlatformWeb.ChatLiveEditLayoutTest do
  @moduledoc """
  Desktop "Edit layout" mode for the chat sidebar (Stage 5).

  Covers the per-user arrangement surface wired in chat_live.ex /
  chat_live.html.heex against real DB-backed channels + the migration-seeded
  org sections:

    * toggling edit mode renders grab handles, per-section Hide controls,
      keyboard move controls, and the "Reset to default layout" button;
    * `channel_moved` persists via `users.preferences["chat_channel_order"]`
      and re-renders the channel under its new section;
    * `move_channel` (the keyboard alternative) reorders within a section;
    * hiding a section drops it, and reset restores it;
    * reset clears all per-user overrides.

  Desktop only — mobile is out of scope for this stack. All assertions read
  the desktop `<aside id="chat-sidebar">` substring.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Test-data helpers ──────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "edit_layout_#{suffix}@example.com",
      name: "Edit Layout #{suffix}",
      oidc_sub: "oidc-edit-layout-#{suffix}",
      avatar_url: nil
    })
  end

  defp authenticated_conn(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  # Create a channel and assign it to a specific org so it resolves under
  # that org's seeded section. `org_slug` is one of the seeded tenant slugs
  # (fabrikam / paragon / soylent / wayne_tech / sxi).
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

  # `section_reordered` is keyed by section `id` (Stage 6 — color became an
  # admin-editable, non-unique attribute, so drag identity can't derive from
  # it). Resolve the seeded section id from its color slug.
  defp section_id_for_slug(slug) do
    section = Enum.find(Sidebar.list_default_sections(), &(&1.color == slug))
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

  # Enter personal-edit mode through the NEW overflow-menu entry point: open
  # the "More" menu, then click the "Edit my layout" item. (Normal mode no
  # longer renders a bare "Edit layout" toggle — both edit entry points live
  # inside the overflow menu.) Choosing the item also closes the menu.
  defp enter_personal_edit(view) do
    view |> element(~s(button[phx-click="toggle_sidebar_menu"])) |> render_click()

    view
    |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_edit"]))
    |> render_click()
  end

  # The rendered DOM substring for one section, so a channel-placement
  # assertion is scoped to the right org bucket and can't be satisfied by
  # the same channel rendered elsewhere.
  defp section_fragment(sidebar, section_id) do
    case Regex.run(~r/<section[^>]*id="section-#{section_id}".*?<\/section>/s, sidebar) do
      [match] -> match
      _ -> ""
    end
  end

  # ── (a) Edit toggle renders the edit-mode affordances ───────────────────

  describe "toggle edit mode" do
    test "normal mode shows only the overflow menu; entering edit reveals handles + hide + reset",
         %{conn: conn} do
      user = insert_user("toggle")
      conn = authenticated_conn(conn, user)
      create_channel("general", "fabrikam")
      {:ok, view, html} = live_following_redirect(conn)

      sidebar = desktop_sidebar(html)
      # Normal mode: the header shows ONE compact "More" overflow button, not
      # the old "Edit layout" text toggle. The menu is closed (no item yet),
      # and none of the edit affordances render.
      assert sidebar =~ ~s(phx-click="toggle_sidebar_menu")
      assert sidebar =~ ~s(aria-label="Sidebar layout options")
      refute sidebar =~ "Edit my layout"
      refute sidebar =~ "channel-row-grab"
      refute sidebar =~ ~s(phx-click="reset_sidebar")
      refute sidebar =~ ~s(phx-click="move_channel")
      refute sidebar =~ ~s(phx-click="toggle_section_hidden")

      # Open the overflow menu — the "Edit my layout" item now appears.
      html_menu =
        view
        |> element(~s(button[phx-click="toggle_sidebar_menu"]))
        |> render_click()

      sidebar_menu = desktop_sidebar(html_menu)
      assert sidebar_menu =~ "Edit my layout"
      assert sidebar_menu =~ ~s(role="menu")

      # Choose "Edit my layout" — enters personal-edit AND closes the menu.
      html_after =
        view
        |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_edit"]))
        |> render_click()

      sidebar_after = desktop_sidebar(html_after)
      # Edit mode: a single "Done" exit shows; grab handle + reset + per-section
      # hide + keyboard move controls all render; the menu is gone.
      assert sidebar_after =~ "Done"
      assert sidebar_after =~ "Editing my layout"
      refute sidebar_after =~ ~s(phx-click="toggle_sidebar_menu")
      assert sidebar_after =~ "channel-row-grab"
      assert sidebar_after =~ ~s(phx-click="reset_sidebar")
      assert sidebar_after =~ ~s(phx-click="toggle_section_hidden")
      assert sidebar_after =~ ~s(phx-click="move_channel")
      assert sidebar_after =~ ~s(data-sidebar-edit="true")
    end
  end

  # ── (b) channel_moved persists + re-renders under the new section ───────

  describe "channel_moved" do
    test "moving a channel persists to prefs and re-renders it under the target section",
         %{conn: conn} do
      user = insert_user("move")
      conn = authenticated_conn(conn, user)
      # One channel defaulting to the Fabrikam section; we move it into SXI.
      channel = create_channel("roamer", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")
      sxi_section = section_id_for_org("sxi")

      {:ok, view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Precondition: the channel renders inside the Fabrikam section, not SXI.
      assert section_fragment(sidebar, fabrikam_section) =~ ~s(data-channel-id="#{channel.id}")
      refute section_fragment(sidebar, sxi_section) =~ ~s(data-channel-id="#{channel.id}")

      # Simulate the drag hook's drop into the SXI section.
      html_after =
        render_hook(view, "channel_moved", %{
          "channel_id" => channel.id,
          "target_section_id" => sxi_section,
          "ordered_ids" => [channel.id]
        })

      sidebar_after = desktop_sidebar(html_after)
      # The channel now renders inside SXI and no longer inside Fabrikam.
      assert section_fragment(sidebar_after, sxi_section) =~ ~s(data-channel-id="#{channel.id}")
      refute section_fragment(sidebar_after, fabrikam_section) =~ ~s(data-channel-id="#{channel.id}")

      # Persisted into the user's preferences (channel order under SXI).
      cco = Accounts.get_user_preferences(user.id)["chat_channel_order"]
      assert cco[sxi_section] == [channel.id]
    end

    test "move_channel (keyboard) reorders two channels within a section", %{conn: conn} do
      user = insert_user("kbd")
      conn = authenticated_conn(conn, user)
      first = create_channel("alpha", "fabrikam")
      second = create_channel("bravo", "fabrikam")
      fabrikam_section = section_id_for_org("fabrikam")

      {:ok, view, _html} = live_following_redirect(conn)

      # Move the second channel up one slot via the keyboard control.
      render_hook(view, "move_channel", %{
        "channel_id" => second.id,
        "section_id" => fabrikam_section,
        "direction" => "up"
      })

      cco = Accounts.get_user_preferences(user.id)["chat_channel_order"]
      # Both channels now ordered under the Fabrikam section, second ahead of first.
      assert cco[fabrikam_section] == [second.id, first.id]
    end
  end

  # ── (c) hide then show (via reset) ─────────────────────────────────────

  describe "section hide / show" do
    test "hiding a section drops it; reset brings it back", %{conn: conn} do
      user = insert_user("hide")
      conn = authenticated_conn(conn, user)
      create_channel("general", "fabrikam")
      sxi_section = section_id_for_org("sxi")

      {:ok, view, html} = live_following_redirect(conn)
      assert desktop_sidebar(html) =~ ~s(id="section-#{sxi_section}")

      # Enter edit mode (via the overflow menu) then hide the SXI section.
      enter_personal_edit(view)

      html_hidden =
        render_hook(view, "toggle_section_hidden", %{
          "section_id" => sxi_section,
          "hidden" => "true"
        })

      sidebar_hidden = desktop_sidebar(html_hidden)
      refute sidebar_hidden =~ ~s(id="section-#{sxi_section}")
      assert Accounts.get_user_preferences(user.id)["chat_hidden_sections"] == [sxi_section]

      # Reset restores the hidden section.
      html_reset =
        view
        |> element(~s(button[phx-click="reset_sidebar"]))
        |> render_click()

      sidebar_reset = desktop_sidebar(html_reset)
      assert sidebar_reset =~ ~s(id="section-#{sxi_section}")
      assert Accounts.get_user_preferences(user.id)["chat_hidden_sections"] == []
    end
  end

  # ── (d) reset clears all overrides ─────────────────────────────────────

  describe "reset to default" do
    test "reset clears section order, channel placement, and hidden sections",
         %{conn: conn} do
      user = insert_user("reset")
      conn = authenticated_conn(conn, user)
      channel = create_channel("mover", "fabrikam")
      sxi_section = section_id_for_org("sxi")

      {:ok, view, _html} = live_following_redirect(conn)

      # Build up overrides: a moved channel, a hidden section, a section order.
      render_hook(view, "channel_moved", %{
        "channel_id" => channel.id,
        "target_section_id" => sxi_section,
        "ordered_ids" => [channel.id]
      })

      render_hook(view, "section_reordered", %{
        "from" => section_id_for_slug("sxi"),
        "to" => section_id_for_slug("paragon")
      })

      enter_personal_edit(view)

      render_hook(view, "toggle_section_hidden", %{
        "section_id" => section_id_for_org("soylent"),
        "hidden" => "true"
      })

      prefs_before = Accounts.get_user_preferences(user.id)
      assert prefs_before["chat_channel_order"] != %{}
      assert prefs_before["chat_hidden_sections"] != []
      assert prefs_before["chat_section_order"] != nil

      # Reset wipes all three keys.
      view
      |> element(~s(button[phx-click="reset_sidebar"]))
      |> render_click()

      prefs_after = Accounts.get_user_preferences(user.id)
      assert is_nil(prefs_after["chat_section_order"])
      assert prefs_after["chat_channel_order"] == %{}
      assert prefs_after["chat_hidden_sections"] == []
    end
  end

  # ── User-id isolation: writes target the session user, not the payload ──

  describe "arrangement writes are scoped to the session user" do
    test "channel_moved writes only the authenticated user's prefs", %{conn: conn} do
      user = insert_user("scoped")
      other = insert_user("victim")
      conn = authenticated_conn(conn, user)
      channel = create_channel("scoped-ch", "fabrikam")
      sxi_section = section_id_for_org("sxi")

      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "channel_moved", %{
        "channel_id" => channel.id,
        "target_section_id" => sxi_section,
        "ordered_ids" => [channel.id]
      })

      # The acting user's prefs changed; the other user's are untouched —
      # there is no client-supplied user id, so a payload can't cross users.
      assert Accounts.get_user_preferences(user.id)["chat_channel_order"][sxi_section] ==
               [channel.id]

      assert Accounts.get_user_preferences(other.id) == %{}
    end
  end
end
