defmodule Platform.Agents.DmAccessTest do
  @moduledoc """
  Per-agent DM permission (task 01a19776 stage 1): the `agents.dm_policy`
  column, the `agent_dm_allowed_users` list, and `Platform.Agents.DmAccess`.

  Named mutations this suite must catch, and the test that goes red:

    * drop the owner clause in `permitted?/2` -> "an owner is always allowed,
      even without agents-module access"
    * drop the admin clause -> "an agents.manage_all admin is always allowed"
    * remove the migration default -> "an existing agent inserted without
      dm_policy reads everyone"
    * consult the list when the policy is "admins" -> "a named member is
      refused under admins"
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Agents, as: AgentAccess
  alias Platform.Access.Grants
  alias Platform.Access.Scope
  alias Platform.Agents.{Agent, AgentDmAllowedUser, AgentRuntime, DmAccess}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo
  alias Platform.Tenancy.Org

  setup do
    root = Repo.get!(Org, acme_org_id())
    tenant = Repo.get!(Org, tenant_org_id("initech"))

    # The agent's owner and a tenant admin who holds agents.manage_all over
    # the owner's org (the builtin admin role) but is not an install admin.
    owner = World.create_user!(%{name: "Owen Owner"})
    World.plain_member!(owner, tenant)
    tenant_admin = World.create_user!()
    World.plain_member!(tenant_admin, tenant, "admin")

    member = World.create_user!(%{name: "Mel Member"})
    World.plain_member!(member, tenant)
    other = World.create_user!(%{name: "Pia Plain"})
    World.plain_member!(other, tenant)

    agent = agent!()
    runtime!(agent, owner)

    %{
      root: root,
      tenant: tenant,
      owner: owner,
      tenant_admin: tenant_admin,
      root_admin: root_admin!(),
      member: member,
      other: other,
      agent: agent
    }
  end

  describe "the migration default" do
    test "an existing agent inserted without dm_policy reads everyone", %{member: member} do
      id = Platform.Types.UUIDv7.generate()
      now = DateTime.utc_now()
      n = System.unique_integer([:positive])

      # insert_all bypasses the schema default, so only the column default
      # can fill dm_policy here.
      {1, _} =
        Repo.insert_all("agents", [
          %{
            id: Ecto.UUID.dump!(id),
            slug: "dm-legacy-#{n}",
            name: "Legacy #{n}",
            status: "active",
            inserted_at: now,
            updated_at: now
          }
        ])

      assert Repo.get!(Agent, id).dm_policy == "everyone"
      assert DmAccess.permitted?(member.id, id)
    end

    test "the database refuses a policy outside the three values", %{agent: agent} do
      assert_raise Postgrex.Error, ~r/agents_dm_policy_check/, fn ->
        Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [dm_policy: "nobody"])
      end
    end

    test "the generic agent changeset cannot write dm_policy", %{agent: agent} do
      {:ok, saved} = agent |> Agent.changeset(%{dm_policy: "admins"}) |> Repo.update()
      assert saved.dm_policy == "everyone"
      assert Repo.reload!(agent).dm_policy == "everyone"
    end
  end

  describe "everyone" do
    test "any internal member may DM", %{member: member, agent: agent} do
      assert agent.dm_policy == "everyone"
      assert DmAccess.permitted?(member.id, agent)
      assert DmAccess.permitted?(member.id, agent.id)
    end
  end

  describe "admins" do
    setup %{agent: agent, root_admin: root_admin} do
      %{agent: set!(agent, root_admin, "admins")}
    end

    test "a plain member is refused", %{member: member, agent: agent} do
      refute DmAccess.permitted?(member.id, agent)
      refute DmAccess.permitted?(member.id, agent.id)
    end

    test "an agents.manage_all admin is always allowed", %{tenant_admin: admin, agent: agent} do
      refute admin.id in DmAccess.owner_ids(agent)
      assert DmAccess.permitted?(admin.id, agent)
    end

    test "an install/root admin is allowed", %{root_admin: root_admin, agent: agent} do
      assert DmAccess.permitted?(root_admin.id, agent)
    end

    test "an owner is always allowed, even without agents-module access", %{tenant: tenant} do
      # The agents module denied to the owner, as module_gating_acceptance_test
      # does: manage?/2 then refuses them, so only the owner clause admits them.
      owner = World.create_user!()
      World.plain_member!(owner, tenant)
      agent = agent!()
      runtime!(agent, owner)
      agent = set!(agent, root_admin!(), "admins")

      {:ok, _} =
        Grants.deny(%{
          principal: {:user, owner.id},
          permission: "agents",
          resource: {:module, tenant}
        })

      refute AgentAccess.manage?(Scope.for_user(owner), agent)
      assert DmAccess.permitted?(owner.id, agent)
    end

    test "an owner reached through the legacy agents.runtime_id is allowed" do
      owner = World.create_user!()
      agent = agent!()
      runtime = runtime!(nil, owner)

      agent =
        agent
        |> Agent.changeset(%{runtime_id: runtime.id})
        |> Repo.update!()
        |> set!(root_admin!(), "admins")

      assert DmAccess.owner_ids(agent) == [owner.id]
      assert DmAccess.permitted?(owner.id, agent)
    end

    test "a named member is refused under admins", %{
      member: member,
      agent: agent,
      root_admin: root_admin
    } do
      agent = set!(agent, root_admin, "specific", [member.id])
      assert DmAccess.permitted?(member.id, agent)

      agent = set!(agent, root_admin, "admins")
      assert DmAccess.allowed_user_ids(agent) == [member.id]
      refute DmAccess.permitted?(member.id, agent)
    end
  end

  describe "specific" do
    setup %{agent: agent, root_admin: root_admin, member: member} do
      %{agent: set!(agent, root_admin, "specific", [member.id])}
    end

    test "a named member is allowed and an unnamed one refused", %{
      member: member,
      other: other,
      agent: agent
    } do
      assert DmAccess.permitted?(member.id, agent)
      refute DmAccess.permitted?(other.id, agent)
    end

    test "the owner and an admin are allowed though not named", %{
      owner: owner,
      tenant_admin: admin,
      agent: agent
    } do
      refute owner.id in DmAccess.allowed_user_ids(agent)
      refute admin.id in DmAccess.allowed_user_ids(agent)

      assert DmAccess.permitted?(owner.id, agent)
      assert DmAccess.permitted?(admin.id, agent)
    end

    test "switching to admins and back keeps the list", %{
      member: member,
      agent: agent,
      root_admin: root_admin
    } do
      agent = set!(agent, root_admin, "admins")
      refute DmAccess.permitted?(member.id, agent)

      agent = set!(agent, root_admin, "specific")
      assert DmAccess.permitted?(member.id, agent)
    end
  end

  describe "permitted?/2 inputs" do
    test "an unknown or malformed agent, or a malformed user, is refused", %{member: member} do
      refute DmAccess.permitted?(member.id, Platform.Types.UUIDv7.generate())
      refute DmAccess.permitted?(member.id, "not-a-uuid")
      refute DmAccess.permitted?(member.id, "sixteen-chars-xx")
      refute DmAccess.permitted?(member.id, nil)
      refute DmAccess.permitted?(nil, agent!())
    end

    test "a malformed user id is refused under a restrictive policy", %{
      agent: agent,
      root_admin: root_admin
    } do
      agent = set!(agent, root_admin, "specific", [])
      refute DmAccess.permitted?("not-a-uuid", agent)
    end
  end

  describe "set_policy/4" do
    test "a plain member is forbidden and nothing is written", %{
      member: member,
      other: other,
      agent: agent
    } do
      assert {:error, :forbidden} =
               DmAccess.set_policy(Scope.for_user(member), agent, "specific", [other.id])

      assert Repo.reload!(agent).dm_policy == "everyone"
      assert DmAccess.allowed_user_ids(agent) == []
    end

    test "the owner and an admin may set it", %{
      owner: owner,
      tenant_admin: admin,
      member: member,
      agent: agent
    } do
      assert {:ok, %Agent{dm_policy: "admins"}} =
               DmAccess.set_policy(Scope.for_user(owner), agent, "admins")

      assert {:ok, %Agent{dm_policy: "specific"}} =
               DmAccess.set_policy(Scope.for_user(admin), agent, "specific", [member.id])

      assert Repo.reload!(agent).dm_policy == "specific"
      assert DmAccess.allowed_user_ids(agent) == [member.id]
    end

    test "an invalid policy is a changeset error", %{root_admin: root_admin, agent: agent} do
      assert {:error, %Ecto.Changeset{} = cs} =
               DmAccess.set_policy(Scope.for_user(root_admin), agent, "nobody")

      assert %{dm_policy: [_]} = errors_on(cs)
      assert Repo.reload!(agent).dm_policy == "everyone"
    end

    test "an external user in the list is refused and nothing is written", %{
      root: root,
      root_admin: root_admin,
      member: member,
      agent: agent
    } do
      external = World.external_user!(root)

      assert {:error, %Ecto.Changeset{} = cs} =
               DmAccess.set_policy(Scope.for_user(root_admin), agent, "specific", [
                 member.id,
                 external.id
               ])

      assert %{allowed_user_ids: ["cannot include external users"]} = errors_on(cs)
      assert Repo.reload!(agent).dm_policy == "everyone"
      assert DmAccess.allowed_user_ids(agent) == []
    end

    test "a malformed or unknown id in the list is refused", %{
      root_admin: root_admin,
      agent: agent
    } do
      scope = Scope.for_user(root_admin)

      assert {:error, %Ecto.Changeset{}} =
               DmAccess.set_policy(scope, agent, "specific", ["not-a-uuid"])

      assert {:error, %Ecto.Changeset{}} =
               DmAccess.set_policy(scope, agent, "specific", [Platform.Types.UUIDv7.generate()])

      assert Repo.aggregate(
               from(a in AgentDmAllowedUser, where: a.agent_id == ^agent.id),
               :count
             ) == 0
    end

    test "a list replaces the previous one and duplicates collapse", %{
      root_admin: root_admin,
      member: member,
      other: other,
      agent: agent
    } do
      scope = Scope.for_user(root_admin)
      {:ok, agent} = DmAccess.set_policy(scope, agent, "specific", [member.id, member.id])
      assert DmAccess.allowed_user_ids(agent) == [member.id]

      {:ok, agent} = DmAccess.set_policy(scope, agent, "specific", [other.id])
      assert DmAccess.allowed_user_ids(agent) == [other.id]

      {:ok, agent} = DmAccess.set_policy(scope, agent, "specific", [])
      assert DmAccess.allowed_user_ids(agent) == []
    end
  end

  describe "summary/1" do
    test "names the policy, the owners and the listed people", %{
      root_admin: root_admin,
      owner: owner,
      member: member,
      agent: agent
    } do
      assert %{policy: "everyone", owners: [%{id: owner_id, name: "Owen Owner"}], people: []} =
               DmAccess.summary(agent)

      assert owner_id == owner.id

      agent = set!(agent, root_admin, "specific", [member.id])

      assert %{policy: "specific", people: [%{id: member_id, name: "Mel Member"}]} =
               DmAccess.summary(agent)

      assert member_id == member.id
    end

    test "an ownerless agent has no owners" do
      assert %{owners: []} = DmAccess.summary(agent!())
    end
  end

  test "policies/0 lists the three values" do
    assert DmAccess.policies() == ~w(everyone admins specific)
  end

  defp agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "dm-access-#{n}", name: "DM Access #{n}"})
    |> Repo.insert!()
  end

  defp runtime!(agent, owner) do
    Repo.insert!(%AgentRuntime{
      agent_id: agent && agent.id,
      owner_user_id: owner.id,
      status: "active",
      runtime_id: "dm-access-rt-#{System.unique_integer([:positive])}"
    })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp set!(agent, admin, policy, user_ids \\ nil) do
    {:ok, agent} = DmAccess.set_policy(Scope.for_user(admin), agent, policy, user_ids)
    agent
  end
end
