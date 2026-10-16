defmodule Platform.Access.SpaceRestrictionsTest do
  use Platform.DataCase, async: false
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures
  alias Platform.Access
  alias Platform.Access.{Grants, Restrictions, Roles, Scope}
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Access.RuntimeProfiles
  alias Platform.Chat.CanvasAccess
  alias Platform.Repo
  alias Platform.Tenancy

  setup do
    root = Tenancy.get_org!(acme_org_id())
    sub = Tenancy.get_org!(tenant_org_id("restriction_sub"))
    [admin, member, subadmin] = for _ <- 1..3, do: create_user!()
    plain_member!(admin, root, "admin")
    plain_member!(member, root)
    plain_member!(subadmin, sub, "admin")
    finance = channel!(%{org_id: root.id})
    p = add_user!(finance.id, member.id)
    add_user!(finance.id, admin.id)

    agent =
      Repo.insert!(%Agent{
        slug: "restriction-#{System.unique_integer([:positive])}",
        name: "Agent",
        status: "active"
      })

    add_agent!(finance.id, agent.id)

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: member.id,
        runtime_id: "restriction-#{System.unique_integer([:positive])}",
        status: "active"
      })

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(runtime, AgentRuntime.default_tool_profile(), nil)

    %{
      root: root,
      sub: sub,
      admin: admin,
      member: member,
      subadmin: subadmin,
      finance: finance,
      canvas: canvas!(finance.id, p.id),
      runtime: runtime
    }
  end

  defp scope(user), do: Scope.for_user(Platform.Accounts.get_user(user.id))

  test "live deny beats direct allow, applies down to canvases, and custom holding restores read",
       c do
    a = scope(c.admin)
    m = scope(c.member)
    r = Scope.for_runtime(c.runtime)
    for s <- [a, m, r], do: assert(Access.can?(s, "chat.read", c.finance.id))

    assert {:ok, _, _} =
             CanvasAccess.fetch_for_viewer(c.canvas.id, {:agent, c.runtime.agent_id},
               access_scope: r
             )

    assert {:ok, _} = Restrictions.restrict_space(c.finance, ["admin"], c.admin.id)
    assert Access.can?(a, "chat.read", c.finance.id)
    for s <- [m, r, scope(c.subadmin)], do: refute(Access.can?(s, "chat.read", c.finance.id))
    refute Access.can?(m, "canvas.read", c.canvas)
    refute Access.can?(m, "canvas.read", c.canvas.id)
    refute Access.can?(m, "files.read", c.finance)

    assert {:error, :not_found} =
             CanvasAccess.fetch_for_viewer(c.canvas.id, {:agent, c.runtime.agent_id},
               access_scope: r
             )

    assert {:ok, _} =
             Grants.grant(%{
               principal: {:user, c.member.id},
               permission: "chat.read",
               resource: {:space, c.finance.id},
               effect: "allow"
             })

    refute Access.can?(scope(c.member), "chat.read", c.finance.id)
    assert Access.restricted_space_ids(m, [c.finance.id]) == MapSet.new([c.finance.id])
    assert Access.restricted_space_ids(a, [c.finance.id]) == MapSet.new()
    refute c.finance.id in Access.permitted_ids(m, "chat.read")
    {:ok, role} = Roles.create_custom_role(c.root, %{name: "Finance"})
    {:ok, _} = Restrictions.restrict_space(c.finance, ["admin", role.key], c.admin.id)
    {:ok, _} = Roles.assign(%{principal: c.member, role: role})
    refute Access.can?(m, "chat.read", c.finance.id)
    assert Access.can?(scope(c.member), "chat.read", c.finance.id)
    {:ok, _} = Restrictions.unrestrict_space(c.finance)
    for s <- [a, m, r], do: assert(Access.can?(s, "chat.read", c.finance.id))
  end

  test "only channels and same-org custom roles are accepted, replacing atomically", c do
    for kind <- ~w(dm group execution meeting system) do
      space =
        Repo.insert!(%Platform.Chat.Space{
          kind: kind,
          name: kind,
          slug: "restriction-#{kind}-#{System.unique_integer([:positive])}"
        })

      assert {:error, :unsupported_kind} =
               Restrictions.restrict_space(space, ["admin"], c.admin.id)
    end

    {:ok, other} = Roles.create_custom_role(c.sub, %{name: "Other"})
    {:ok, _} = Restrictions.restrict_space(c.finance, ["admin"], c.admin.id)

    assert {:error, :invalid_role} =
             Restrictions.restrict_space(c.finance, [other.key], c.admin.id)

    assert {:error, :invalid_role} =
             Restrictions.restrict_space(c.finance, ["missing"], c.admin.id)

    assert {:error, :not_found} =
             Restrictions.restrict_space("malformed-id", ["admin"], c.admin.id)

    assert Restrictions.restricted_role_keys(c.finance.id) == ["admin"]
    legacy = channel!()
    {:ok, root_role} = Roles.create_custom_role(c.root, %{name: "Legacy"})
    assert {:ok, _} = Restrictions.restrict_space(legacy, [root_role.key], c.admin.id)
  end

  test "batch marking reads once, honors ancestor holdings, and preserves unrelated module ids",
       c do
    child = channel!(%{org_id: c.sub.id})
    {:ok, _} = Restrictions.restrict_space(child, ["admin"], c.admin.id)
    {:ok, _} = Restrictions.restrict_space(c.finance, ["admin"], c.admin.id)
    m = scope(c.member)
    a = scope(c.admin)
    s = scope(c.subadmin)
    assert Access.restricted_space_ids(a, [child.id, c.finance.id]) == MapSet.new()
    assert Access.restricted_space_ids(s, [child.id, c.finance.id]) == MapSet.new([c.finance.id])
    assert Access.permitted_ids(m, "tasks.read") == Scope.permitted_ids(m, "tasks.read")
    handler = "restriction-query-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler,
      [:platform, :repo, :query],
      fn _, _, _, _ -> send(caller, :restriction_query) end,
      nil
    )

    try do
      assert Access.restricted_space_ids(m, [child.id, c.finance.id]) ==
               MapSet.new([child.id, c.finance.id])

      assert_receive :restriction_query
      refute_receive :restriction_query
    after
      :telemetry.detach(handler)
    end

    assert Access.can?(Scope.system(), "chat.read", c.finance.id)
  end

  test "external runtime guest marker is not an assigned role", c do
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: c.member.id, org_id: c.root.id})
    r = Scope.for_runtime(c.runtime)
    assert Scope.guest?(r)
    refute Access.holds_role?(r, "guest", c.root.id)
    {:ok, _} = Restrictions.restrict_space(c.finance, ["guest"], c.admin.id)
    refute Access.can?(r, "chat.read", c.finance.id)
  end

  test "role deletion refuses while it restricts a space, including the last role", c do
    {:ok, role} = Roles.create_custom_role(c.root, %{name: "Finance"})
    {:ok, _} = Restrictions.restrict_space(c.finance, [role.key], c.admin.id)
    assert {:error, {:role_restricts_spaces, [id]}} = Roles.delete_custom_role(role)
    assert id == c.finance.id
    refute Access.can?(scope(c.member), "chat.read", c.finance.id)
    {:ok, _} = Restrictions.unrestrict_space(c.finance)
    assert {:ok, _} = Roles.delete_custom_role(role)
  end

  test "raw database cascade removes the last restriction; context deletion is guarded", c do
    {:ok, role} = Roles.create_custom_role(c.root, %{name: "Finance"})
    {:ok, _} = Restrictions.restrict_space(c.finance, [role.key], c.admin.id)
    refute Access.can?(scope(c.member), "chat.read", c.finance.id)
    Repo.delete!(role)
    assert Restrictions.restricted_role_keys(c.finance.id) == []
    assert Access.can?(scope(c.member), "chat.read", c.finance.id)
  end
end
