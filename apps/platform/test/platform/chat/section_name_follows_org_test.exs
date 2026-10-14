defmodule Platform.Chat.SectionNameFollowsOrgTest do
  @moduledoc """
  Task 01a08212: renaming an org left its `channel_sections` row naming the
  old one, forever. The section stored a COPY of the org name at creation
  time and nothing ever refreshed it.

  The fix (option B) makes `channel_sections.name` a nullable, sidebar-only
  label OVERRIDE: the header renders `section.name || org.name`, resolved at
  read time through `Platform.Chat.Section.display_name/1`.

  Every rename below is a direct `Repo.update(Org.changeset(...))` of the org
  row. That is deliberate, not a shortcut: it IS the only rename path that
  exists today. `AdminOrgsLive` is create-only, `Tenancy.Lifecycle` calls
  `Org.changeset/2` only on create/archive/restore, and no MCP tool renames
  an org, so production renames happen by SQL against this row. A fix that
  relied on a rename hook would never fire for them.

  The sections here all come from `Tenancy.create_org/2`, the real creation
  path; none is seeded with a name that is already right, because such a
  fixture would pass whether or not the name follows the org.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar
  alias Platform.Chat.SidebarMask
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  import Ecto.Query, only: [from: 2]

  defp admin_user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "follows-org-#{n}@example.com",
        name: "Follows Org #{n}",
        oidc_sub: "oidc-follows-org-#{n}"
      })
      |> Repo.insert!()

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
    {:ok, org} = Tenancy.create_org(admin, %{name: name, slug: "follows#{n}"})
    org
  end

  # The only org-rename path that exists today: a direct update of the row.
  defp rename_org!(org, name) do
    {:ok, renamed} = org |> Org.changeset(%{name: name}) |> Repo.update()
    renamed
  end

  defp channel_in!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "general",
        slug: "follows-general-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  defp resolved_section!(resolved, org) do
    case Enum.find(resolved, &(&1.section.org_id == org.id)) do
      %{section: section} -> section
      nil -> flunk("no resolved section for org #{org.slug}")
    end
  end

  defp stored_name(org) do
    Repo.one!(from(s in Section, where: s.org_id == ^org.id, select: s.name))
  end

  describe "(a) a following section tracks an org rename" do
    test "the header reads the NEW org name after a direct row rename" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      channel = channel_in!(org)

      rename_org!(org, "Newclient")

      resolved = Sidebar.resolve_for_user(admin.id, [channel])
      section = resolved_section!(resolved, org)
      placeholders = SidebarMask.placeholders(resolved)

      assert SidebarMask.label(placeholders, section, false, MapSet.new()) == "Newclient"
      assert Section.display_name(section) == "Newclient"
    end
  end

  describe "(b) a custom label survives an org rename" do
    test "a label set through rename_section/3 is not replaced by the new org name" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      channel = channel_in!(org)
      section_id = Repo.one!(from(s in Section, where: s.org_id == ^org.id, select: s.id))

      assert {:ok, _} = Sidebar.rename_section(admin, section_id, "Milhouse")
      rename_org!(org, "Newclient")

      resolved = Sidebar.resolve_for_user(admin.id, [channel])
      section = resolved_section!(resolved, org)

      assert SidebarMask.label(%{}, section, false, MapSet.new()) == "Milhouse"
      assert stored_name(org) == "Milhouse"
    end
  end

  describe "(c) positive control: a stored name that differs from the org is kept" do
    test "a section already carrying a different name renders that name" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      channel = channel_in!(org)

      {1, _} =
        Repo.update_all(from(s in Section, where: s.org_id == ^org.id),
          set: [name: "Legacy Label"]
        )

      resolved = Sidebar.resolve_for_user(admin.id, [channel])
      section = resolved_section!(resolved, org)

      assert SidebarMask.label(%{}, section, false, MapSet.new()) == "Legacy Label"
      refute SidebarMask.label(%{}, section, false, MapSet.new()) == org.name
    end
  end

  describe "(d) masked after a rename" do
    test "the header and a bucket naming the NEW org resolve to the section's placeholder" do
      admin = admin_user!()
      org = create_org!(admin, "Oldclient")
      channel = channel_in!(org)

      rename_org!(org, "Newclient")

      resolved = Sidebar.resolve_for_user(admin.id, [channel])
      section = resolved_section!(resolved, org)
      ctx = SidebarMask.context(resolved, true, MapSet.new())
      placeholder = Map.fetch!(ctx.placeholders, section.id)

      assert placeholder =~ ~r/^Workspace [A-Z]+$/
      assert SidebarMask.label(ctx.placeholders, section, true, MapSet.new()) == placeholder

      # The 01a0938b regression: a bucket named by the org's CURRENT name must
      # still find its section. When the name the mask compared against was a
      # stale copy, the lookup missed and the pill fell back to bare
      # "Workspace", which is the wrong placeholder, not a leak, but still a
      # visible defect.
      bucket_label = SidebarMask.label_for_bucket(ctx, resolved, "Newclient")

      assert bucket_label == placeholder
      refute bucket_label == "Workspace"
      refute bucket_label in ["Newclient", "Oldclient"]
    end
  end

  describe "(e) a new org's section follows it from birth" do
    test "ensure_default_section/1 stores a nil name" do
      admin = admin_user!()
      org = create_org!(admin, "Brandnew")

      assert stored_name(org) == nil
    end
  end
end
