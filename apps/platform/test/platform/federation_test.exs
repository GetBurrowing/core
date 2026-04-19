defmodule Platform.FederationTest do
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  defp create_user do
    Repo.insert!(%User{
      email: "fed_test_#{System.unique_integer([:positive])}@example.com",
      name: "Fed Test User",
      oidc_sub: "oidc-fed-test-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  describe "register_runtime/2" do
    test "creates a runtime with pending status" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      assert runtime.status == "pending"
      assert runtime.owner_user_id == user.id
      assert runtime.transport == "websocket"
      assert runtime.trust_level == "participant"
    end
  end

  describe "activate_runtime/1" do
    test "changes status to active and returns token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, raw_token} = Federation.activate_runtime(runtime)

      assert activated.status == "active"
      assert is_binary(raw_token)
      assert activated.auth_token_hash != nil
      # Verify token validates
      assert AgentRuntime.verify_token(raw_token, activated.auth_token_hash)
    end
  end

  describe "link_agent/2" do
    test "associates an agent with the runtime" do
      user = create_user()
      agent = create_agent()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, linked_agent} = Federation.link_agent(runtime, agent)
      assert linked_agent.runtime_type == "external"
      assert linked_agent.runtime_id == runtime.id
    end

    test "auto-adds the federated agent to every non-archived channel space in its workspace" do
      alias Platform.Chat.Space

      workspace_id = Ecto.UUID.generate()

      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      {:ok, random} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "Random",
          slug: "random-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      # Archived space should NOT get the agent rostered.
      {:ok, archived} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "Archived",
          slug: "archived-#{System.unique_integer([:positive])}",
          kind: "channel",
          archived_at: DateTime.utc_now()
        })
        |> Repo.insert()

      agent = create_agent(%{workspace_id: workspace_id})
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Federation.link_agent(runtime, agent)

      general_entry = Chat.get_space_agent(general.id, agent.id)
      assert general_entry.role == "member"

      random_entry = Chat.get_space_agent(random.id, agent.id)
      assert random_entry.role == "member"

      refute Chat.get_space_agent(archived.id, agent.id)
    end

    test "auto-roster adds nil-workspace agents to nil-workspace channel spaces (single-tenant)" do
      alias Platform.Chat.Space

      # Single-tenant / default-org setup: both agents and spaces have
      # workspace_id: nil. Auto-roster must still match them together.
      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: nil,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent = create_agent()
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, linked} = Federation.link_agent(runtime, agent)
      assert is_nil(linked.workspace_id)

      assert %{role: "member"} = Chat.get_space_agent(general.id, agent.id)
    end

    test "auto-roster does NOT leak across workspaces" do
      alias Platform.Chat.Space

      # Agent in workspace A should NOT be rostered into workspace B's spaces.
      workspace_a = Ecto.UUID.generate()
      workspace_b = Ecto.UUID.generate()

      {:ok, space_a} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_a,
          name: "A",
          slug: "a-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      {:ok, space_b} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_b,
          name: "B",
          slug: "b-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent_a = create_agent(%{workspace_id: workspace_a})
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Federation.link_agent(runtime, agent_a)

      assert Chat.get_space_agent(space_a.id, agent_a.id)
      refute Chat.get_space_agent(space_b.id, agent_a.id)
    end

    test "auto-roster is idempotent when called again on an already-rostered agent" do
      alias Platform.Chat.Space

      workspace_id = Ecto.UUID.generate()

      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent = create_agent(%{workspace_id: workspace_id})

      :ok = Federation.auto_roster_federated_agent(agent)
      :ok = Federation.auto_roster_federated_agent(agent)

      # Idempotent: a second auto_roster call does not create a second row.
      entries =
        Chat.list_space_agents(general.id) |> Enum.filter(&(&1.agent_id == agent.id))

      assert length(entries) == 1
    end
  end

  describe "generate_runtime_token/1" do
    test "returns a valid token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, updated, raw_token} = Federation.generate_runtime_token(runtime)

      assert is_binary(raw_token)
      assert AgentRuntime.verify_token(raw_token, updated.auth_token_hash)
    end
  end

  describe "get_runtime_by_token/1" do
    test "finds an active runtime by its token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _activated, raw_token} = Federation.activate_runtime(runtime)

      found = Federation.get_runtime_by_token(raw_token)
      assert found != nil
      assert found.id == runtime.id
    end

    test "returns nil for invalid token" do
      assert Federation.get_runtime_by_token("bogus-token") == nil
    end
  end

  describe "suspend_runtime/1 and revoke_runtime/1" do
    test "suspend changes status" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _token} = Federation.activate_runtime(runtime)
      {:ok, suspended} = Federation.suspend_runtime(activated)
      assert suspended.status == "suspended"
    end

    test "revoke clears the token hash" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _token} = Federation.activate_runtime(runtime)
      {:ok, revoked} = Federation.revoke_runtime(activated)
      assert revoked.status == "revoked"
      assert revoked.auth_token_hash == nil
    end
  end
end
