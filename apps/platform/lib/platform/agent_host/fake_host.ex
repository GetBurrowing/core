defmodule Platform.AgentHost.FakeHost do
  @moduledoc """
  A stand-in agent host for dev (task 01a10315 stage 4), started only when
  `BURROW_FAKE_AGENT_HOST=1` in dev (`config/runtime.exs` sets
  `config :platform, :fake_agent_host, true`; `Platform.Application` reads
  it). Nothing here runs in prod or test unless a test starts it itself.

  It joins `Platform.AgentHost.Reconciler` exactly as the real host's channel
  process does (`host_joined/2`, then an empty `inventory/2`), so the
  reconciler converges native agents to it and every screen sees a connected
  host. Then, for each `agent.start` / `agent.restart` it receives:

    * a `codex` agent reports `needs_login` at Codex's device login, with
      `login: {step: "device_code", url: "https://auth.openai.com/codex/device",
      code: "FAKE-1234"}`, until `complete/1` (dev route
      `POST /dev/fake-agent-host/<agent_id>/complete`) marks it logged in;
      after that it reports `running`;
    * a `claude_code` agent reports `running` when its start carried an API
      key (`env["ANTHROPIC_API_KEY"]`, which is never kept or logged here),
      and otherwise `needs_login` at step `login`. Never a Claude login URL or
      code (task 01a17b10).

  `agent.stop` reports `stopped`. Logs, pane, file and auth requests get no
  answer; their callers time out as they would against a host that is slow.

  No real CLI runs and nothing leaves the BEAM.
  """

  use GenServer

  require Logger

  alias Platform.AgentHost.Reconciler

  @device_url "https://auth.openai.com/codex/device"
  @device_code "FAKE-1234"
  @report_after_ms 500
  @rejoin_after_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The device code a fake codex login shows."
  def device_code, do: @device_code

  @doc "The device URL a fake codex login shows."
  def device_url, do: @device_url

  @doc """
  Finish `agent_id`'s fake Codex login, as if its owner approved the code on
  OpenAI's page. `:ok`, or `{:error, :unknown_agent}` for an agent this fake
  host was never asked to start, or `{:error, :not_device_login}` for a
  non-codex one.
  """
  @spec complete(binary(), GenServer.server()) ::
          :ok | {:error, :unknown_agent | :not_device_login | :not_running}
  def complete(agent_id, server \\ __MODULE__) when is_binary(agent_id) do
    if GenServer.whereis(server),
      do: GenServer.call(server, {:complete, agent_id}),
      else: {:error, :not_running}
  end

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      agents: %{},
      completed: MapSet.new(),
      report_after_ms: Keyword.get(opts, :report_after_ms, @report_after_ms),
      reconciler: nil
    }

    {:ok, state, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state), do: {:noreply, join(state)}

  @impl true
  def handle_call({:complete, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :unknown_agent}, state}

      %{harness: "codex"} = agent ->
        state = %{state | completed: MapSet.put(state.completed, agent_id)}
        if agent.started?, do: report(agent_id, observation(agent_id, agent, state))
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_device_login}, state}
    end
  end

  @impl true
  def handle_info({:agent_host_push, event, %{"agent_id" => id} = payload}, state)
      when event in ["agent.start", "agent.restart"] and is_binary(id) do
    env = if is_map(payload["env"]), do: payload["env"], else: %{}

    agent = %{
      harness: payload["harness"],
      api_key?: is_binary(env["ANTHROPIC_API_KEY"]),
      started?: true
    }

    Process.send_after(self(), {:report, id}, state.report_after_ms)
    {:noreply, put_in(state.agents[id], agent)}
  end

  def handle_info({:agent_host_push, "agent.stop", %{"agent_id" => id}}, state)
      when is_binary(id) do
    state =
      case Map.get(state.agents, id) do
        nil -> state
        agent -> put_in(state.agents[id], %{agent | started?: false})
      end

    report(id, %{"agent_id" => id, "state" => "stopped"})
    {:noreply, state}
  end

  def handle_info({:agent_host_push, _event, _payload}, state), do: {:noreply, state}

  def handle_info({:report, id}, state) do
    case Map.get(state.agents, id) do
      %{started?: true} = agent -> report(id, observation(id, agent, state))
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reconciler: ref} = state) do
    Process.send_after(self(), :rejoin, @rejoin_after_ms)
    {:noreply, %{state | reconciler: nil}}
  end

  def handle_info(:rejoin, state), do: {:noreply, join(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────

  @doc false
  def observation(id, %{harness: "codex"}, state) do
    if MapSet.member?(state.completed, id) do
      %{"agent_id" => id, "state" => "running"}
    else
      %{
        "agent_id" => id,
        "state" => "needs_login",
        "detail" => "device_code",
        "login" => %{"step" => "device_code", "url" => @device_url, "code" => @device_code}
      }
    end
  end

  def observation(id, %{api_key?: true}, _state), do: %{"agent_id" => id, "state" => "running"}

  def observation(id, _agent, _state),
    do: %{
      "agent_id" => id,
      "state" => "needs_login",
      "detail" => "login",
      "login" => %{"step" => "login"}
    }

  defp report(id, payload) do
    case Reconciler.agent_state(self(), payload) do
      :ok -> :ok
      other -> Logger.warning("[FakeHost] agent=#{id} state not recorded: #{inspect(other)}")
    end
  end

  defp join(state) do
    case GenServer.whereis(Reconciler) do
      nil ->
        Process.send_after(self(), :rejoin, @rejoin_after_ms)
        state

      pid ->
        with :ok <- Reconciler.host_joined(self(), %{"profile" => "fake"}),
             :ok <- Reconciler.inventory(self(), %{"profile" => "fake", "agents" => []}) do
          %{state | reconciler: Process.monitor(pid)}
        else
          other ->
            Logger.warning("[FakeHost] could not join the reconciler: #{inspect(other)}")
            Process.send_after(self(), :rejoin, @rejoin_after_ms)
            state
        end
    end
  end
end
