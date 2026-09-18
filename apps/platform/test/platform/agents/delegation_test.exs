defmodule Platform.Agents.DelegationTest do
  @moduledoc """
  `Platform.Agents.Delegation` (task `01a0b491-0718-7001-8bba-bf50f119bb13`
  stage 2).

  ## The vacuity this file exists to avoid

  The two agents excluded on the live install were ALREADY OFFLINE when
  the exclusion rows were written, so a test asserting "the excluded
  agents are absent from the eligible list" would pass with the filter
  deleted — they would be absent anyway. Every test here therefore
  excludes an agent whose own CONNECTED work runtime is inserted by the
  test itself.

  ## The positive control

  Three fixtures: a voice-only runtime, a work runtime, and a work
  runtime whose agent carries an exclusion row. Exactly one comes back
  eligible. Without the middle fixture an `eligible_agents/0` that
  returned `[]` unconditionally would pass every other assertion in this
  file.

  `async: false` — `RuntimePresence` is a single named process shared by
  every test in the suite.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.Delegation
  alias Platform.Agents.DelegationExclusion
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  @reason "Excluded for the duration of this test with a sentence long enough to be a reason."

  defp agent!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "delegation-#{label}-#{n}",
      name: "Delegation #{label} #{n}",
      status: "active"
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      email: "delegation-#{n}@example.com",
      name: "Delegation Owner #{n}",
      oidc_sub: "oidc-delegation-#{n}"
    })
  end

  defp runtime!(agent, features) do
    n = System.unique_integer([:positive])
    runtime_id = "delegation-runtime-#{n}"

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: runtime_id,
        agent_id: agent.id,
        owner_user_id: user!().id,
        display_name: "Delegation Runtime #{n}",
        status: "active",
        auth_token_hash: "hash-#{n}",
        metadata: %{"client_info" => %{"features" => features}}
      })

    RuntimePresence.track(runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime_id) end)

    runtime
  end

  defp exclude!(agent, kind) do
    %DelegationExclusion{}
    |> DelegationExclusion.changeset(%{
      agent_id: agent.id,
      reason_kind: kind,
      reason: @reason,
      decided_by: "test"
    })
    |> Repo.insert!()
  end

  defp eligible_ids, do: Delegation.eligible_agents() |> Enum.map(fn {a, _f} -> a.id end)

  describe "eligible_agents/0" do
    test "returns the work runtime, and only it, across all three fixtures" do
      voice = agent!("voice")
      work = agent!("work")
      excluded = agent!("excluded")

      runtime!(voice, ["meeting_voice"])
      runtime!(work, ["system_event_prompt"])
      runtime!(excluded, ["system_event_prompt"])
      exclude!(excluded, "capability_judgement")

      ids = eligible_ids()

      # The positive control: without this the two refutes below pass on
      # an eligible_agents/0 that always returns [].
      assert work.id in ids
      refute voice.id in ids
      refute excluded.id in ids
    end

    test "a runtime declaring no features is a work runtime, not a voice worker" do
      # The work runtime on a live install honestly declares []; a closed
      # reading of declared features would return nobody at all.
      agent = agent!("undeclared")
      runtime!(agent, [])

      assert agent.id in eligible_ids()
    end

    test "an agent with both a voice row and a work row stays eligible" do
      agent = agent!("both")
      runtime!(agent, ["meeting_voice"])
      runtime!(agent, ["system_event_prompt"])

      assert {_agent, features} =
               Delegation.eligible_agents() |> Enum.find(fn {a, _f} -> a.id == agent.id end)

      # Only the WORK row's features are folded in — the voice row is not
      # the row that would do the work.
      assert features == ["system_event_prompt"]
    end

    test "an offline work runtime is not eligible" do
      agent = agent!("offline")
      runtime = runtime!(agent, ["system_event_prompt"])
      RuntimePresence.untrack(runtime.runtime_id)

      refute agent.id in eligible_ids()
    end
  end

  describe "ineligible_agents/0" do
    test "carries the kind and the full reason sentence, not a boolean" do
      capability = agent!("capability")
      conflict = agent!("conflict")

      runtime!(capability, ["system_event_prompt"])
      exclude!(capability, "capability_judgement")
      exclude!(conflict, "role_conflict")

      rows = Delegation.ineligible_agents()
      by_id = Map.new(rows, fn {a, kind, reason} -> {a.id, {kind, reason}} end)

      assert {"capability_judgement", @reason} = Map.fetch!(by_id, capability.id)
      assert {"role_conflict", @reason} = Map.fetch!(by_id, conflict.id)
    end

    test "lists an excluded agent whose runtime is offline" do
      # The judgement is about the agent. A list that dropped the agent
      # when its socket went down would make 'excluded' and 'does not
      # exist' the same observation, which is the defect this companion
      # function exists to prevent.
      agent = agent!("dormant")
      exclude!(agent, "role_conflict")

      assert Enum.any?(Delegation.ineligible_agents(), fn {a, _k, _r} -> a.id == agent.id end)
    end
  end

  describe "DelegationExclusion.changeset/2" do
    test "rejects a reason_kind outside the closed set" do
      agent = agent!("kind")

      changeset =
        DelegationExclusion.changeset(%DelegationExclusion{}, %{
          agent_id: agent.id,
          reason_kind: "looks_idle",
          reason: @reason,
          decided_by: "test"
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:reason_kind]

      # Positive control for the assertion above.
      assert DelegationExclusion.changeset(%DelegationExclusion{}, %{
               agent_id: agent.id,
               reason_kind: "role_conflict",
               reason: @reason,
               decided_by: "test"
             }).valid?
    end

    test "rejects a reason too short to be a reason" do
      agent = agent!("short")

      changeset =
        DelegationExclusion.changeset(%DelegationExclusion{}, %{
          agent_id: agent.id,
          reason_kind: "role_conflict",
          reason: "no",
          decided_by: "test"
        })

      refute changeset.valid?
      assert {msg, opts} = changeset.errors[:reason]
      assert msg =~ "at least"
      assert opts[:count] == 20
    end

    test "one agent cannot carry two reasons" do
      agent = agent!("dup")
      exclude!(agent, "role_conflict")

      assert {:error, changeset} =
               %DelegationExclusion{}
               |> DelegationExclusion.changeset(%{
                 agent_id: agent.id,
                 reason_kind: "capability_judgement",
                 reason: @reason,
                 decided_by: "test"
               })
               |> Repo.insert()

      assert changeset.errors[:agent_id] != nil
    end
  end
end
