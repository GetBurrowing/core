defmodule Platform.AgentHost.ReconcilerTest do
  @moduledoc """
  The reconciler converges native agents to their desired state through the
  agent host (task 01a10322 stage 2), and every `agent.start` carries a
  freshly minted runtime token: it authenticates `PlatformWeb.RuntimeSocket`,
  and the token before it no longer does.

  The host is a real `PlatformWeb.AgentHostSocket` connection joined from the
  test, so commands are asserted as the pushes the daemon would receive.
  """
  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.AgentHost.State
  alias Platform.Agents.{AgentRuntime, NativeAgents}
  alias Platform.Chat.ReplyFailure
  alias Platform.Repo

  @token "agent-host-token-01a10322-reconciler"

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "agent-host-#{n}@example.com",
        name: "Agent host #{n}",
        oidc_sub: "oidc-agent-host-#{n}"
      })

    %{owner: owner}
  end

  defp native!(owner, name) do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: "claude_code"})
    {agent, runtime}
  end

  defp join_host! do
    {:ok, socket} =
      connect(PlatformWeb.AgentHostSocket, %{},
        connect_info: %{x_headers: [{"x-agent-host-token", @token}]}
      )

    {:ok, _reply, channel} = subscribe_and_join(socket, "agent_host:control", %{})
    channel
  end

  defp inventory!(channel, agents, profile \\ "contained") do
    ref = push(channel, "host.inventory", %{"profile" => profile, "agents" => agents})
    assert_reply ref, :ok
  end

  defp runtime_connects?(runtime_id, token) do
    match?(
      {:ok, _},
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => runtime_id, "token" => token})
    )
  end

  describe "converging on join" do
    test "a running-desired agent the host does not run is started, with a fresh token", %{
      owner: owner
    } do
      {agent, runtime} = native!(owner, "Ada")
      {:ok, _} = NativeAgents.set_desired_state(agent, "running")
      {stopped_agent, _} = native!(owner, "Bea")

      channel = join_host!()
      inventory!(channel, [])

      assert_push "agent.start", %{
        "agent_id" => agent_id,
        "runtime_id" => runtime_id,
        "runtime_token" => token,
        "harness" => "claude_code",
        "core_url" => core_url,
        "env" => %{}
      }

      assert agent_id == agent.id
      assert runtime_id == runtime.runtime_id
      assert is_binary(core_url)
      assert runtime_connects?(runtime.runtime_id, token)

      # Bea's desired state is stopped and the host does not run her: nothing.
      refute_push "agent.start", %{"agent_id" => _}
      refute_push "agent.stop", %{"agent_id" => _}
      assert %{state: :starting} = AgentHost.status(agent)
      assert AgentHost.status(stopped_agent) == nil
    end

    test "a stopped-desired agent the host reports running is stopped", %{owner: owner} do
      {agent, _runtime} = native!(owner, "Cal")

      channel = join_host!()
      inventory!(channel, [%{"agent_id" => agent.id, "state" => "running"}])

      assert_push "agent.stop", %{"agent_id" => agent_id}
      assert agent_id == agent.id
      refute_push "agent.start", _
    end

    test "an agent already where it should be gets no command", %{owner: owner} do
      {running, _} = native!(owner, "Dee")
      {:ok, _} = NativeAgents.set_desired_state(running, "running")
      {stopped, _} = native!(owner, "Eve")

      channel = join_host!()

      inventory!(channel, [
        %{"agent_id" => running.id, "state" => "running"},
        %{"agent_id" => stopped.id, "state" => "stopped"}
      ])

      refute_push "agent.start", _
      refute_push "agent.stop", _
      assert %{state: :running, profile: "contained"} = AgentHost.status(running)
      assert AgentHost.host()[:profile] == "contained"
    end
  end

  describe "tokens" do
    test "each start's token authenticates RuntimeSocket and the previous one stops working",
         %{owner: owner} do
      {agent, runtime} = native!(owner, "Fay")
      channel = join_host!()
      inventory!(channel, [])

      assert :ok = AgentHost.start_agent(agent)
      assert_push "agent.start", %{"runtime_token" => first}
      assert runtime_connects?(runtime.runtime_id, first)

      assert :ok = AgentHost.restart_agent(agent)
      assert_push "agent.restart", %{"runtime_token" => second}

      assert first != second
      assert runtime_connects?(runtime.runtime_id, second)
      refute runtime_connects?(runtime.runtime_id, first)

      # Core keeps only the hash of the live token.
      stored = Repo.get!(AgentRuntime, runtime.id)
      assert stored.auth_token_hash == AgentRuntime.hash_token(second)
    end

    test "no token reaches the log", %{owner: owner} do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {agent, _runtime} = native!(owner, "Gus")
      channel = join_host!()
      inventory!(channel, [])

      log =
        capture_log([level: :debug], fn ->
          :ok = AgentHost.start_agent(agent)
          Logger.info("planted-line-01a10322")
        end)

      assert_push "agent.start", %{"runtime_token" => token}
      # Positive control: the capture does see info lines.
      assert log =~ "planted-line-01a10322"
      refute log =~ token
    end
  end

  describe "desired-state changes" do
    test "start and stop record the desire and converge", %{owner: owner} do
      {agent, runtime} = native!(owner, "Hal")
      channel = join_host!()
      inventory!(channel, [])

      assert :ok = AgentHost.start_agent(agent)
      assert_push "agent.start", %{"agent_id" => _}
      assert Repo.get!(AgentRuntime, runtime.id).desired_state == "running"

      ref = push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "running"})
      assert_reply ref, :ok
      assert %{state: :running} = AgentHost.status(agent)

      assert :ok = AgentHost.stop_agent(agent)
      assert_push "agent.stop", %{"agent_id" => agent_id}
      assert agent_id == agent.id
      assert Repo.get!(AgentRuntime, runtime.id).desired_state == "stopped"
    end

    test "with no host connected the desire is still recorded", %{owner: owner} do
      {agent, runtime} = native!(owner, "Ivy")
      refute AgentHost.connected?()
      assert :ok = AgentHost.start_agent(agent)
      assert Repo.get!(AgentRuntime, runtime.id).desired_state == "running"
    end

    test "a crashed report is recorded and is NOT restarted by core", %{owner: owner} do
      {agent, _} = native!(owner, "Jon")
      {:ok, _} = NativeAgents.set_desired_state(agent, "running")
      channel = join_host!()
      inventory!(channel, [%{"agent_id" => agent.id, "state" => "running"}])
      refute_push "agent.start", _

      ref = push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "crashed"})
      assert_reply ref, :ok
      assert %{state: :crashed} = AgentHost.status(agent)
      refute_push "agent.start", _
    end

    test "a start that comes back stopped is NOT started again by core (no token loop)",
         %{owner: owner} do
      {agent, _} = native!(owner, "Kay")
      channel = join_host!()
      inventory!(channel, [])

      assert :ok = AgentHost.start_agent(agent)
      assert_push "agent.start", %{"agent_id" => _}

      # The unit failed to come up. Converging here would mint another token
      # and start again, forever; only a person's next press may.
      ref = push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "stopped"})
      assert_reply ref, :ok
      assert %{state: :stopped} = AgentHost.status(agent)
      refute_push "agent.start", _
    end

    test "an unknown state string is refused, not turned into an atom", %{owner: owner} do
      {agent, _} = native!(owner, "Kit")
      channel = join_host!()
      inventory!(channel, [])

      ref =
        push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "exploded-01a10322"})

      assert_reply ref, :error, %{reason: "invalid_state"}
      assert AgentHost.status(agent) == nil
    end
  end

  describe "observed state is ephemeral" do
    test "a host that goes away takes its observations with it", %{owner: owner} do
      {agent, _} = native!(owner, "Lou")
      channel = join_host!()
      inventory!(channel, [%{"agent_id" => agent.id, "state" => "stopped"}])
      assert %{state: :stopped} = AgentHost.status(agent)

      AgentHost.subscribe()
      pid = channel.channel_pid
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert_receive {:agent_host_status, :host_disconnected}

      refute AgentHost.connected?()
      assert AgentHost.status(agent) == nil
      assert State.all() == %{}
    end
  end

  describe "logs" do
    test "a log request is answered by the host's agent.log under the same ref", %{owner: owner} do
      {agent, _} = native!(owner, "Max")
      channel = join_host!()
      inventory!(channel, [])

      task = Task.async(fn -> AgentHost.logs(agent, lines: 2) end)
      assert_push "agent.logs", %{"agent_id" => agent_id, "lines" => 2, "ref" => ref}
      assert agent_id == agent.id

      reply = push(channel, "agent.log", %{"ref" => ref, "lines" => ["one", "two"]})
      assert_reply reply, :ok
      assert {:ok, ["one", "two"]} = Task.await(task)
    end

    test "with no host, logs say so" do
      assert {:error, :not_connected} = AgentHost.logs(Ecto.UUID.generate())
    end
  end

  describe "ReplyFailure reads the host's observation" do
    test "needs_login and crashed become the notice's cause; no observation falls back",
         %{owner: owner} do
      {agent, _} = native!(owner, "Ned")
      {:ok, _} = NativeAgents.set_desired_state(agent, "running")
      channel = join_host!()
      inventory!(channel, [%{"agent_id" => agent.id, "state" => "needs_login"}])
      assert ReplyFailure.cause_for(agent, :runtime_offline) == :needs_login

      ref = push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "crashed"})
      assert_reply ref, :ok
      assert ReplyFailure.cause_for(agent, :runtime_offline) == :crashed

      ref = push(channel, "agent.state", %{"agent_id" => agent.id, "state" => "running"})
      assert_reply ref, :ok
      # Running yet offline: nothing observed explains it.
      assert ReplyFailure.cause_for(agent, :runtime_offline) == :unknown

      {other, _} = native!(owner, "Oz")
      # Not observed, desired stopped: the stage-1 fallback.
      assert ReplyFailure.cause_for(other, :runtime_offline) == :stopped
    end
  end
end
