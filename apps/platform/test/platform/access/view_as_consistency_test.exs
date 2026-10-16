defmodule Platform.Access.ViewAsConsistencyTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Access
  alias Platform.Access.{Scope, ViewAs}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.{Chat, Repo, Tenancy}
  alias Platform.Tenancy.OrgMembership

  test "an owner's visible channel is absent for a runtime outside its roster" do
    org = Tenancy.get_org_by_slug!("acme")
    n = System.unique_integer([:positive])

    viewer =
      Repo.insert!(%User{
        name: "Viewer",
        email: "view-root-#{n}@example.com",
        oidc_sub: "vr-#{n}"
      })

    owner =
      Repo.insert!(%User{
        name: "Owner",
        email: "view-owner-#{n}@example.com",
        oidc_sub: "vo-#{n}"
      })

    Repo.insert!(%OrgMembership{user_id: viewer.id, org_id: org.id, role: "admin"})
    Repo.insert!(%OrgMembership{user_id: owner.id, org_id: org.id, role: "member"})
    agent = Repo.insert!(%Agent{name: "Roster agent", slug: "view-roster-#{n}"})

    runtime =
      Platform.RuntimeProfileFixtures.runtime!(
        owner.id,
        ["messaging"],
        %{agent_id: agent.id},
        nil
      )

    {:ok, channel} =
      Chat.create_space(%{
        name: "Roster channel",
        slug: "view-roster-#{n}",
        kind: "channel",
        org_id: org.id
      })

    viewer_scope = Scope.for_user(viewer)
    resource = {:space, channel.id}

    assert Access.can?(Scope.for_user(owner), "chat.read", resource)
    refute Access.can?(Scope.for_runtime(runtime), "chat.read", resource)
    {:ok, before} = ViewAs.compute(viewer_scope, {:agent, runtime.id})
    refute Enum.any?(before.resources.channels, &(&1.id == channel.id))

    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        joined_at: DateTime.utc_now()
      })

    assert Access.can?(Scope.for_runtime(runtime), "chat.read", resource)
    {:ok, after_join} = ViewAs.compute(viewer_scope, {:agent, runtime.id})
    assert Enum.any?(after_join.resources.channels, &(&1.id == channel.id))
  end
end
