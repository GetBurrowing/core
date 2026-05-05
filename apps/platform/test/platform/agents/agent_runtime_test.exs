defmodule Platform.Agents.AgentRuntimeTest do
  @moduledoc """
  Tests for the `AgentRuntime` schema's pure helpers and the
  `Platform.Federation.update_metadata/2` round-trip.

  Pure helper tests use `ExUnit.Case` (no DB). The `update_metadata/2`
  round-trip uses `Platform.DataCase` because it touches Postgres.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Repo

  describe "client_product/1 (pure)" do
    test "returns \"openclaw\" when metadata.client_info.product is \"openclaw\"" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "openclaw", "version" => "0.1.0"}}
      }

      assert AgentRuntime.client_product(runtime) == "openclaw"
    end

    test "returns \"claude_channel\" when metadata.client_info.product is \"claude_channel\"" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel"}}
      }

      assert AgentRuntime.client_product(runtime) == "claude_channel"
    end

    test "returns \"unknown\" when metadata is empty (no client_info ever set)" do
      runtime = %AgentRuntime{metadata: %{}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" when client_info is present but product key is missing" do
      runtime = %AgentRuntime{metadata: %{"client_info" => %{"version" => "0.1.0"}}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" defensively when product is not in the allowlist" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "definitely-not-real"}}
      }

      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" when client_info is present but not a map" do
      runtime = %AgentRuntime{metadata: %{"client_info" => "garbage"}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end
  end

  describe "Federation.update_metadata/2 (DB round-trip)" do
    test "merges new keys into metadata without dropping existing ones" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-meta-#{System.unique_integer([:positive])}",
          metadata: %{"existing" => "keep"}
        })

      {:ok, updated} =
        Federation.update_metadata(runtime, %{
          "client_info" => %{"product" => "openclaw", "version" => "0.1.0"}
        })

      reloaded = Repo.get!(AgentRuntime, updated.id)

      assert reloaded.metadata["existing"] == "keep"
      assert reloaded.metadata["client_info"] == %{"product" => "openclaw", "version" => "0.1.0"}
      assert AgentRuntime.client_product(reloaded) == "openclaw"
    end

    test "treats nil metadata as empty map (defensive)" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-meta-#{System.unique_integer([:positive])}"
        })

      # Force-clear metadata to nil to simulate a legacy row.
      runtime = %{runtime | metadata: nil}

      {:ok, updated} =
        Federation.update_metadata(runtime, %{"client_info" => %{"product" => "claude_channel"}})

      reloaded = Repo.get!(AgentRuntime, updated.id)
      assert reloaded.metadata["client_info"]["product"] == "claude_channel"
      assert AgentRuntime.client_product(reloaded) == "claude_channel"
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "rt_meta_test_#{System.unique_integer([:positive])}@example.com",
      name: "Runtime Meta Test User",
      oidc_sub: "oidc-rt-meta-#{System.unique_integer([:positive])}"
    })
  end
end
