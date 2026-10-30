defmodule Platform.Calendar.ConsentConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.{AgentAccess, AgentGrant, Consent, Event}
  alias Platform.Access.{Scope, RuntimeProfile, RuntimeProfiles}
  alias Platform.Memory.{Briefing, Insights.Briefings}

  test "independent connections serialize stale approvals, duplicate approve and revoke" do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])
    user = Platform.ExternalUserFixtures.create_user!()
    Platform.ExternalUserFixtures.plain_member!(user, Platform.Tenancy.get_org_by_slug!("globex"))
    agent = Repo.insert!(%Platform.Agents.Agent{name: "Consent race", slug: "consent-race-#{n}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "consent-race-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions: RuntimeProfiles.translated_permissions(["context_read"])
    })

    owner = Scope.for_user(user)
    scope = Scope.for_runtime(runtime)

    try do
      {:ok, _} =
        AgentAccess.grant(owner, agent.id, %{create: true, move: true, read_private: true})

      attrs = %{
        title: "Race",
        starts_at: ~U[2026-11-05 10:00:00.000000Z],
        ends_at: ~U[2026-11-05 11:00:00.000000Z]
      }

      {:ok, event} = Calendar.create_event(owner, attrs)

      {:ok, a} =
        AgentAccess.propose(
          scope,
          user.id,
          "move",
          %{starts_at: ~U[2026-11-06 10:00:00Z], ends_at: ~U[2026-11-06 11:00:00Z]},
          "move-a",
          event.id
        )

      {:ok, b} =
        AgentAccess.propose(
          scope,
          user.id,
          "move",
          %{starts_at: ~U[2026-11-07 10:00:00Z], ends_at: ~U[2026-11-07 11:00:00Z]},
          "move-b",
          event.id
        )

      results = race([fn -> act(a, "approve", owner) end, fn -> act(b, "approve", owner) end])
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :stale}, &1)) == 1
      assert Repo.get!(Event, event.id).sequence == 1

      {:ok, c} = AgentAccess.propose(scope, user.id, "create", attrs, "duplicate")
      results = race([fn -> act(c, "approve", owner) end, fn -> act(c, "approve", owner) end])
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Repo.get!(Event, c.hold_id).sequence == 1

      {:ok, d} = AgentAccess.propose(scope, user.id, "create", attrs, "revoke")
      race([fn -> act(d, "approve", owner) end, fn -> AgentAccess.revoke(owner, agent.id) end])
      consent = Repo.get!(Consent, d.id)
      hold = Repo.get!(Event, d.hold_id)
      assert consent.state in ["approved", "revoked"]
      refute consent.state == "pending"
      if consent.state == "revoked", do: assert(hold.cancelled_at), else: refute(hold.tentative)
      assert Repo.get!(Platform.Memory.Briefing, d.briefing_id).receipts["calendar:" <> d.id]
    after
      Repo.delete_all(from(c in Consent, where: c.owner_id == ^user.id))
      Repo.delete_all(from(g in AgentGrant, where: g.owner_id == ^user.id))
      Repo.delete_all(from(i in Platform.Inbox.Item, where: i.user_id == ^user.id))
      Repo.delete_all(from(b in Briefing, where: b.user_id == ^user.id))
      Repo.delete_all(from(e in Event, where: e.owner_id == ^user.id))
      Repo.delete_all(from(p in RuntimeProfile, where: p.runtime_id == ^runtime.id))
      Repo.delete!(runtime)
      Repo.delete!(agent)
      Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^user.id))
      Repo.delete!(user)
      Sandbox.mode(Repo, :manual)
    end
  end

  defp act(c, verb, owner),
    do: Briefings.handle(Repo.get!(Briefing, c.briefing_id), "calendar:" <> c.id, verb, owner)

  defp race(funs) do
    parent = self()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 20_000))
  end
end
