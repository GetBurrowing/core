defmodule Platform.Access.RoleAdminTest do
  @moduledoc """
  Task 01a1a2e4-9265 stage 1: `Platform.Access.RoleAdmin` authorizes every
  custom-role write against `Effective.manages_org?/2` for the role's org,
  refuses permissions the actor does not hold, and `grant_capped/3` lifts an
  owner cap only through the OWNER's assignment.

  Fixture: two sibling tenant orgs `a` and `b` under the root (a tenant
  admin is not a root admin), mirroring `custom_roles_test.exs`.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Caps, Registry, Role, RoleAdmin, RoleAssignment, Roles}
  alias Platform.Access.{RuntimeProfiles, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    n = System.unique_integer([:positive])
    %{a: tenant_org_id("role_admin_a_#{n}"), b: tenant_org_id("role_admin_b_#{n}")}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "role-admin-#{tag}-#{n}@example.com",
      name: "Role Admin #{tag} #{n}",
      oidc_sub: "role-admin-#{tag}-#{n}"
    })
  end

  defp member!(org_id, role \\ "member") do
    u = user!(role)
    join_org!(u, org_id, role)
    u
  end

  defp join_org!(user, org_id, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp runtime!(owner, modules \\ ["prototype"]) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{slug: "role-admin-agent-#{n}", name: "RA Agent #{n}", status: "active"})

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        runtime_id: "role-admin-#{n}",
        status: "active"
      })

    {:ok, _} = RuntimeProfiles.create_for_runtime(runtime, modules, nil)
    {runtime, agent}
  end

  defp role!(org_id, permissions) do
    {:ok, role} =
      Roles.create_custom_role(org_id, %{
        name: "RA role #{System.unique_integer([:positive])}",
        permissions: permissions
      })

    role
  end

  defp counts, do: {Repo.aggregate(Role, :count), Repo.aggregate(RoleAssignment, :count)}

  defp lacked_by(actor) do
    Registry.permission_names()
    |> Enum.reject(
      &(&1 in Registry.module_admin_permissions() or Registry.install_level?(&1) or
          Registry.derived?(&1) or String.starts_with?(&1, "mcp."))
    )
    |> Enum.reject(&Access.holds_anywhere?(actor, &1))
  end

  # ── authorization ───────────────────────────────────────────────────────

  describe "a member actor" do
    test "is forbidden on every write and read", ctx do
      actor = scope(member!(ctx.a))
      target = member!(ctx.a)
      role = role!(ctx.a, %{"prototypes.read" => "membership_org"})
      {:ok, assignment} = Roles.assign(%{principal: target, role: role})
      {runtime, _} = runtime!(member!(ctx.a))
      before = counts()

      assert {:error, :forbidden} =
               RoleAdmin.create_role(actor, ctx.a, %{name: "X", permissions: []})

      assert {:error, :forbidden} = RoleAdmin.update_role(actor, role.key, %{name: "Y"})
      assert {:error, :forbidden} = RoleAdmin.delete_role(actor, role.key)
      assert {:error, :forbidden} = RoleAdmin.assign(actor, role.key, member!(ctx.a))
      assert {:error, :forbidden} = RoleAdmin.unassign(actor, assignment.id)
      assert {:error, :forbidden} = RoleAdmin.list_custom_roles(actor, ctx.a)
      assert {:error, :forbidden} = RoleAdmin.list_assignments_for_role(actor, role.key)

      assert {:error, :forbidden} =
               RoleAdmin.grant_capped(actor, runtime, %{
                 permission: "prototypes.publish",
                 role: {:new, "Publishers", ["prototypes.publish"]},
                 owner?: true,
                 agent?: true
               })

      assert counts() == before
      assert Roles.get_role(role.key).name == role.name
    end
  end

  describe "an admin of org a" do
    test "is forbidden on org b's roles and assignments", ctx do
      actor = scope(member!(ctx.a, "admin"))
      b_role = role!(ctx.b, %{"prototypes.read" => "membership_org"})
      b_member = member!(ctx.b)
      {:ok, b_assignment} = Roles.assign(%{principal: member!(ctx.b), role: b_role})
      {b_runtime, _} = runtime!(member!(ctx.b))
      before = counts()

      assert {:error, :forbidden} =
               RoleAdmin.create_role(actor, ctx.b, %{name: "X", permissions: []})

      assert {:error, :forbidden} = RoleAdmin.update_role(actor, b_role.key, %{name: "Y"})
      assert {:error, :forbidden} = RoleAdmin.delete_role(actor, b_role.key)
      assert {:error, :forbidden} = RoleAdmin.assign(actor, b_role.key, b_member)
      assert {:error, :forbidden} = RoleAdmin.unassign(actor, b_assignment.id)
      assert {:error, :forbidden} = RoleAdmin.list_custom_roles(actor, ctx.b)
      assert {:error, :forbidden} = RoleAdmin.list_assignments_for_role(actor, b_role.key)

      assert {:error, :forbidden} =
               RoleAdmin.grant_capped(actor, b_runtime, %{
                 permission: "prototypes.publish",
                 role: {:new, "Publishers", ["prototypes.publish"]},
                 owner?: true,
                 agent?: true
               })

      assert counts() == before
    end

    test "creates, lists, edits, assigns, unassigns and deletes in org a", ctx do
      actor = scope(member!(ctx.a, "admin"))

      assert {:ok, role} =
               RoleAdmin.create_role(actor, ctx.a, %{
                 name: "Publishers",
                 permissions: ["prototypes.publish", "prototypes.read"]
               })

      assert role.org_id == ctx.a

      assert role.permissions == %{
               "prototypes.publish" => "membership_org",
               "prototypes.read" => "membership_org"
             }

      assert {:ok, [listed]} = RoleAdmin.list_custom_roles(actor, ctx.a)
      assert listed.key == role.key

      first = member!(ctx.a)
      {_runtime, agent} = runtime!(member!(ctx.a))
      assert {:ok, a1} = RoleAdmin.assign(actor, role.key, first)
      assert {:ok, a2} = RoleAdmin.assign(actor, role.key, agent)

      assert {:ok, [r1, r2]} = RoleAdmin.list_assignments_for_role(actor, role.key)
      assert {r1.assignment.id, r1.principal_type, r1.name} == {a1.id, "user", first.name}
      assert {r2.assignment.id, r2.principal_type, r2.name} == {a2.id, "agent", agent.name}

      assert {:ok, renamed} = RoleAdmin.update_role(actor, role.key, %{name: "Prototype team"})
      assert renamed.name == "Prototype team"
      assert renamed.permissions == role.permissions

      assert {:ok, _} = RoleAdmin.unassign(actor, a1.id)
      assert {:ok, [only]} = RoleAdmin.list_assignments_for_role(actor, role.key)
      assert only.assignment.id == a2.id

      assert {:ok, _} = RoleAdmin.delete_role(actor, role.key)
      assert Roles.get_role(role.key) == nil
    end

    test "an edit keeps an existing non-default rule on a permission that stays checked", ctx do
      actor = scope(member!(ctx.a, "admin"))
      role = role!(ctx.a, %{"prototypes.read" => "all", "files.read" => "membership_org"})

      assert {:ok, updated} =
               RoleAdmin.update_role(actor, role.key, %{
                 permissions: ["prototypes.read", "prototypes.publish"]
               })

      assert updated.permissions == %{
               "prototypes.read" => "all",
               "prototypes.publish" => "membership_org"
             }
    end

    test "a built-in update returns :builtin and leaves the row unchanged", ctx do
      actor = scope(member!(ctx.a, "admin"))

      for key <- ~w(admin member guest) do
        before = Roles.get_role(key)

        assert {:error, :builtin} =
                 RoleAdmin.update_role(actor, key, %{
                   name: "Hacked",
                   permissions: ["prototypes.publish"]
                 })

        assert {:error, :builtin} = RoleAdmin.delete_role(actor, key)
        assert {:error, :builtin_not_assignable} = RoleAdmin.assign(actor, key, member!(ctx.a))
        assert Roles.get_role(key) == before
      end

      refute Map.has_key?(Roles.get_role("member").permissions, "prototypes.publish")
    end

    test "a built-in update by a member is :forbidden before Roles' gate", ctx do
      actor = scope(member!(ctx.a))
      assert {:error, :forbidden} = RoleAdmin.update_role(actor, "member", %{name: "Hacked"})
    end

    test "a permission the actor does not hold is :exceeds_actor, on create and on update",
         ctx do
      actor = scope(member!(ctx.a, "admin"))
      assert [lacked | _] = lacked_by(actor)
      before = counts()

      assert {:error, {:exceeds_actor, [^lacked]}} =
               RoleAdmin.create_role(actor, ctx.a, %{
                 name: "Too wide",
                 permissions: ["prototypes.read", lacked]
               })

      assert counts() == before

      role = role!(ctx.a, %{"prototypes.read" => "membership_org"})

      assert {:error, {:exceeds_actor, [^lacked]}} =
               RoleAdmin.update_role(actor, role.key, %{
                 permissions: ["prototypes.read", lacked]
               })

      assert Roles.get_role(role.key).permissions == %{"prototypes.read" => "membership_org"}
    end

    test "a malformed or missing assignment id is :not_found", ctx do
      actor = scope(member!(ctx.a, "admin"))
      assert {:error, :not_found} = RoleAdmin.unassign(actor, "higginshigginsxx")
      assert {:error, :not_found} = RoleAdmin.unassign(actor, Ecto.UUID.generate())
    end
  end

  describe "module-admin permissions" do
    test "are refused even for a root admin who holds them" do
      root = acme_org_id()
      actor = scope(member!(root, "admin"))
      assert Access.holds_anywhere?(actor, "tasks.manage")
      before = counts()

      assert {:error, {:module_admin, ["tasks.manage"]}} =
               RoleAdmin.create_role(actor, root, %{
                 name: "Plan approvers #{System.unique_integer([:positive])}",
                 permissions: ["tasks.read", "tasks.manage"]
               })

      assert counts() == before
    end
  end

  # ── grant_capped ────────────────────────────────────────────────────────

  describe "grant_capped/3" do
    setup ctx do
      admin = member!(ctx.a, "admin")
      owner = member!(ctx.a)
      {runtime, agent} = runtime!(owner)

      assert %{"prototype" => [%{permission: "prototypes.publish"}]} = Caps.for_runtime(runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", runtime)

      %{actor: scope(admin), owner: owner, runtime: runtime, agent: agent}
    end

    defp grant(ctx, attrs) do
      RoleAdmin.grant_capped(
        ctx.actor,
        ctx.runtime,
        Map.merge(%{permission: "prototypes.publish", owner?: true, agent?: true}, attrs)
      )
    end

    test "existing role: assigns the owner and the agent and lifts the cap", ctx do
      role = role!(ctx.a, %{"prototypes.publish" => "membership_org"})

      assert {:ok, %{role: %Role{key: key}, assignments: [owner_row, agent_row]}} =
               grant(ctx, %{role: {:existing, role.key}})

      assert key == role.key
      assert {owner_row.principal_type, owner_row.principal_id} == {"user", ctx.owner.id}
      assert {agent_row.principal_type, agent_row.principal_id} == {"agent", ctx.agent.id}

      assert Caps.for_runtime(ctx.runtime) == %{}
      assert :ok = ToolAuthorization.authorize("prototype_publish", ctx.runtime)

      # Already assigned counts as success and writes nothing.
      before = counts()
      assert {:ok, %{assignments: [again, _]}} = grant(ctx, %{role: {:existing, role.key}})
      assert again.id == owner_row.id
      assert counts() == before
    end

    test "new role: created in the owner's org with membership_org rules", ctx do
      {roles_before, _} = counts()

      assert {:ok, %{role: role, assignments: [_, _]}} =
               grant(ctx, %{role: {:new, "Publishers", ["prototypes.publish", "prototypes.read"]}})

      assert Repo.aggregate(Role, :count) == roles_before + 1
      assert role.org_id == ctx.a

      assert role.permissions == %{
               "prototypes.publish" => "membership_org",
               "prototypes.read" => "membership_org"
             }

      assert :ok = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
    end

    test "agent?: false assigns the owner only, which still lifts the cap", ctx do
      role = role!(ctx.a, %{"prototypes.publish" => "membership_org"})

      assert {:ok, %{assignments: [only]}} =
               grant(ctx, %{role: {:existing, role.key}, agent?: false})

      assert only.principal_type == "user"
      assert :ok = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
    end

    test "owner?: false is :owner_required and writes nothing", ctx do
      role = role!(ctx.a, %{"prototypes.publish" => "membership_org"})
      before = counts()

      assert {:error, :owner_required} =
               grant(ctx, %{role: {:existing, role.key}, owner?: false})

      assert {:error, :owner_required} =
               grant(ctx, %{role: {:new, "Publishers", ["prototypes.publish"]}, owner?: false})

      assert counts() == before
      assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
    end

    test "a role lacking the permission, or another org's role, is :role_lacks_permission",
         ctx do
      lacking = role!(ctx.a, %{"prototypes.read" => "membership_org"})
      foreign = role!(ctx.b, %{"prototypes.publish" => "membership_org"})
      before = counts()

      assert {:error, :role_lacks_permission} = grant(ctx, %{role: {:existing, lacking.key}})
      assert {:error, :role_lacks_permission} = grant(ctx, %{role: {:existing, foreign.key}})
      assert {:error, :role_lacks_permission} = grant(ctx, %{role: {:existing, "member"}})

      assert {:error, :role_lacks_permission} =
               grant(ctx, %{role: {:new, "Readers", ["prototypes.read"]}})

      assert counts() == before
    end

    test "a new role the actor could not create rolls back the whole grant", ctx do
      assert [lacked | _] = lacked_by(ctx.actor)
      before = counts()

      assert {:error, {:exceeds_actor, [^lacked]}} =
               grant(ctx, %{role: {:new, "Too wide", ["prototypes.publish", lacked]}})

      assert counts() == before
    end

    test "unassigning the owner restores the cap", ctx do
      role = role!(ctx.a, %{"prototypes.publish" => "membership_org"})
      assert {:ok, %{assignments: [owner_row, _]}} = grant(ctx, %{role: {:existing, role.key}})
      assert :ok = ToolAuthorization.authorize("prototype_publish", ctx.runtime)

      assert {:ok, _} = RoleAdmin.unassign(ctx.actor, owner_row.id)

      assert %{"prototype" => [%{permission: "prototypes.publish"}]} =
               Caps.for_runtime(ctx.runtime)

      assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", ctx.runtime)
    end
  end

  # ── read-only lookups (task 01a1a399) ────────────────────────────────

  describe "list_builtin_roles/0" do
    test "is exactly admin, member and guest, all built-in, ordered by key", _ctx do
      assert [
               %Role{key: "admin", builtin: true},
               %Role{key: "member", builtin: true},
               %Role{key: "guest", builtin: true}
             ] = RoleAdmin.list_builtin_roles()
    end
  end

  describe "assignable_principals/2" do
    test "returns org a's internal members and the agents their members own", ctx do
      actor = scope(member!(ctx.a, "admin"))
      owner = member!(ctx.a)
      other = member!(ctx.a)
      b_member = member!(ctx.b)
      external = member!(ctx.a)
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: ctx.a})
      {_, agent} = runtime!(owner)

      assert {:ok, %{users: users, agents: agents}} =
               RoleAdmin.assignable_principals(actor, ctx.a)

      user_ids = Enum.map(users, fn {id, _, _} -> id end)
      assert owner.id in user_ids
      assert other.id in user_ids
      refute b_member.id in user_ids
      refute external.id in user_ids

      assert [{agent_id, _}] = agents
      assert agent_id == agent.id
    end

    test "is forbidden for a member actor and for an org-b admin querying org a", ctx do
      member = scope(member!(ctx.a))
      b_admin = scope(member!(ctx.b, "admin"))

      assert {:error, :forbidden} = RoleAdmin.assignable_principals(member, ctx.a)
      assert {:error, :forbidden} = RoleAdmin.assignable_principals(b_admin, ctx.a)
    end
  end

  describe "agents_owned_by/1" do
    test "returns exactly the owner's agent names, [] for an owner with none", ctx do
      owner = member!(ctx.a)
      {_, agent} = runtime!(owner)
      nobody = member!(ctx.a)

      assert RoleAdmin.agents_owned_by(owner.id) == [agent.name]
      assert RoleAdmin.agents_owned_by(nobody.id) == []
    end
  end
end
