defmodule Platform.Access.CustomRolesTest do
  @moduledoc """
  Task 01a1386e-59d1 stage 1: custom roles as per-org permission sets, and
  role assignments, inside `Platform.Access`
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`).

  Fixture: the root org, two sibling tenant orgs `a` and `b` under it.
  Permissions used are ones the built-in `member` role does NOT carry
  (`tasks.promote`, `prototypes.publish`), so a custom role's contribution
  is visible against a member's base Scope.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Registry, Role, RoleAssignment, Roles, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    n = System.unique_integer([:positive])

    %{
      root: acme_org_id(),
      a: tenant_org_id("custom_roles_a_#{n}"),
      b: tenant_org_id("custom_roles_b_#{n}")
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "custom-roles-#{tag}-#{n}@example.com",
      name: "Custom Roles #{tag} #{n}",
      oidc_sub: "custom-roles-#{tag}-#{n}"
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

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "custom-roles-agent-#{n}", name: "CR Agent #{n}", status: "active"})
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp role!(org_id, name, permissions) do
    {:ok, role} = Roles.create_custom_role(org_id, %{name: name, permissions: permissions})
    role
  end

  defp ok!({:ok, value}), do: value

  defp permission_errors(changeset) do
    changeset
    |> traverse_errors(fn {message, _opts} -> message end)
    |> Map.get(:permissions, [])
  end

  defp keys(scope, org_id), do: Map.get(scope.role_keys, org_id, MapSet.new())

  # ── custom roles ────────────────────────────────────────────────────────

  describe "custom roles" do
    test "create, rename and delete; listed only in their own org", ctx do
      role = role!(ctx.a, "Finance", %{"tasks.promote" => "membership_org"})

      assert "custom:" <> uuid = role.key
      assert Platform.UUID.valid?(uuid)
      refute role.builtin
      assert role.org_id == ctx.a
      assert Roles.custom_key?(role.key)

      listed = ctx.a |> Roles.list_roles() |> Enum.map(& &1.key)
      assert listed == ["admin", "guest", "member", role.key]
      refute role.key in Enum.map(Roles.list_roles(ctx.b), & &1.key)

      # A name is unique per org, case-insensitively; another org may reuse it.
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Roles.create_custom_role(ctx.a, %{name: "FINANCE"})

      assert Keyword.has_key?(errors, :name)
      assert {:ok, _} = Roles.create_custom_role(ctx.b, %{name: "Finance"})

      renamed = ok!(Roles.update_custom_role(role, %{name: "Finance team"}))
      assert renamed.name == "Finance team"
      assert renamed.key == role.key
      assert Repo.get_by!(Role, key: role.key).name == "Finance team"

      # The key and org are never caller-writable.
      moved = ok!(Roles.update_custom_role(role.key, %{key: "admin", org_id: ctx.b}))
      assert moved.key == role.key and moved.org_id == ctx.a

      assert {:ok, _} = Roles.delete_custom_role(role.key)
      assert Roles.get_role(role.key) == nil
      assert {:error, :role_not_found} = Roles.delete_custom_role(role.key)
    end

    test "an install-level, derived, unregistered or kind-admission permission is refused",
         ctx do
      [install | _] = Registry.install_level_permissions()

      assert {:error, %Ecto.Changeset{} = cs} =
               Roles.create_custom_role(ctx.a, %{name: "Root", permissions: %{install => "all"}})

      assert permission_errors(cs) |> Enum.any?(&(&1 =~ "install-level"))

      for permission <- Registry.derived_permissions() do
        assert {:error, %Ecto.Changeset{}} =
                 Roles.create_custom_role(ctx.a, %{
                   name: "Derived #{permission}",
                   permissions: %{permission => "all"}
                 })
      end

      assert {:error, %Ecto.Changeset{}} =
               Roles.create_custom_role(ctx.a, %{
                 name: "Bogus",
                 permissions: %{"no.such" => "all"}
               })

      # member 2's `implicit_or_participant` is a valid built-in rule, but not
      # one of the three a custom role may use.
      assert {:error, %Ecto.Changeset{} = cs} =
               Roles.create_custom_role(ctx.a, %{
                 name: "Implicit",
                 permissions: %{"chat.read" => "implicit_or_participant"}
               })

      assert permission_errors(cs) |> Enum.any?(&(&1 =~ "custom role may not use"))

      # The three accepted values, alone and as a list.
      assert {:ok, _} =
               Roles.create_custom_role(ctx.a, %{
                 name: "Ok",
                 permissions: %{
                   "tasks.read" => "all",
                   "files.read" => "membership_org",
                   "canvas.read" => ["participant_spaces", "membership_org"]
                 }
               })

      # And an update cannot sneak one in either.
      role = role!(ctx.a, "Later", %{})

      assert {:error, %Ecto.Changeset{}} =
               Roles.update_custom_role(role, %{permissions: %{install => "all"}})
    end

    test "built-in roles are immutable through the API" do
      admin = Roles.get_role("admin")
      before = Repo.all(from(r in Role, where: r.builtin, order_by: r.key))

      for key <- Registry.builtin_role_keys() do
        assert {:error, :builtin} = Roles.update_custom_role(key, %{name: "Hacked"})
        assert {:error, :builtin} = Roles.delete_custom_role(key)
      end

      assert {:error, :builtin} = Roles.update_custom_role(admin, %{permissions: %{}})
      assert {:error, :builtin} = Roles.delete_custom_role(admin)
      assert Repo.all(from(r in Role, where: r.builtin, order_by: r.key)) == before

      # The DB keeps a custom row org-owned too.
      assert_raise Postgrex.Error, ~r/access_roles_custom_org_check/, fn ->
        Repo.query!(
          "INSERT INTO access_roles (key, name, builtin, permissions, inserted_at, updated_at) " <>
            "VALUES ('custom:orphan', 'Orphan', false, '{}', now(), now())"
        )
      end

    end
  end

  # ── assignments ─────────────────────────────────────────────────────────

  describe "assign/1" do
    test "refuses a non-member, an external member, a built-in role and a missing agent", ctx do
      role = role!(ctx.a, "Ops", %{"tasks.promote" => "membership_org"})

      stranger = member!(ctx.b)
      assert {:error, :no_membership} = Roles.assign(%{principal: stranger, role: role})

      guest = user!("guest")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: ctx.a})
      assert {:error, :no_membership} = Roles.assign(%{principal: guest, role: role})

      insider = member!(ctx.a)

      for key <- Registry.builtin_role_keys() do
        assert {:error, :builtin_not_assignable} =
                 Roles.assign(%{principal: insider, role: key})
      end

      assert {:error, :agent_not_found} =
               Roles.assign(%{principal: {:agent, Ecto.UUID.generate()}, role: role})

      assert {:error, :role_not_found} = Roles.assign(%{principal: insider, role: "custom:nope"})
      assert {:error, :org_mismatch} = Roles.assign(%{principal: insider, role: role, org_id: ctx.b})
      assert {:error, :invalid_principal} = Roles.assign(%{principal: "someone", role: role})

      # This member never creates memberships.
      assert Repo.aggregate(from(m in OrgMembership, where: m.user_id == ^stranger.id), :count) ==
               1

      assert Repo.aggregate(RoleAssignment, :count) == 0

      # Positive control: the same call for a member succeeds.
      assert {:ok, %RoleAssignment{source: "manual"}} =
               Roles.assign(%{principal: insider, role: role})

      assert {:error, %Ecto.Changeset{}} = Roles.assign(%{principal: insider, role: role})
    end

    test "two assignments: both keys held and both permission sets unioned", ctx do
      user = member!(ctx.a)
      finance = role!(ctx.a, "Finance", %{"tasks.promote" => "membership_org"})
      ops = role!(ctx.a, "Ops", %{"prototypes.publish" => "membership_org", "tasks.read" => "all"})

      # Custom roles that exist but are not assigned change nothing.
      base = scope(user)
      refute Map.has_key?(base.permissions, "tasks.promote")
      refute Map.has_key?(base.permissions, "prototypes.publish")
      assert keys(base, ctx.a) == MapSet.new(["member"])

      a1 = ok!(Roles.assign(%{principal: user, role: finance}))
      a2 = ok!(Roles.assign(%{principal: {:user, user.id}, role: ops.key}))

      s = scope(user)
      assert keys(s, ctx.a) == MapSet.new(["member", finance.key, ops.key])
      assert s.permissions["tasks.promote"] == [ctx.a]
      assert s.permissions["prototypes.publish"] == [ctx.a]
      assert s.permissions["tasks.read"] == :all
      assert Access.can?(s, "tasks.promote", ctx.a)
      refute Access.can?(s, "tasks.promote", ctx.b)

      # Everything else is the base Scope's.
      assert Map.drop(s.permissions, ["tasks.promote", "prototypes.publish"]) == base.permissions
      assert s.grants == base.grants

      assert [a1.id, a2.id] == user |> Roles.list_assignments_for() |> Enum.map(& &1.id)

      # Unassigning both returns exactly the base Scope.
      {:ok, _} = Roles.unassign(a1)
      {:ok, _} = Roles.unassign(a2.id)
      assert scope(user) == base
      assert {:error, :not_found} = Roles.unassign(a1.id)
    end

    test "zero assignments and zero custom roles: permissions and grants equal the base",
         ctx do
      user = member!(ctx.a)
      join_org!(user, ctx.root, "admin")
      base = scope(user)

      # An unrelated user's assignment changes nothing for this one.
      role = role!(ctx.a, "Elsewhere", %{"tasks.promote" => "all"})
      other = member!(ctx.a)
      ok!(Roles.assign(%{principal: other, role: role}))

      s = scope(user)
      assert s.permissions == base.permissions
      assert s.grants == base.grants
      assert s.role_keys == base.role_keys
    end

    test "a guest with an assignment holds the key but gains no permission", ctx do
      user = member!(ctx.a)
      role = role!(ctx.a, "Finance", %{"tasks.promote" => "membership_org", "tasks.read" => "all"})
      ok!(Roles.assign(%{principal: user, role: role}))

      # Positive control: while internal, the role widens.
      assert scope(user).permissions["tasks.promote"] == [ctx.a]

      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: ctx.b})
      s = scope(user)

      assert Scope.guest?(s)
      assert MapSet.member?(keys(s, ctx.a), role.key)
      assert Access.holds_role?(s, role.key, ctx.a)
      refute Map.has_key?(s.permissions, "tasks.promote")
      refute Map.has_key?(s.permissions, "tasks.read")
    end

    test "an assignment counts only while the user has a membership in its org", ctx do
      user = member!(ctx.a)
      role = role!(ctx.a, "Finance", %{"tasks.promote" => "membership_org"})
      ok!(Roles.assign(%{principal: user, role: role}))
      assert Access.holds_role?(scope(user), role.key, ctx.a)

      Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^user.id))
      s = scope(user)
      refute Access.holds_role?(s, role.key, ctx.a)
      refute Map.has_key?(s.permissions, "tasks.promote")
    end

    test "an agent assignment: the key and the role's grants, never the role's permissions",
         ctx do
      owner = member!(ctx.a)
      agent = agent!()
      runtime = %AgentRuntime{agent_id: agent.id, owner_user_id: owner.id, allowed_bundles: []}
      other = %AgentRuntime{agent_id: agent!().id, owner_user_id: owner.id, allowed_bundles: []}
      role = role!(ctx.a, "Finance bots", %{"tasks.promote" => "all"})

      {:ok, project} =
        Tasks.create_project(%{name: "cr-#{System.unique_integer([:positive])}", org_id: ctx.a})

      ok!(Grants.grant(%{principal: {:role, role.key}, permission: "tasks.read", resource: project}))

      base = Scope.for_runtime(runtime)
      assert base.role_keys == %{}
      refute Access.holds_role?(base, role.key, ctx.a)
      refute Access.can?(base, "tasks.read", {:project, project.id})

      ok!(Roles.assign(%{principal: runtime, role: role}))
      s = Scope.for_runtime(runtime)

      assert s.role_keys == %{ctx.a => MapSet.new([role.key])}
      assert Access.holds_role?(s, role.key, ctx.a)
      assert s.permissions == base.permissions
      assert [%Grant{principal_role_key: key}] = s.grants
      assert key == role.key
      assert Access.can?(s, "tasks.read", {:project, project.id})

      # Another agent, and the owner, hold nothing from it.
      refute Access.holds_role?(Scope.for_runtime(other), role.key, ctx.a)
      refute Access.holds_role?(scope(owner), role.key, ctx.a)
      assert [%RoleAssignment{principal_type: "agent"}] = Roles.list_assignments_for(agent)
    end

    test "a role-principal grant on a custom role reaches its holders only", ctx do
      holder = member!(ctx.a)
      bystander = member!(ctx.a)
      role = role!(ctx.a, "Readers", %{})

      {:ok, project} =
        Tasks.create_project(%{name: "cr-#{System.unique_integer([:positive])}", org_id: ctx.a})

      ok!(Grants.deny(%{principal: {:role, role.key}, permission: "tasks.read", resource: project}))

      # Positive control: before the assignment the member reads the project.
      assert Access.can?(scope(holder), "tasks.read", {:project, project.id})

      ok!(Roles.assign(%{principal: holder, role: role}))
      refute Access.can?(scope(holder), "tasks.read", {:project, project.id})
      assert Access.can?(scope(bystander), "tasks.read", {:project, project.id})
    end

    test "delete_custom_role/1 cascades its assignments and its role grants", ctx do
      user = member!(ctx.a)
      role = role!(ctx.a, "Doomed", %{"tasks.promote" => "membership_org"})
      keep = role!(ctx.a, "Kept", %{})

      {:ok, project} =
        Tasks.create_project(%{name: "cr-#{System.unique_integer([:positive])}", org_id: ctx.a})

      ok!(Roles.assign(%{principal: user, role: role}))
      ok!(Roles.assign(%{principal: user, role: keep}))
      ok!(Grants.grant(%{principal: {:role, role.key}, permission: "tasks.read", resource: project}))
      ok!(Grants.grant(%{principal: {:role, keep.key}, permission: "tasks.read", resource: project}))

      count = fn schema, field, key ->
        Repo.aggregate(from(r in schema, where: field(r, ^field) == ^key), :count)
      end

      assert count.(RoleAssignment, :role_key, role.key) == 1
      assert count.(Grant, :principal_role_key, role.key) == 1

      {:ok, _} = Roles.delete_custom_role(role)

      assert count.(RoleAssignment, :role_key, role.key) == 0
      assert count.(Grant, :principal_role_key, role.key) == 0
      assert count.(RoleAssignment, :role_key, keep.key) == 1
      assert count.(Grant, :principal_role_key, keep.key) == 1

      s = scope(user)
      refute MapSet.member?(keys(s, ctx.a), role.key)
      refute Map.has_key?(s.permissions, "tasks.promote")
    end
  end

  # ── holds_role?/3 ───────────────────────────────────────────────────────

  describe "holds_role?/3" do
    test "holds through an ancestor org, never from a sibling or a descendant", ctx do
      root_admin = member!(ctx.root, "admin")
      a_admin = member!(ctx.a, "admin")

      # Root admin holds `admin` over the root and over its sub-orgs.
      s = scope(root_admin)
      assert Access.holds_role?(s, "admin", ctx.root)
      assert Access.holds_role?(s, "admin", ctx.a)
      assert Access.holds_role?(s, ["guest", "admin"], ctx.b)
      assert Access.holds_role?(s, "admin", nil)
      refute Access.holds_role?(s, "member", ctx.a)

      # A sub-org admin holds it over its own org only.
      t = scope(a_admin)
      assert Access.holds_role?(t, "admin", ctx.a)
      refute Access.holds_role?(t, "admin", ctx.b)
      refute Access.holds_role?(t, "admin", ctx.root)
      refute Access.holds_role?(t, "admin", nil)

      # A custom role held in the root reaches sub-orgs; one held in `a` does not reach `b`.
      root_role = role!(ctx.root, "Auditors", %{})
      a_role = role!(ctx.a, "Finance", %{})
      ok!(Roles.assign(%{principal: root_admin, role: root_role}))
      ok!(Roles.assign(%{principal: a_admin, role: a_role}))

      assert Access.holds_role?(scope(root_admin), root_role.key, ctx.b)
      assert Access.holds_role?(scope(a_admin), a_role.key, ctx.a)
      refute Access.holds_role?(scope(a_admin), a_role.key, ctx.b)
      refute Access.holds_role?(scope(a_admin), a_role.key, ctx.root)
    end

    test "empty inputs, malformed ids and the system scope", ctx do
      user = member!(ctx.a, "admin")
      s = scope(user)

      refute Access.holds_role?(s, [], ctx.a)
      refute Access.holds_role?(s, "admin", "not-a-uuid")
      refute Access.holds_role?(s, "admin", Ecto.UUID.generate())
      refute Access.holds_role?(Scope.for_user(nil), "admin", ctx.a)
      assert Access.holds_role?(Scope.system(), "anything", ctx.a)
    end
  end
end
