defmodule Platform.Chat.ActiveAgentStoreTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.ActiveAgentStore

  setup do
    # Clean up ETS state between tests to avoid bleed-over
    space_id = "space-#{:erlang.unique_integer([:positive])}"
    %{space_id: space_id}
  end

  describe "set_active/2 and get_active/1" do
    test "sets and returns the active agent", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      assert :ok = ActiveAgentStore.set_active(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == agent_id
    end

    test "overwrites a previous active agent", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_a)
      ActiveAgentStore.set_active(space_id, agent_b)

      assert ActiveAgentStore.get_active(space_id) == agent_b
    end
  end

  describe "get_active/1" do
    test "returns nil for unknown space" do
      assert ActiveAgentStore.get_active(
               "nonexistent-space-#{:erlang.unique_integer([:positive])}"
             ) ==
               nil
    end
  end

  describe "get_last_agent/1" do
    test "returns nil for unknown space" do
      assert ActiveAgentStore.get_last_agent(
               "nonexistent-space-#{:erlang.unique_integer([:positive])}"
             ) ==
               nil
    end

    test "matches the active agent after set_active/2", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)

      assert ActiveAgentStore.get_active(space_id) == agent_id
      assert ActiveAgentStore.get_last_agent(space_id) == agent_id
    end

    test "is retained after clear_active/1", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)
      assert :ok = ActiveAgentStore.clear_active(space_id)

      assert ActiveAgentStore.get_active(space_id) == nil
      assert ActiveAgentStore.get_last_agent(space_id) == agent_id
    end

    test "survives repeated clear_active/1 calls", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)
      assert :ok = ActiveAgentStore.clear_active(space_id)
      assert :ok = ActiveAgentStore.clear_active(space_id)

      assert ActiveAgentStore.get_active(space_id) == nil
      assert ActiveAgentStore.get_last_agent(space_id) == agent_id
    end

    test "is retained after a matching clear_if_match/2", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)
      assert :ok = ActiveAgentStore.clear_if_match(space_id, agent_id)

      assert ActiveAgentStore.get_active(space_id) == nil
      assert ActiveAgentStore.get_last_agent(space_id) == agent_id
    end

    test "is unchanged by a non-matching clear_if_match/2", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_a)
      assert :ok = ActiveAgentStore.clear_if_match(space_id, agent_b)

      assert ActiveAgentStore.get_active(space_id) == agent_a
      assert ActiveAgentStore.get_last_agent(space_id) == agent_a
    end

    @tag timeout: 5_000
    test "is retained after the inactivity timeout fires", %{space_id: space_id} do
      original = Application.get_env(:platform, :active_agent_timeout_ms)
      Application.put_env(:platform, :active_agent_timeout_ms, 50)

      on_exit(fn ->
        if original do
          Application.put_env(:platform, :active_agent_timeout_ms, original)
        else
          Application.delete_env(:platform, :active_agent_timeout_ms)
        end
      end)

      agent_id = Ecto.UUID.generate()
      ActiveAgentStore.set_active(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == agent_id

      Process.sleep(150)

      assert ActiveAgentStore.get_active(space_id) == nil
      assert ActiveAgentStore.get_last_agent(space_id) == agent_id
    end

    test "moves to the new agent when re-armed with a different agent", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_a)
      assert ActiveAgentStore.get_last_agent(space_id) == agent_a

      ActiveAgentStore.set_active(space_id, agent_b)

      assert ActiveAgentStore.get_active(space_id) == agent_b
      assert ActiveAgentStore.get_last_agent(space_id) == agent_b
    end

    test "re-arms cleanly from a released row", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_a)
      ActiveAgentStore.clear_active(space_id)

      # The retained row carries a nil timer_ref — re-arming must not raise.
      assert :ok = ActiveAgentStore.set_active(space_id, agent_b)

      assert ActiveAgentStore.get_active(space_id) == agent_b
      assert ActiveAgentStore.get_last_agent(space_id) == agent_b
    end
  end

  describe "clear_active/1" do
    test "clears the active agent", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == agent_id

      assert :ok = ActiveAgentStore.clear_active(space_id)
      assert ActiveAgentStore.get_active(space_id) == nil
    end

    test "is idempotent on empty space", %{space_id: space_id} do
      assert :ok = ActiveAgentStore.clear_active(space_id)
    end
  end

  describe "clear_if_match/2" do
    test "clears when the current active agent matches", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_id)
      assert :ok = ActiveAgentStore.clear_if_match(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == nil
    end

    test "does not clear when a different agent is active", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      ActiveAgentStore.set_active(space_id, agent_a)
      assert :ok = ActiveAgentStore.clear_if_match(space_id, agent_b)
      assert ActiveAgentStore.get_active(space_id) == agent_a
    end

    test "is idempotent on empty space", %{space_id: space_id} do
      assert :ok = ActiveAgentStore.clear_if_match(space_id, Ecto.UUID.generate())
    end
  end

  describe "timeout" do
    @tag timeout: 5_000
    test "auto-clears after configured interval", %{space_id: space_id} do
      # Use a very short timeout for testing
      original = Application.get_env(:platform, :active_agent_timeout_ms)
      Application.put_env(:platform, :active_agent_timeout_ms, 50)

      on_exit(fn ->
        if original do
          Application.put_env(:platform, :active_agent_timeout_ms, original)
        else
          Application.delete_env(:platform, :active_agent_timeout_ms)
        end
      end)

      agent_id = Ecto.UUID.generate()
      ActiveAgentStore.set_active(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == agent_id

      # Wait for timeout to fire
      Process.sleep(150)

      assert ActiveAgentStore.get_active(space_id) == nil
    end

    @tag timeout: 5_000
    test "timeout does not clear if a different agent took over", %{space_id: space_id} do
      original = Application.get_env(:platform, :active_agent_timeout_ms)
      # Use 300ms so agent_b's timer hasn't fired yet when we check at 100ms
      Application.put_env(:platform, :active_agent_timeout_ms, 300)

      on_exit(fn ->
        if original do
          Application.put_env(:platform, :active_agent_timeout_ms, original)
        else
          Application.delete_env(:platform, :active_agent_timeout_ms)
        end
      end)

      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()

      # Set agent A with a 300ms timeout
      ActiveAgentStore.set_active(space_id, agent_a)

      # Immediately switch to agent B — cancels agent A's timer and starts a new 300ms one
      ActiveAgentStore.set_active(space_id, agent_b)

      # Wait 100ms — if agent A's timer wasn't cancelled, it would fire at 300ms anyway.
      # Agent B's timer fires at ~300ms, so at 100ms it's still active.
      Process.sleep(100)

      # Agent B should still be active
      assert ActiveAgentStore.get_active(space_id) == agent_b
    end
  end

  describe "PubSub broadcasts" do
    test "broadcasts on set_active", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      ActiveAgentStore.set_active(space_id, agent_id)

      assert_receive {:active_agent_changed, ^space_id, ^agent_id}, 1_000
    end

    test "broadcasts nil on clear_active", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()
      ActiveAgentStore.set_active(space_id, agent_id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      ActiveAgentStore.clear_active(space_id)

      assert_receive {:active_agent_changed, ^space_id, nil}, 1_000
    end

    test "broadcasts nil on clear_if_match when matching", %{space_id: space_id} do
      agent_id = Ecto.UUID.generate()
      ActiveAgentStore.set_active(space_id, agent_id)

      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      ActiveAgentStore.clear_if_match(space_id, agent_id)

      assert_receive {:active_agent_changed, ^space_id, nil}, 1_000
    end

    test "does not broadcast on clear_if_match when non-matching", %{space_id: space_id} do
      agent_a = Ecto.UUID.generate()
      agent_b = Ecto.UUID.generate()
      ActiveAgentStore.set_active(space_id, agent_a)

      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      ActiveAgentStore.clear_if_match(space_id, agent_b)

      refute_receive {:active_agent_changed, _, _}, 200
    end

    @tag timeout: 5_000
    test "broadcasts on timeout auto-clear", %{space_id: space_id} do
      original = Application.get_env(:platform, :active_agent_timeout_ms)
      Application.put_env(:platform, :active_agent_timeout_ms, 50)

      on_exit(fn ->
        if original do
          Application.put_env(:platform, :active_agent_timeout_ms, original)
        else
          Application.delete_env(:platform, :active_agent_timeout_ms)
        end
      end)

      agent_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      ActiveAgentStore.set_active(space_id, agent_id)
      assert_receive {:active_agent_changed, ^space_id, ^agent_id}, 1_000

      # Wait for timeout
      assert_receive {:active_agent_changed, ^space_id, nil}, 1_000
    end
  end

  # Task 01a155a6 stage 3. A web node runs no AttentionRouter, so the mutex
  # that decides routing is its full peer's. A write kept on the web node would
  # arm a store nothing routes from, and its release timer would broadcast to
  # the full node's LiveViews over clustered PubSub.
  describe "under the web role with a cluster peer" do
    setup do
      previous = Map.new([:role, :cluster_peer], &{&1, Application.fetch_env(:platform, &1)})

      on_exit(fn ->
        for {key, value} <- previous do
          case value do
            {:ok, v} -> Application.put_env(:platform, key, v)
            :error -> Application.delete_env(:platform, key)
          end
        end
      end)

      Application.put_env(:platform, :role, :web)
      :ok
    end

    test "writes go to the peer's store; this node's store is untouched and broadcasts nothing",
         %{space_id: space_id} do
      peer = :nobody@nowhere
      Application.put_env(:platform, :cluster_peer, peer)
      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")

      assert ActiveAgentStore.server() == {ActiveAgentStore, peer}
      assert :ok = ActiveAgentStore.set_active(space_id, Ecto.UUID.generate())
      assert :ok = ActiveAgentStore.clear_active(space_id)
      assert :ok = ActiveAgentStore.clear_if_match(space_id, Ecto.UUID.generate())

      assert ActiveAgentStore.get_active(space_id) == nil
      assert ActiveAgentStore.get_last_agent(space_id) == nil
      refute_receive {:active_agent_changed, ^space_id, _}, 100
    end

    test "positive control: with this node as the peer, the forwarded write lands and broadcasts",
         %{space_id: space_id} do
      Application.put_env(:platform, :cluster_peer, node())
      Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space_id}")
      agent_id = Ecto.UUID.generate()

      assert ActiveAgentStore.server() == {ActiveAgentStore, node()}
      assert :ok = ActiveAgentStore.set_active(space_id, agent_id)

      assert ActiveAgentStore.get_active(space_id) == agent_id
      assert_receive {:active_agent_changed, ^space_id, ^agent_id}, 500
    end

    test "with no peer configured, a web node keeps its own store", %{space_id: space_id} do
      Application.delete_env(:platform, :cluster_peer)
      agent_id = Ecto.UUID.generate()

      assert ActiveAgentStore.server() == ActiveAgentStore
      assert :ok = ActiveAgentStore.set_active(space_id, agent_id)
      assert ActiveAgentStore.get_active(space_id) == agent_id
    end
  end
end
