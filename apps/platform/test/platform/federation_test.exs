defmodule Platform.FederationTest do
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
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
