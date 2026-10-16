defmodule Platform.Access.ImpactTest do
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Access.{Change, Grant, Grants, Impact, Scope}
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  setup do
    org = tenant_org_id("impact")
    {:ok, project} = Tasks.create_project(%{name: "impact-#{uniq()}", org_id: org})
    %{org: org, project: project}
  end

  test "losses name a cross-org explicit grantee and their owner-capped runtime", ctx do
    user = user!("cross-org")
    member!(user, tenant_org_id("impact-other"), "guest")
    agent = Platform.RuntimeProfileFixtures.runtime!(user.id, ["task"], %{}, nil)

    {:ok, grant} =
      Grants.grant(%{principal: user, permission: "tasks.read", resource: ctx.project})

    {:ok, task} = Tasks.create_task(%{project_id: ctx.project.id, title: "Inherited task"})
    counts = counts()

    assert Platform.Access.can?(Scope.for_user(user), "tasks.read", ctx.project)
    assert Platform.Access.can?(Scope.for_runtime(agent), "tasks.read", ctx.project)
    assert {:ok, impact} = Impact.diff(Scope.system(), [%{action: "revoke", id: grant.id}])

    assert MapSet.new(Enum.map(impact.loses, &{&1.type, &1.id})) ==
             MapSet.new([{"user", user.id}, {"agent", agent.id}])

    assert Enum.any?(impact.loses, &(&1.id == user.id and &1.name == user.name))

    assert Enum.any?(
             impact.inherited,
             &(&1.id == agent.id and &1.resource.id == task.id and &1.effect == "loses")
           )

    assert impact.count == 2
    assert counts() == counts
    assert Repo.get!(Grant, grant.id)
  end

  test "agent grant conflicts name the owner and exclude unrelated capped runtimes", ctx do
    owner = user!("owner")
    member!(owner, ctx.org, "guest")

    agent =
      Repo.insert!(%Platform.Agents.Agent{slug: "impact-agent-#{uniq()}", name: "Impact agent"})

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(owner.id, ["task"], %{agent_id: agent.id}, nil)

    assert {:ok, impact} =
             Impact.diff(Scope.system(), [
               %{
                 action: "grant",
                 principal: {:agent, runtime.agent_id},
                 permission: "tasks.write",
                 resource: {:project, ctx.project.id}
               }
             ])

    assert [%{kind: "capped", owner_id: owner_id, owner_name: owner_name}] = impact.conflicts
    assert owner_id == owner.id
    assert owner_name == owner.name
    assert impact.gains == []
  end

  test "undo preview restores effective access but leaves persisted rows intact", ctx do
    user = user!("guest")
    member!(user, ctx.org, "guest")

    {:ok, grant} =
      Grants.grant(%{principal: user, permission: "tasks.read", resource: ctx.project})

    change = Repo.one!(from(c in Change, order_by: [desc: c.id], limit: 1))
    counts = counts()

    assert {:ok, impact} = Impact.diff(Scope.system(), change.id)
    assert Enum.any?(impact.loses, &(&1.id == user.id))
    assert Repo.get!(Grant, grant.id)
    assert counts() == counts
  end

  test "a role deny finds an external participant and agents", ctx do
    user = user!("external")
    member!(user, ctx.org, "guest")

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "impact-#{uniq()}",
        slug: "impact-#{uniq()}",
        kind: "channel",
        org_id: ctx.org
      })

    {:ok, _} =
      Platform.Chat.add_participant(space.id, %{
        participant_id: user.id,
        participant_type: "user",
        joined_at: DateTime.utc_now()
      })

    runtime = Platform.RuntimeProfileFixtures.runtime!(user.id, ["messaging"], %{}, nil)
    assert Platform.Access.can?(Scope.for_user(user), "chat.read", space)

    assert {:ok, impact} =
             Impact.diff(Scope.system(), [
               %{
                 action: "deny",
                 principal: {:role, "guest"},
                 permission: "chat.read",
                 resource: {:space, space.id}
               }
             ])

    assert Enum.any?(impact.loses, &(&1.id == user.id))
    assert Enum.any?(impact.loses, &(&1.id == runtime.id))
  end

  test "records time and SQL query count at 50 and 200 candidate people", ctx do
    for size <- [50, 200] do
      for _ <- 1..(size - if(size == 200, do: 50, else: 0)) do
        user = user!("benchmark")
        member!(user, ctx.org, "member")
      end

      key = {__MODULE__, make_ref()}
      Process.put(key, 0)
      handler = "impact-#{uniq()}"
      caller = self()

      :ok =
        :telemetry.attach(
          handler,
          [:platform, :repo, :query],
          fn _, _, _, _ ->
            if self() == caller, do: Process.put(key, Process.get(key, 0) + 1)
          end,
          nil
        )

      try do
        {elapsed, result} =
          :timer.tc(fn ->
            Impact.diff(Scope.system(), [
              %{
                action: "deny",
                principal: {:role, "member"},
                permission: "tasks.read",
                resource: {:project, ctx.project.id}
              }
            ])
          end)

        assert {:ok, impact} = result
        assert length(impact.loses) >= size

        IO.puts(
          "IMPACT_BENCH candidates=#{size} elapsed_us=#{elapsed} queries=#{Process.get(key)}"
        )
      after
        :telemetry.detach(handler)
        Process.delete(key)
      end
    end
  end

  defp counts,
    do:
      {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count),
       Repo.aggregate(Platform.Audit.Event, :count)}

  defp uniq, do: System.unique_integer([:positive])

  defp user!(name) do
    n = uniq()

    Repo.insert!(%User{
      name: "Impact #{name} #{n}",
      email: "impact-#{n}@example.com",
      oidc_sub: "impact-#{n}"
    })
  end

  defp member!(user, org_id, role) do
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: org_id,
        role: if(role == "guest", do: "member", else: role),
        external: role == "guest"
      })
    )
  end
end
