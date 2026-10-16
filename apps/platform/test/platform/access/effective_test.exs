defmodule Platform.Access.EffectiveTest do
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Effective, Grants, Restrictions, Scope, ViewAs}
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  setup do
    org = tenant_org_id("effective")
    user = user!("member")
    member!(user, org, false)
    {:ok, project} = Tasks.create_project(%{name: "effective-#{uniq()}", org_id: org})
    %{org: org, user: user, project: project}
  end

  test "every row agrees with can? and effective sources", ctx do
    {:ok, _} =
      Grants.deny(%{principal: ctx.user, permission: "tasks.write", resource: ctx.project})

    assert {:ok, view} = ViewAs.compute(Scope.system(), {:user, ctx.user.id})
    assert {:ok, rows} = Effective.lines(Scope.system(), {:user, ctx.user.id})
    assert Enum.any?(rows, &(&1.where.id == ctx.project.id and &1.source == "deny"))
    assert Enum.any?(rows, &(&1.where.id == ctx.project.id and &1.source == "role"))
    assert_agreement(rows, view.scope)
  end

  test "a grant and its inherited child name the exact ledger row", ctx do
    guest = user!("guest")
    member!(guest, ctx.org, true)

    {:ok, grant} =
      Grants.grant(%{principal: guest, permission: "tasks.read", resource: ctx.project})

    {:ok, task} = Tasks.create_task(%{project_id: ctx.project.id, title: "Inherited"})

    assert {:ok, rows} = Effective.lines(Scope.system(), {:user, guest.id})

    assert Enum.any?(
             rows,
             &(&1.where.id == ctx.project.id and &1.source == "grant" and &1.grant_id == grant.id)
           )

    assert Enum.any?(
             rows,
             &(&1.where.id == task.id and &1.source == "inherited" and &1.grant_id == grant.id and
                 &1.inherited_from.id == ctx.project.id)
           )

    assert {:ok, scope} = Effective.scope_for({:user, guest.id})
    assert_agreement(rows, scope)
  end

  test "a runtime's capped line names its owner", ctx do
    guest = user!("owner")
    member!(guest, ctx.org, true)

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        name: "Effective agent",
        slug: "effective-agent-#{uniq()}"
      })

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(guest.id, ["task"], %{agent_id: agent.id}, nil)

    {:ok, _} =
      Grants.grant(%{
        principal: {:agent, agent.id},
        permission: "tasks.write",
        resource: ctx.project
      })

    assert {:ok, rows} = Effective.lines(Scope.system(), {:agent, runtime.id})
    line = Enum.find(rows, &(&1.where.id == ctx.project.id and &1.permission == "tasks.write"))
    assert line.source == "capped"
    refute line.allowed
    assert line.owner_id == guest.id
    assert line.note =~ guest.name
    assert {:ok, scope} = Effective.scope_for({:agent, runtime.runtime_id})
    assert_agreement(rows, scope)
  end

  test "restricted channels explain a refusal without claiming an effective allow", ctx do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "effective-#{uniq()}",
        slug: "effective-#{uniq()}",
        kind: "channel",
        org_id: ctx.org
      })

    assert Access.can?(Scope.for_user(ctx.user), "chat.read", space)
    assert {:ok, _} = Restrictions.restrict_space(space, ["admin"])
    assert {:ok, rows} = Effective.lines(Scope.system(), {:user, ctx.user.id})
    line = Enum.find(rows, &(&1.where.id == space.id and &1.permission == "chat.read"))
    assert line.source == "restricted"
    refute line.allowed
    assert {:ok, scope} = Effective.scope_for({:user, ctx.user.id})
    assert_agreement(rows, scope)
  end

  test "inspection authorization is exactly ViewAs authorization", ctx do
    viewer = Scope.for_user(ctx.user)
    assert {:error, refusal} = ViewAs.compute(viewer, {:user, ctx.user.id})
    assert Effective.lines(viewer, {:user, ctx.user.id}) == {:error, refusal}
  end

  test "project manager inventory excludes a guest who only reads another project", ctx do
    manager = user!("project-manager")
    included = user!("project-guest")
    excluded = user!("other-project-guest")
    for user <- [manager, included, excluded], do: member!(user, ctx.org, true)
    {:ok, other} = Tasks.create_project(%{name: "other-#{uniq()}", org_id: ctx.org})

    for permission <- ["access.manage", "tasks.read"] do
      {:ok, _} =
        Grants.grant(%{principal: manager, permission: permission, resource: ctx.project})
    end

    {:ok, _} =
      Grants.grant(%{principal: included, permission: "tasks.read", resource: ctx.project})

    {:ok, _} = Grants.grant(%{principal: excluded, permission: "tasks.read", resource: other})
    viewer = Scope.for_user(manager)
    # ViewAs permits an inspection anywhere in this org; the inventory must
    # additionally require an effective relationship with a managed resource.
    assert {:ok, _} = ViewAs.compute(viewer, {:user, excluded.id})
    subjects = Effective.subjects(viewer)
    assert Enum.any?(subjects, &(&1.target == {:user, included.id}))
    refute Enum.any?(subjects, &(&1.target == {:user, excluded.id}))
  end

  defp assert_agreement(rows, scope) do
    types = %{
      "project" => :project,
      "task" => :task,
      "stack" => :stack,
      "space" => :space,
      "canvas" => :canvas,
      "memory_node" => :memory_node
    }

    for row <- rows do
      assert row.allowed ==
               Access.can?(
                 scope,
                 row.permission,
                 {Map.fetch!(types, row.where.type), row.where.id}
               )

      assert row.allowed == row.source not in ["deny", "capped", "restricted"]
    end
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = uniq()

    Repo.insert!(%User{
      name: "Effective #{tag} #{n}",
      email: "effective-#{n}@example.com",
      oidc_sub: "effective-#{n}"
    })
  end

  defp member!(user, org_id, external) do
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: org_id,
        role: "member",
        external: external
      })
    )
  end
end
