defmodule PlatformWeb.ChatLiveSectionLabelFollowsOrgTest do
  @moduledoc """
  Task 01a08212 stage 2, rendered in the LiveView: a section that follows its
  org (stored `name` nil) is named by the org's CURRENT name.

  Burrow redesign 22 stage 2 deleted the desktop channel rail: its section
  headers, the admin-edit label input, its hint and reset, and the masked
  section headers are gone, so those cases are deleted. The surviving surface
  that names a section is the move-to-organisation chooser, opened from the
  row menu.

  The org rename is a direct `Repo.update(Org.changeset(...))` of the org row,
  the only rename path that exists today.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
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

  defp mount!(user) do
    conn = init_test_session(build_conn(), current_user_id: user.id)

    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
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

      # The row menu opens by right-click on the Chat list row (hook
      # RowContextMenu), which pushes `open_row_actions`.
      render_hook(view, "open_row_actions", %{"space_id" => acme.id})

      view
      |> element(~s(button[data-role="move-to-org-trigger"][phx-value-channel_id="#{acme.id}"]))
      |> render_click()

      destination =
        ~s([data-role="move-to-org-destination"][phx-value-channel_id="#{acme.id}"][data-section-id="#{section_id}"])

      assert has_element?(view, destination, "Newclient")
    end
  end
end
