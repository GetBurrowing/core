defmodule Platform.Access.RuntimeScopeCapTest do
  use Platform.DataCase, async: true

  alias Platform.Access
  alias Platform.Access.{Grant, Grants, Scope}
  alias Platform.Tasks

  import Platform.TenancyFixtures
  import Platform.RuntimeProfileFixtures

  test "a compatibility roster cannot keep tools after the owner loses membership" do
    owner = root_admin!()
    runtime = runtime!(owner.id, ["space"])
    assert Access.holds_anywhere?(Scope.for_runtime(runtime), "chat.read")
    assert Platform.Federation.ToolAuthorization.authorize("space_list", runtime) == :ok

    memberships = Platform.Repo.all(Ecto.assoc(owner, :org_memberships))
    Enum.each(memberships, &Platform.Repo.delete!/1)

    scope = Scope.for_runtime(runtime)
    assert Scope.carries?(scope, "chat.read")
    assert Platform.Access.RuntimeProfiles.tool_profile(runtime) == ["space"]
    refute Access.holds_anywhere?(scope, "chat.read")

    assert Platform.Federation.ToolAuthorization.authorize("space_list", runtime) ==
             {:error, :forbidden}
  end

  test "for_runtime applies an owner's deny after a positive control" do
    owner = root_admin!()

    {:ok, project} =
      Tasks.create_project(%{
        name: "scope-cap-#{System.unique_integer([:positive])}",
        org_id: acme_org_id()
      })

    runtime = runtime!(owner.id, ["task"])
    resource = {:project, project.id}

    assert Access.can?(Scope.for_runtime(runtime), "tasks.read", resource)

    assert {:ok, _} =
             Grants.deny(%{principal: owner, permission: "tasks.read", resource: resource})

    refute Access.can?(Scope.for_runtime(runtime), "tasks.read", resource)
  end

  test "permission values intersect and a missing owner permission disappears" do
    own = %Scope{
      actor: :agent,
      permissions: %{"tasks.read" => :all, "canvas.read" => ["a", "b"], "vault.use" => :all}
    }

    owner = %Scope{
      actor: :owner,
      permissions: %{"tasks.read" => ["q"], "canvas.read" => ["b", "c"]}
    }

    capped = Scope.intersect(own, owner)

    assert capped.permissions == %{"tasks.read" => ["q"], "canvas.read" => ["b"]}
    assert Access.can?(capped, "tasks.read", "q")
    refute Access.can?(capped, "tasks.read", "other")
    refute Access.can?(capped, "vault.use")
  end

  test "owner denies and agent denies both narrow the cap" do
    q = Ecto.UUID.generate()
    r = Ecto.UUID.generate()
    s = Ecto.UUID.generate()

    owner_deny = %Grant{
      permission: "tasks.read",
      effect: "deny",
      resource_type: "project",
      resource_id: q
    }

    agent_deny = %Grant{
      permission: "tasks.read",
      effect: "deny",
      resource_type: "project",
      resource_id: r
    }

    own = %Scope{actor: :agent, permissions: %{"tasks.read" => :all}, grants: [agent_deny]}
    owner = %Scope{actor: :owner, permissions: %{"tasks.read" => :all}, grants: [owner_deny]}
    capped = Scope.intersect(own, owner)

    assert Access.can?(capped, "tasks.read", s)
    refute Access.can?(capped, "tasks.read", q)
    refute Access.can?(capped, "tasks.read", r)
  end

  test "an owner allow does not add a permission the agent lacks" do
    q = Ecto.UUID.generate()

    allow = %Grant{
      permission: "tasks.read",
      effect: "allow",
      resource_type: "project",
      resource_id: q
    }

    own = %Scope{actor: :agent, permissions: %{}}
    owner = %Scope{actor: :owner, permissions: %{}, grants: [allow]}

    refute Access.can?(Scope.intersect(own, owner), "tasks.read", q)
  end
end
