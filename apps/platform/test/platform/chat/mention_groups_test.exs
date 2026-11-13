defmodule Platform.Chat.MentionGroupsTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  alias Platform.Chat.MentionGroups

  setup do
    org = Platform.Tenancy.get_org!(Platform.TenancyFixtures.tenant_org_id("mention-groups"))
    admin = create_user!()
    plain_member!(admin, org, "admin")
    member = create_user!()
    plain_member!(member, org)
    %{org: org, admin: admin, member: member}
  end

  test "exact-org admin manages groups; members can only discover", c do
    assert {:error, :forbidden} = MentionGroups.create_group(c.member, c.org.id, %{name: "Ops"})
    assert {:ok, group} = MentionGroups.create_group(c.admin, c.org.id, %{name: " Ops ", members: [%{type: "user", id: c.member.id}]})
    assert group.name == "Ops"
    assert [%{type: "user", id: id}] = group.members
    assert id == c.member.id
    assert {:ok, [_]} = MentionGroups.list_groups(c.member, c.org.id)
    assert {:error, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "ops"})
    assert {:ok, renamed} = MentionGroups.update_group(c.admin, group.id, %{name: "Operations"})
    assert renamed.id == group.id
    assert {:ok, _} = MentionGroups.archive_group(c.admin, group.id)
    assert {:ok, []} = MentionGroups.list_groups(c.member, c.org.id)
    assert {:ok, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "operations"})
  end

  test "external and foreign targets fail closed", c do
    external = external_user!(c.org)
    stranger = create_user!()
    assert {:error, :forbidden} = MentionGroups.list_groups(external, c.org.id)
    assert {:error, :forbidden} = MentionGroups.create_group(external, c.org.id, %{name: "Bad"})
    for bad <- [%{type: "user", id: stranger.id}, %{type: "system", id: c.member.id}, %{type: "agent", id: "bad"}] do
      assert {:error, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "Bad", members: [bad]})
    end
    assert {:ok, candidates} = MentionGroups.list_candidates(c.admin, c.org.id)
    refute Enum.any?(candidates, &(&1.id == stranger.id))
    assert {:error, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "[bad]"})
  end

  test "foreign admins and archived organizations cannot manage", c do
    foreign = Platform.Tenancy.get_org!(Platform.TenancyFixtures.tenant_org_id("mention-foreign"))
    assert {:error, :forbidden} = MentionGroups.create_group(c.admin, foreign.id, %{name: "Bad"})
    assert {:ok, group} = MentionGroups.create_group(c.admin, c.org.id, %{name: "Active"})
    Platform.Repo.update!(Ecto.Changeset.change(c.org, archived_at: DateTime.utc_now()))
    assert {:error, :forbidden} = MentionGroups.list_groups(c.admin, c.org.id)
    assert {:error, :forbidden} = MentionGroups.update_group(c.admin, group.id, %{name: "No"})
  end

  test "agent candidates require existing participation in an organization space", c do
    n = System.unique_integer([:positive])
    agent = Platform.Repo.insert!(Platform.Agents.Agent.changeset(%Platform.Agents.Agent{}, %{name: "A", slug: "group-a-#{n}"}))
    assert {:error, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "Agents", members: [%{type: "agent", id: agent.id}]})
    space = channel!(%{org_id: c.org.id})
    add_agent!(space.id, agent.id)
    assert {:ok, candidates} = MentionGroups.list_candidates(c.admin, c.org.id)
    assert Enum.any?(candidates, &(&1.type == "agent" and &1.id == agent.id))
    assert {:ok, _} = MentionGroups.create_group(c.admin, c.org.id, %{name: "Agents", members: [%{type: "agent", id: agent.id}]})
  end
end
