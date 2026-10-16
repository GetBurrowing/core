defmodule Platform.Access.AgentManagementTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Agents, RuntimeProfiles, Scope}
  alias Platform.Agents.Agent
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.RoleAssignment
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  test "a member federates only for self and cannot mutate another member's runtime or pin" do
    root = Repo.get!(Org, acme_org_id())
    owner = World.create_user!()
    other = World.create_user!()
    World.plain_member!(owner, root)
    World.plain_member!(other, root)

    owner_scope = Scope.for_user(owner)
    other_scope = Scope.for_user(other)
    agent = agent!()

    assert {:ok, runtime} =
             Federation.register_runtime(owner_scope, %{
               runtime_id: unique_runtime_id(),
               agent_id: agent.id,
               owner_user_id: other.id
             })

    assert runtime.owner_user_id == owner.id
    assert Agents.manage?(owner_scope, runtime)
    refute Agents.manage?(other_scope, runtime)
    assert Agents.may_federate?(other_scope)

    original = Repo.get!(Platform.Agents.AgentRuntime, runtime.id)
    profile = RuntimeProfiles.get(runtime)

    assert {:error, :unauthorized} = Federation.suspend_runtime(other_scope, runtime)
    assert {:error, :unauthorized} = Federation.revoke_runtime(other_scope, runtime)
    assert {:error, :unauthorized} = Federation.generate_runtime_token(other_scope, runtime)

    assert {:error, :unauthorized} =
             RuntimeProfiles.set_tool_profile(other_scope, runtime, ["task"])

    assert {:error, :unauthorized} =
             RuntimeProfiles.restrict(other_scope, runtime, %{"tasks.read" => "all"})

    assert Repo.get!(Platform.Agents.AgentRuntime, runtime.id) == original
    assert RuntimeProfiles.get(runtime) == profile

    assert {:error, :unauthorized} = Roles.assign_role("designer", agent.id, actor: other_scope)
    assert Repo.get_by(RoleAssignment, role_key: "designer") == nil
    assert {:ok, _} = Roles.assign_role("designer", agent.id, actor: owner_scope)
    assert {:error, :unauthorized} = Roles.unassign_role("designer", actor: other_scope)
    assert Repo.get_by(RoleAssignment, role_key: "designer").agent_id == agent.id
    assert :ok = Roles.unassign_role("designer", actor: owner_scope)

    assert {:ok, _} = RuntimeProfiles.set_tool_profile(owner_scope, runtime, ["task"])
    assert {:ok, _} = RuntimeProfiles.restrict(owner_scope, runtime, %{"tasks.read" => "all"})
    assert {:ok, _} = Federation.suspend_runtime(owner_scope, runtime)
  end

  test "root admin manages another owner's runtime and ownerless agent; guest cannot federate" do
    root = Repo.get!(Org, acme_org_id())
    owner = World.create_user!()
    World.plain_member!(owner, root)
    guest = World.create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: root.id})

    owner_scope = Scope.for_user(owner)
    root_scope = Scope.for_user(root_admin!())
    guest_scope = Scope.for_user(guest)
    agent = agent!()
    ownerless = agent!()

    assert {:ok, runtime} =
             Federation.register_runtime(owner_scope, %{
               runtime_id: unique_runtime_id(),
               agent_id: agent.id
             })

    assert Agents.manage?(root_scope, runtime)
    assert Agents.may_create_ownerless?(root_scope)
    refute Agents.may_federate?(guest_scope)
    refute Agents.manage?(guest_scope, runtime)
    refute Agents.manage?(owner_scope, ownerless)
    assert Agents.manage?(root_scope, ownerless)

    assert {:error, :unauthorized} =
             Federation.register_runtime(guest_scope, %{runtime_id: unique_runtime_id()})

    assert {:ok, _} = Roles.assign_role("designer", ownerless.id, actor: root_scope)
    assert {:error, :unauthorized} = Roles.unassign_role("designer", actor: owner_scope)
    assert :ok = Roles.unassign_role("designer", actor: root_scope)
  end

  test "sub-org admin manages its members but cannot release another org's agent" do
    tenant = Repo.get!(Org, tenant_org_id("soylent"))
    root = Repo.get!(Org, acme_org_id())
    admin = World.create_user!()
    owner = World.create_user!()
    outsider = World.create_user!()
    World.plain_member!(admin, tenant, "admin")
    World.plain_member!(owner, tenant)
    World.plain_member!(outsider, root)

    scope = Scope.for_user(admin)
    owned_agent = agent!()
    outsider_agent = agent!()

    {:ok, owned_runtime} =
      Federation.register_runtime(Scope.for_user(owner), %{
        runtime_id: unique_runtime_id(),
        agent_id: owned_agent.id
      })

    {:ok, outsider_runtime} =
      Federation.register_runtime(Scope.for_user(outsider), %{
        runtime_id: unique_runtime_id(),
        agent_id: outsider_agent.id
      })

    assert Agents.manage?(scope, owned_runtime)
    refute Agents.manage?(scope, outsider_runtime)
    assert {:ok, _} = Federation.suspend_runtime(scope, owned_runtime)
    assert {:error, :unauthorized} = Federation.suspend_runtime(scope, outsider_runtime)

    :ok = Roles.unassign_role("designer")
    assert {:ok, _} = Roles.assign_role("designer", owned_agent.id, actor: scope)

    assert {:error, :unauthorized} =
             Roles.set_override("design.critique", outsider_agent.id, actor: scope)

    assert {:ok, _} = Roles.set_override("design.critique", owned_agent.id, actor: scope)

    assert {:error, :unauthorized} =
             Roles.set_override("design.critique", outsider_agent.id, actor: scope)

    assert :ok = Roles.clear_override("design.critique", actor: scope)
    assert :ok = Roles.unassign_role("designer", actor: scope)
  end

  defp agent! do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "managed-agent-#{n}", name: "Managed #{n}"})
      |> Repo.insert()

    agent
  end

  defp unique_runtime_id, do: "managed-#{System.unique_integer([:positive])}"
end
