defmodule PlatformWeb.ChatLiveOrgScopeTest do
  @moduledoc """
  The chat rail and header resolve a channel's scope pill from the org ROW
  (slug + name), not from a closed map of the six shipped orgs (task 01a0938b
  stage 1).

  Before this stage a runtime-created org got no pill anywhere in chat: the
  drawer went through `sub_org_scope_atom/1` (six display names), the header
  through `space_scope_atom/1` -> `section_scope_atom/1` (six slugs), and both
  returned nil for anything else. `org_scope/1` keeps the six shipped atoms,
  because `@scope_filter` holds atoms and the header's active state compares
  against it, and hands every other org its stored slug as a binary.
  """

  use Platform.DataCase, async: true

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias PlatformWeb.ChatLive

  # Deliberately a name that is NOT the title-cased slug ("New Client"), so a
  # label derived from the slug and one read from the row cannot agree.
  defp runtime_org!(attrs \\ %{}) do
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    Repo.insert!(
      Org.changeset(
        %Org{},
        Map.merge(
          %{name: "Newclient", slug: "new_client", parent_org_id: fabrikam.id, color_hue: 200},
          attrs
        )
      )
    )
  end

  defp channel_on(org) do
    %Space{
      id: Ecto.UUID.generate(),
      name: "anything-at-all",
      slug: "anything-at-all",
      kind: "channel",
      org_id: org.id,
      is_direct: false
    }
  end

  describe "org_scope/1" do
    test "a shipped slug keeps its existing scope atom" do
      assert ChatLive.org_scope("wayne_tech") == :wayne_tech
      assert ChatLive.org_scope("fabrikam") == :fabrikam
    end

    test "a runtime org's slug is returned as the stored binary, never an atom" do
      assert ChatLive.org_scope("new_client") == "new_client"
    end
  end

  describe "space_scope_atom/1" do
    test "a channel on a runtime-created org resolves to that org's slug" do
      org = runtime_org!()

      assert ChatLive.space_scope_atom(channel_on(org)) == "new_client"
    end

    test "a channel on a shipped org keeps its atom" do
      wayne_tech = Tenancy.get_org_by_slug!("wayne_tech")

      assert ChatLive.space_scope_atom(channel_on(wayne_tech)) == :wayne_tech
    end

    test "dm and group spaces still carry no scope" do
      org = runtime_org!()

      assert ChatLive.space_scope_atom(%{kind: "dm", org_id: org.id}) == nil
      assert ChatLive.space_scope_atom(%{kind: "group", org_id: org.id}) == nil
    end
  end

  describe "channel_sections/5 bucket_orgs" do
    test "each bucket carries the org's slug, name and scope from the same read" do
      org = runtime_org!()

      sections = ChatLive.channel_sections([channel_on(org)], [])

      assert sections.bucket_orgs["Newclient"] ==
               %{slug: "new_client", name: "Newclient", scope: "new_client"}

      wayne_tech = Tenancy.get_org_by_slug!("wayne_tech")

      assert sections.bucket_orgs[wayne_tech.name] ==
               %{slug: "wayne_tech", name: wayne_tech.name, scope: :wayne_tech}
    end

    test "a rename moves the bucket key and keeps the slug" do
      org = runtime_org!()
      ch = channel_on(org)

      before = ChatLive.channel_sections([ch], [])
      assert before.bucket_orgs["Newclient"].slug == "new_client"

      # A new name that does not contain the old one, so the absence check
      # below cannot pass by substring.
      org |> Org.changeset(%{name: "Brightwater"}) |> Repo.update!()

      after_rename = ChatLive.channel_sections([ch], [])

      assert after_rename.sub_orgs["Brightwater"] == [ch]
      refute Map.has_key?(after_rename.sub_orgs, "Newclient")
      refute Map.has_key?(after_rename.bucket_orgs, "Newclient")

      assert after_rename.bucket_orgs["Brightwater"] ==
               %{slug: "new_client", name: "Brightwater", scope: "new_client"}
    end
  end
end
