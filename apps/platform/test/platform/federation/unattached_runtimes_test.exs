defmodule Platform.Federation.UnattachedRuntimesTest do
  @moduledoc """
  Task 01a1b84c stage 1: `Federation.list_unattached_runtimes/1` and
  `Federation.unattached_runtime?/1` share one predicate. A runtime is
  unattached when its `agent_id` is NULL, it is not `revoked`, and no agent
  points at it through `agents.runtime_id`.

  Orphans are built by deleting the agent row with `Repo.delete!/1` (the
  `agent_runtimes.agent_id` FK is `on_delete: :nilify_all`), never through
  `AgentData.delete_agent/1`, which revokes.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.Org

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp rid(prefix), do: "gateway-example-#{prefix}-#{System.unique_integer([:positive])}"

  defp attached!(owner, runtime_id) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, _token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "unatt-#{n}", name: "Unattached #{n}", status: "active"},
        %{runtime_id: runtime_id, tool_profile: AgentRuntime.default_tool_profile()}
      )

    {agent, runtime}
  end

  defp orphan!(owner, runtime_id) do
    {agent, runtime} = attached!(owner, runtime_id)
    Repo.delete!(agent)
    runtime = Federation.get_runtime(runtime.id)
    assert runtime.agent_id == nil
    assert runtime.status == "active"
    runtime
  end

  # agent_id NULL, but an agent still points at the row via agents.runtime_id.
  defp pointed_at!(owner, runtime_id) do
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: runtime_id})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)
    n = System.unique_integer([:positive])

    Repo.insert!(
      Agent.changeset(%Agent{}, %{
        slug: "pointer-#{n}",
        name: "Pointer #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
    )

    runtime = Federation.get_runtime(runtime.id)
    assert runtime.agent_id == nil
    runtime
  end

  defp ids(runtimes), do: Enum.map(runtimes, & &1.runtime_id)

  setup do
    %{owner: member!(), admin: root_admin!()}
  end

  test "lists active, suspended and pending agent_id-NULL rows and nothing attached or revoked",
       %{owner: owner, admin: admin} do
    active = orphan!(owner, rid("active"))
    {:ok, suspended} = Federation.suspend_runtime(orphan!(owner, rid("suspended")))
    {:ok, pending} = Federation.register_runtime(owner.id, %{runtime_id: rid("pending")})
    assert pending.status == "pending" and pending.agent_id == nil

    {:ok, revoked} = Federation.revoke_runtime(orphan!(owner, rid("revoked")))
    {attached_agent, attached} = attached!(owner, rid("attached"))
    {:ok, voice} = voice!(owner, attached_agent)
    pointed = pointed_at!(owner, rid("pointed"))

    listed = ids(Federation.list_unattached_runtimes(Scope.for_user(%{id: admin.id})))

    for row <- [active, suspended, pending], do: assert(row.runtime_id in listed)

    for row <- [revoked, attached, voice, pointed] do
      refute row.runtime_id in listed, "#{row.runtime_id} must not be listed"
    end

    assert listed == Enum.sort(listed)

    for row <- [active, suspended, pending], do: assert(Federation.unattached_runtime?(row))

    for row <- [revoked, attached, voice, pointed],
        do: refute(Federation.unattached_runtime?(row))

    refute Federation.unattached_runtime?(nil)
  end

  test "the agents.runtime_id pointer alone keeps a row off the list", %{
    owner: owner,
    admin: admin
  } do
    pointed = pointed_at!(owner, rid("pointer-only"))
    scope = Scope.for_user(%{id: admin.id})

    refute pointed.runtime_id in ids(Federation.list_unattached_runtimes(scope))
    refute Federation.unattached_runtime?(pointed)
  end

  test "a member without agents.manage_all sees none of another user's orphans", %{
    owner: owner
  } do
    orphan!(owner, rid("other"))
    viewer = member!()

    assert Federation.list_unattached_runtimes(Scope.for_user(%{id: viewer.id})) == []
  end

  defp voice!(owner, agent) do
    {:ok, voice, _token} =
      Federation.register_voice_runtime(owner.id, agent, %{runtime_id: rid("voice")})

    assert voice.agent_id == agent.id
    {:ok, voice}
  end
end
