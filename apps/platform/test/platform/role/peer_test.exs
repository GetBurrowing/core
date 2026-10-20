defmodule Platform.Role.PeerTest do
  @moduledoc """
  Node-local reads a web node sends to its full peer (task 01a155a6 stage 4).

  The peer is a recording stand-in for `:erpc.call/5`, injected as
  `:role_peer_rpc`: it records what would have crossed the wire and answers
  from a table the test sets. A peer whose answer is the only place the value
  exists is the discriminating case: a read that stayed local would see this
  VM's empty or unrelated state instead.

  NOT async: it sets the node role and app env.
  """

  use ExUnit.Case, async: false

  alias Platform.AgentHost
  alias Platform.Chat.{ActiveAgentStore, ContextPlane}
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.{LeaseManager, TaskRouterWatcher}
  alias Platform.Role.Peer

  @peer :platform@core_platform_test

  setup do
    keys = [:role, :cluster_peer, :role_peer_rpc]
    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :answers})

      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    test_pid = self()

    Application.put_env(:platform, :role_peer_rpc, fn node, module, fun, args, timeout ->
      send(test_pid, {:rpc, node, module, fun, args, timeout})

      case Map.fetch(:persistent_term.get({__MODULE__, :answers}, %{}), {module, fun, args}) do
        {:ok, {:raise, reason}} -> raise ErlangError, original: reason
        {:ok, answer} -> answer
        :error -> raise ErlangError, original: {:erpc, :noconnection}
      end
    end)

    Application.put_env(:platform, :role, :web)
    Application.put_env(:platform, :cluster_peer, @peer)
    :ok
  end

  defp peer_answers(answers), do: :persistent_term.put({__MODULE__, :answers}, answers)

  defp id, do: "peer-test-#{System.unique_integer([:positive])}"

  describe "Peer" do
    test "is remote only under :web with a peer" do
      assert Peer.remote?()
      assert Peer.server(LeaseManager) == {LeaseManager, @peer}

      Application.delete_env(:platform, :cluster_peer)
      refute Peer.remote?()
      assert Peer.server(LeaseManager) == LeaseManager

      Application.put_env(:platform, :cluster_peer, @peer)
      Application.put_env(:platform, :role, :full)
      refute Peer.remote?()
    end

    test "read/5 answers the default, without a call, on a full node" do
      Application.put_env(:platform, :role, :full)
      assert Peer.read(RuntimePresence, :local_online?, ["x"], :default) == :default
      refute_received {:rpc, _, _, _, _, _}
    end

    test "read/5 answers the default when the peer raises or is unreachable" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert Peer.read(RuntimePresence, :local_list_all, [], %{}) == %{}
      end)

      assert_received {:rpc, @peer, RuntimePresence, :local_list_all, [], 2_000}
    end
  end

  describe "RuntimePresence on a web node" do
    test "a runtime connected to the peer reads online, with its status, in every list" do
      runtime_id = id()
      entry = %{connected_at: DateTime.utc_now(), last_seen_at: DateTime.utc_now(), proven: %{}}

      peer_answers(%{
        {RuntimePresence, :local_online?, [runtime_id]} => true,
        {RuntimePresence, :local_status, [runtime_id]} => entry,
        {RuntimePresence, :local_list_all, []} => %{runtime_id => entry}
      })

      refute RuntimePresence.local_online?(runtime_id)
      assert RuntimePresence.online?(runtime_id)
      assert RuntimePresence.status(runtime_id) == entry
      assert runtime_id in RuntimePresence.list_online()
      assert Map.has_key?(RuntimePresence.list_all(), runtime_id)

      assert_received {:rpc, @peer, RuntimePresence, :local_online?, [^runtime_id], _}
    end

    test "a runtime connected to the web node itself still reads online; an unreachable peer adds nothing" do
      runtime_id = id()
      RuntimePresence.track(runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime_id) end)
      peer_answers(%{})

      ExUnit.CaptureLog.capture_log(fn ->
        assert RuntimePresence.online?(runtime_id)
        refute RuntimePresence.online?(id())
        assert Map.has_key?(RuntimePresence.list_all(), runtime_id)
      end)
    end
  end

  describe "ActiveAgentStore on a web node" do
    test "reads the peer's row, where server/0 sends every write" do
      space_id = id()
      agent = Ecto.UUID.generate()

      peer_answers(%{
        {ActiveAgentStore, :local_get_active, [space_id]} => agent,
        {ActiveAgentStore, :local_get_last_agent, [space_id]} => agent
      })

      assert ActiveAgentStore.local_get_active(space_id) == nil
      assert ActiveAgentStore.get_active(space_id) == agent
      assert ActiveAgentStore.get_last_agent(space_id) == agent
    end

    test "an unreachable peer reads as no active agent" do
      peer_answers(%{})

      ExUnit.CaptureLog.capture_log(fn ->
        assert ActiveAgentStore.get_active(id()) == nil
      end)
    end
  end

  describe "LeaseManager on a web node" do
    test "get/1 reads the peer's lease" do
      task_id = id()
      lease = %{task_id: task_id, owner_runtime_id: "rt"}
      peer_answers(%{{LeaseManager, :local_get, [task_id]} => lease})

      assert LeaseManager.local_get(task_id) == nil
      assert LeaseManager.get(task_id) == lease
    end

    test "record_ack/3 and silence/3 go to the peer and name an unreachable one, not a missing lease" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert LeaseManager.record_ack(id(), "rt", "sub") == {:error, :peer_unreachable}

        assert LeaseManager.silence(id(), DateTime.add(DateTime.utc_now(), 600), "reason here") ==
                 {:error, :peer_unreachable}
      end)
    end
  end

  describe "TaskRouterWatcher.force_dispatch/1 on a web node" do
    test "is sent to the peer and never evaluated locally" do
      task_id = id()
      peer_answers(%{{TaskRouterWatcher, :force_dispatch, [task_id]} => :ok})

      assert TaskRouterWatcher.force_dispatch(task_id) == :ok
      assert_received {:rpc, @peer, TaskRouterWatcher, :force_dispatch, [^task_id], _}
    end

    test "with no peer it is a :noop, not a router start" do
      Application.delete_env(:platform, :cluster_peer)
      assert TaskRouterWatcher.force_dispatch(id()) == :noop
      refute_received {:rpc, _, _, _, _, _}
    end
  end

  describe "AgentHost on a web node" do
    test "connected?/0 and status/1 read the peer's reconciler and table" do
      agent_id = id()
      host = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(host, :kill) end)

      peer_answers(%{
        {Platform.AgentHost.Reconciler, :host_pid, []} => host,
        {Platform.AgentHost.State, :get, [agent_id]} => %{state: :running}
      })

      assert AgentHost.connected?()
      assert AgentHost.status(agent_id) == %{state: :running}
    end
  end

  describe "ContextPlane on a web node" do
    test "reads the peer's context" do
      space_id = id()
      activity = [%{message_id: "m1", author: "p", preview: "hi", timestamp: DateTime.utc_now()}]

      peer_answers(%{
        {ContextPlane, :local_read, [{:activity, space_id}, []]} => activity,
        {ContextPlane, :local_read, [{:space, space_id}, %{}]} => %{name: "Space"},
        {ContextPlane, :local_read, [{:agents, space_id}, %{}]} => %{},
        {ContextPlane, :local_read, [{:canvases, space_id}, []]} => []
      })

      assert ContextPlane.get_recent_activity(space_id) == activity
      assert ContextPlane.get_space_context(space_id) == %{name: "Space"}
    end
  end
end
