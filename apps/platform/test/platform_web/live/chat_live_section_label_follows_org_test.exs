defmodule PlatformWeb.ChatLiveSectionLabelFollowsOrgTest do
  @moduledoc """
  Task 01a08212 stage 2, rendered in the LiveView: a rail section header
  follows its org's CURRENT name, and the admin-edit input is an optional
  sidebar-only label (Saru's canvas 01a0dff3-bb77, option 2b).

  Every org rename here is a direct `Repo.update(Org.changeset(...))` of the
  org row. That is deliberate, not a shortcut: it IS the only rename path that
  exists today. `AdminOrgsLive` is create-only, `Tenancy.Lifecycle` touches
  `Org.changeset/2` only on create/archive/restore, and no MCP tool renames an
  org, so production renames happen by SQL against this row.

  The org is created through `Tenancy.create_org/2` with a slug unrelated to
  its name (`lbl<n>`), so the unmasked `data-section-slug` (the colour token,
  which is out of scope here and stays the slug) cannot spell either name and
  the "no spelling of the old name" absence checks measure the label alone.
  Absence goes through `Platform.MaskAssertions.refute_name_anywhere/2`, which
  checks the display form AND both slug forms, attributes included: a bare
  `refute html =~ name` passes a name leaking through `data-section-slug`.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  import Ecto.Query, only: [from: 2]

  defp admin_user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "label_follows_#{n}@example.com",
        name: "Label Follows #{n}",
        oidc_sub: "oidc-label-follows-#{n}",
        avatar_url: nil
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end

  defp create_org!(admin, name) do
    n = System.unique_integer([:positive])
    {:ok, org} = Tenancy.create_org(admin, %{name: name, slug: "lbl#{n}"})
    org
  end

  # The only org-rename path that exists today: a direct update of the row.
  defp rename_org!(org, name) do
    {:ok, renamed} = org |> Org.changeset(%{name: name}) |> Repo.update()
    renamed
  end

  defp channel_in!(org) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Lblchan#{n}", slug: "lblchan#{n}", kind: "channel"})

    {:ok, space} = Chat.assign_space_org(space, org.id)
    space
  end

  defp acme_channel! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Acmechan#{n}", slug: "acmechan#{n}", kind: "channel"})

    {:ok, space} = Chat.assign_space_org(space, Tenancy.get_org_by_slug!("acme").id)
    space
  end

  defp section_id!(org) do
    Repo.one!(from(s in Section, where: s.org_id == ^org.id, select: s.id))
  end

  defp stored_name(section_id) do
    Repo.one!(from(s in Section, where: s.id == ^section_id, select: s.name))
  end

  defp mount!(user) do
    conn = init_test_session(build_conn(), current_user_id: user.id)

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

  defp section_html(view, section_id) do
    view |> element(~s(#chat-sidebar section#section-#{section_id})) |> render()
  end

  defp enter_admin_edit(view) do
    view |> element(~s(button[phx-click="toggle_sidebar_menu"])) |> render_click()

    view
    |> element(~s(button[role="menuitem"][phx-click="toggle_sidebar_admin_edit"]))
    |> render_click()
  end

  defp label_input_html(view, section_id) do
    view
    |> element(~s(#chat-sidebar section#section-#{section_id} input[name="name"]))
    |> render()
  end

  defp hint_html(view, section_id) do
    view
    |> element(~s(#chat-sidebar section#section-#{section_id} [data-role="section-label-hint"]))
    |> render()
  end

  defp reset_selector(section_id),
    do:
      ~s(#chat-sidebar section#section-#{section_id} button[data-role="section-label-reset"][phx-value-section_id="#{section_id}"])

  defp header_selector(section_id, name),
    do: ~s(#chat-sidebar section#section-#{section_id}[aria-label="#{name} channels"])

  describe "(a) a following section's header tracks an org rename" do
    test "a re-mount after a direct row rename shows the NEW name and no spelling of the old" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _channel = channel_in!(org)
      section_id = section_id!(org)

      # Positive control: before the rename the surface DOES carry the old
      # name, so the absence check below is testing a surface that held it.
      {:ok, before_view, _html} = mount!(admin)
      assert has_element?(before_view, header_selector(section_id, "Oldclient"))
      assert_name_anywhere(section_html(before_view, section_id), "Oldclient")

      rename_org!(org, "Newclient")

      {:ok, view, html} = mount!(admin)

      assert has_element?(view, header_selector(section_id, "Newclient"))
      assert section_html(view, section_id) =~ "Newclient"
      refute_name_anywhere(desktop_sidebar(html), "Oldclient")
      assert stored_name(section_id) == nil
    end
  end

  describe "(b) a custom label survives an org rename" do
    test "a label set through rename_section_default is still the header after the rename" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _channel = channel_in!(org)
      section_id = section_id!(org)

      {:ok, view, _html} = mount!(admin)

      render_hook(view, "rename_section_default", %{
        "section_id" => section_id,
        "name" => "Milhouse"
      })

      rename_org!(org, "Newclient")

      {:ok, view2, html2} = mount!(admin)

      assert has_element?(view2, header_selector(section_id, "Milhouse"))
      refute_name_anywhere(section_html(view2, section_id), "Newclient")
      refute_name_anywhere(desktop_sidebar(html2), "Oldclient")
      assert stored_name(section_id) == "Milhouse"
    end
  end

  describe "(c) admin-edit shows which state the header is in, and the reset clears it" do
    test "custom label: hint names the org, the reset button clears the row and the header follows" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _channel = channel_in!(org)
      section_id = section_id!(org)
      assert {:ok, _} = Sidebar.rename_section(admin, section_id, "Milhouse")
      rename_org!(org, "Newclient")

      {:ok, view, _html} = mount!(admin)
      enter_admin_edit(view)

      input = label_input_html(view, section_id)
      assert input =~ ~s(value="Milhouse")
      assert input =~ ~s(placeholder="Newclient")

      hint = hint_html(view, section_id)
      assert hint =~ "Sidebar label only. The organisation is Newclient."
      refute hint =~ "Uses the organisation name."
      assert has_element?(view, reset_selector(section_id), "Use organisation name")
      assert has_element?(view, reset_selector(section_id) <> ~s([phx-value-name=""]))
      assert has_element?(view, reset_selector(section_id) <> ~s([type="button"]))

      view |> element(reset_selector(section_id)) |> render_click()

      assert stored_name(section_id) == nil

      input_after = label_input_html(view, section_id)
      refute input_after =~ ~s(value=)
      assert input_after =~ ~s(placeholder="Newclient")
      assert hint_html(view, section_id) =~ "Uses the organisation name."
      refute has_element?(view, reset_selector(section_id))

      {:ok, view2, _html2} = mount!(admin)
      assert has_element?(view2, header_selector(section_id, "Newclient"))
    end

    test "following: input is empty with the org name as placeholder, no reset button" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _channel = channel_in!(org)
      section_id = section_id!(org)
      rename_org!(org, "Newclient")

      {:ok, view, _html} = mount!(admin)
      enter_admin_edit(view)

      input = label_input_html(view, section_id)
      refute input =~ ~s(value=)
      assert input =~ ~s(placeholder="Newclient")
      assert input =~ "placeholder:text-subtle"

      hint = hint_html(view, section_id)
      assert hint =~ "Uses the organisation name."
      refute hint =~ "Sidebar label only."
      refute has_element?(view, reset_selector(section_id))
    end
  end

  describe "(d) a masked session after a rename" do
    test "header, aria-labels and data-section-slug carry a placeholder and neither name" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _channel = channel_in!(org)
      section_id = section_id!(org)
      rename_org!(org, "Newclient")

      {:ok, view, _html} = mount!(admin)
      assert_name_anywhere(section_html(view, section_id), "Newclient")

      view |> element(~s(button[phx-click="toggle_mask_names"])) |> render_click()

      section = section_html(view, section_id)
      assert section =~ ~r/aria-label="Workspace [A-Z]+ channels"/
      assert section =~ ~r/data-section-slug="workspace-[a-z]+"/
      refute section =~ ~r/aria-label="Workspace channels"/

      sidebar = view |> render() |> desktop_sidebar()
      refute_name_anywhere(sidebar, "Newclient")
      refute_name_anywhere(sidebar, "Oldclient")
    end
  end

  describe "(e) the input's accessible name is the sidebar label for the org" do
    test "reads 'Sidebar label for <org>' in both states, never 'Rename … section'" do
      admin = admin_user!()
      following = create_org!(admin, "Oldclient")
      labelled = create_org!(admin, "Otherco Holdings")
      _ = channel_in!(following)
      _ = channel_in!(labelled)
      following_id = section_id!(following)
      labelled_id = section_id!(labelled)
      assert {:ok, _} = Sidebar.rename_section(admin, labelled_id, "Otherco")
      rename_org!(following, "Newclient")

      {:ok, view, _html} = mount!(admin)
      html = enter_admin_edit(view)

      assert label_input_html(view, following_id) =~ ~s(aria-label="Sidebar label for Newclient")

      assert label_input_html(view, labelled_id) =~
               ~s(aria-label="Sidebar label for Otherco Holdings")

      refute desktop_sidebar(html) =~ ~r/aria-label="Rename [^"]* section"/
    end
  end

  describe "(f) the move-to-organisation chooser names a following section" do
    test "the destination row reads the org's current name, not an empty stored name" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      _ = channel_in!(org)
      section_id = section_id!(org)
      acme = acme_channel!()
      rename_org!(org, "Newclient")

      {:ok, view, _html} = mount!(admin)

      view
      |> element(~s(button[data-role="row-actions-trigger"][data-space-id="#{acme.id}"]))
      |> render_click()

      view
      |> element(~s(button[data-role="move-to-org-trigger"][phx-value-channel_id="#{acme.id}"]))
      |> render_click()

      destination =
        ~s([data-role="move-to-org-destination"][phx-value-channel_id="#{acme.id}"][data-section-id="#{section_id}"])

      assert has_element?(view, destination, "Newclient")
    end
  end
end
