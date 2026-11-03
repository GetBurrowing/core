defmodule Platform.Access.CapsTest do
  @moduledoc """
  Task 01a1a2e4-9265 stage 1: `Platform.Access.Caps` reports exactly the
  bundle permissions the owner cap removes, and agrees with
  `ToolAuthorization.authorize/2`, because both read the same runtime Scope.

  Fixture: a tenant org under the root (a tenant admin is not a root admin,
  so it holds no module-admin permission). Builtin `member` carries
  `prototypes.read` but not `prototypes.publish`; builtin `admin` carries
  both.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Access.{Caps, Roles, RuntimeProfiles}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolAuthorization
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup do
    n = System.unique_integer([:positive])
    %{org: tenant_org_id("caps_#{n}")}
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "caps-#{tag}-#{n}@example.com",
      name: "Caps #{tag} #{n}",
      oidc_sub: "caps-#{tag}-#{n}"
    })
  end

  defp member!(org_id, role) do
    u = user!(role)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org_id, role: role})
    |> Repo.insert!()

    u
  end

  defp runtime!(owner, modules) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{slug: "caps-agent-#{n}", name: "Caps Agent #{n}", status: "active"})

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        runtime_id: "caps-#{n}",
        status: "active"
      })

    {:ok, _} = RuntimeProfiles.create_for_runtime(runtime, modules, nil)
    {runtime, agent}
  end

  defp publisher!(org_id) do
    {:ok, role} =
      Roles.create_custom_role(org_id, %{
        name: "Prototype publisher #{System.unique_integer([:positive])}",
        permissions: %{"prototypes.publish" => "membership_org"}
      })

    role
  end

  test "a member owner caps prototypes.publish, and only that", %{org: org} do
    owner = member!(org, "member")
    {runtime, _agent} = runtime!(owner, ["prototype", "task"])

    assert Caps.for_runtime(runtime) == %{
             "prototype" => [%{permission: "prototypes.publish", label: "Publish prototypes"}]
           }

    assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", runtime)
    assert :ok = ToolAuthorization.authorize("prototype_versions", runtime)
  end

  test "an admin owner caps nothing", %{org: org} do
    owner = member!(org, "admin")
    {runtime, _agent} = runtime!(owner, ["prototype"])

    assert Caps.for_runtime(runtime) == %{}
    assert :ok = ToolAuthorization.authorize("prototype_publish", runtime)
  end

  test "a bundle not in the profile is never reported", %{org: org} do
    owner = member!(org, "member")
    {runtime, _agent} = runtime!(owner, ["task"])

    assert Caps.for_runtime(runtime) == %{}
  end

  test "a role assigned to the OWNER lifts the cap on the next call", %{org: org} do
    owner = member!(org, "member")
    {runtime, _agent} = runtime!(owner, ["prototype"])
    assert %{"prototype" => _} = Caps.for_runtime(runtime)

    {:ok, _} = Roles.assign(%{principal: owner, role: publisher!(org)})

    assert Caps.for_runtime(runtime) == %{}
    assert :ok = ToolAuthorization.authorize("prototype_publish", runtime)
  end

  test "a role assigned to the AGENT only leaves the cap in place", %{org: org} do
    owner = member!(org, "member")
    {runtime, agent} = runtime!(owner, ["prototype"])

    {:ok, _} = Roles.assign(%{principal: agent, role: publisher!(org)})

    assert %{"prototype" => [%{permission: "prototypes.publish"}]} = Caps.for_runtime(runtime)
    assert {:error, :forbidden} = ToolAuthorization.authorize("prototype_publish", runtime)
  end

  test "a runtime with no profile row caps nothing", %{org: org} do
    owner = member!(org, "member")
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "caps-np-#{n}", name: "No profile #{n}", status: "active"})

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        runtime_id: "caps-np-#{n}",
        status: "active"
      })

    assert Caps.for_runtime(runtime) == %{}
  end

  test "a scope with no own/owner sides caps nothing" do
    assert Caps.from_scope(%Platform.Access.Scope{}, ["prototype"]) == %{}
  end

  describe "owner/1" do
    test "the owner and the owner's scope org", %{org: org} do
      owner = member!(org, "member")
      {runtime, _agent} = runtime!(owner, ["prototype"])

      assert %{user: %User{id: id}, org_id: ^org} = Caps.owner(runtime)
      assert id == owner.id
    end

    test "an ownerless runtime has no user and no org" do
      # agent_runtimes.owner_user_id is NOT NULL, so an ownerless runtime is
      # only ever an in-memory struct.
      assert Caps.owner(%AgentRuntime{owner_user_id: nil}) == %{user: nil, org_id: nil}
    end
  end
end
