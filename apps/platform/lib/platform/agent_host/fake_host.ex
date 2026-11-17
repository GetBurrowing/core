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
      key (`env["ANTHROPIC_API_KEY"]`, which is never kept or logged here) or
      a fake Claude login has succeeded for it, and otherwise `needs_login`
      at step `login`. Never a Claude login URL or code in an observation
      (task 01a17b10). As on a real host, `agent.claude_logout` does NOT
      change what a later start reports: a logged-out Claude Code agent whose
      unit is up still reads `running` (the login prompt sits in its pane).

  A stubbed Claude subscription login (task 01a1b365 stage 2,
  `claude_login_reply/3`): `agent.claude_login_start` is answered with a fake
  claude.com URL; `agent.claude_login_code` with `ok`, account
  `owner@example.com`, plan `max`, for the one known-good code
  (`claude_login_code/0`), and `bad_code` for anything else. The switch
  `set_claude_login/2` (dev route
  `POST /dev/fake-agent-host/claude-login/<mode>`) makes a good code answer
  `no_subscription`, or makes the fake host answer nothing (`timeout`). On
  `ok` the agent then reports `running`, as the real host's restart would.
  The code is compared here and dropped; it is never kept or logged.

  It joins only once `PlatformWeb.Endpoint` is running: it starts before the
  Endpoint in the supervision tree, so it waits and retries every second
  (`join/1`).

  `agent.stop` reports `stopped`. Logs, pane, file and auth requests get no
  answer; their callers time out as they would against a host that is slow.

  No real CLI runs and nothing leaves the BEAM.
  """

  use GenServer

  require Logger

  alias Platform.AgentHost.{LoginCode, Reconciler}

  @device_url "https://auth.openai.com/codex/device"
  @device_code "FAKE-1234"
  @claude_url "https://claude.com/cai/oauth/authorize?code=true&state=fake-agent-host"
  @claude_code "fake-claude-login-code#fake-state"
  @claude_account "owner@example.com"
  @claude_plan "max"
  @claude_modes [:ok, :no_subscription, :timeout]
  @report_after_ms 500
  @rejoin_after_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The device code a fake codex login shows."
  def device_code, do: @device_code

  @doc "The device URL a fake codex login shows."
  def device_url, do: @device_url

  @doc "The one code a fake Claude login accepts."
  def claude_login_code, do: @claude_code

  @doc "The account and plan a fake Claude login reports."
  def claude_login_account, do: %{account: @claude_account, plan: @claude_plan}

  @doc "Every mode of the fake Claude login, the default first."
  def claude_login_modes, do: @claude_modes

  @doc """
  The fake host's `agent.claude_login` reply to a Claude login command, before
  the channel's sanitising, or nil for no reply at all. Pure; shared with the
  test stand-in (`Platform.FakeAgentHost`). `mode` is one of
  `claude_login_modes/0`.
  """
  @spec claude_login_reply(String.t(), map(), atom()) :: map() | nil
  def claude_login_reply(_event, _payload, :timeout), do: nil

  def claude_login_reply("agent.claude_login_start", _payload, _mode),
    do: %{"result" => "url", "url" => @claude_url}

  def claude_login_reply("agent.claude_login_code", %{"code" => %LoginCode{} = code}, mode) do
    cond do
      LoginCode.reveal(code) != @claude_code -> %{"result" => "bad_code"}
      mode == :no_subscription -> %{"result" => "no_subscription"}
      true -> %{"result" => "ok", "account" => @claude_account, "plan" => @claude_plan}
    end
  end

  def claude_login_reply("agent.claude_login_code", _payload, _mode),
    do: %{"result" => "bad_code"}

  def claude_login_reply("agent.claude_logout", _payload, _mode), do: %{"result" => "ok"}

  @doc """
  Switch the fake Claude login (`claude_login_modes/0`). `:ok`, or
  `{:error, :unknown_mode | :not_running}`.
  """
  @spec set_claude_login(atom(), GenServer.server()) ::
          :ok | {:error, :unknown_mode | :not_running}
  def set_claude_login(mode, server \\ __MODULE__) do
    cond do
      mode not in @claude_modes -> {:error, :unknown_mode}
      GenServer.whereis(server) -> GenServer.call(server, {:claude_login_mode, mode})
      true -> {:error, :not_running}
    end
  end

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
      claude_logged_in: MapSet.new(),
      claude_login: :ok,
      report_after_ms: Keyword.get(opts, :report_after_ms, @report_after_ms),
      endpoint: Keyword.get(opts, :endpoint, PlatformWeb.Endpoint),
      # The hello's `features` (agent-host host.ts HOST_FEATURES); `[]` stands
      # in for a host built before Claude login.
      features: Keyword.get(opts, :features, ["claude_login"]),
      reconciler: nil
    }

    {:ok, state, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state), do: {:noreply, join(state)}

  @impl true
  def handle_call({:claude_login_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | claude_login: mode}}

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

  def handle_info({:agent_host_push, event, %{"agent_id" => id, "ref" => ref} = payload}, state)
      when event in ["agent.claude_login_start", "agent.claude_login_code", "agent.claude_logout"] do
    case claude_login_reply(event, payload, state.claude_login) do
      nil ->
        {:noreply, state}

      reply ->
        # Through the real channel handler's sanitising, as the host's reply would be.
        PlatformWeb.AgentHostChannel.handle_in(
          "agent.claude_login",
          Map.merge(%{"ref" => ref, "agent_id" => id}, reply),
          %Phoenix.Socket{}
        )

        if reply["result"] == "ok" and event == "agent.claude_login_code" do
          # The real host restarts the unit, which then reads running; every
          # later start reads running too (the credentials persist).
          report(id, %{"agent_id" => id, "state" => "running"})
          {:noreply, %{state | claude_logged_in: MapSet.put(state.claude_logged_in, id)}}
        else
          {:noreply, state}
        end
    end
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

  def observation(id, _agent, state) do
    if MapSet.member?(state.claude_logged_in, id),
      do: %{"agent_id" => id, "state" => "running"},
      else: needs_login(id)
  end

  defp needs_login(id),
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

  # It joins only once the Endpoint is up (task 01a10315 stage 6): joining
  # converges every native agent, and an `agent.start` broadcasts the runtime
  # disconnect through the Endpoint, which at boot is not started yet (the
  # reconciler crashed on it at every dev boot).
  defp join(state) do
    case {GenServer.whereis(Reconciler), Process.whereis(state.endpoint)} do
      {pid, endpoint} when is_nil(pid) or is_nil(endpoint) ->
        Process.send_after(self(), :rejoin, @rejoin_after_ms)
        state

      {pid, _endpoint} ->
        with :ok <-
               Reconciler.host_joined(self(), %{"profile" => "fake", "features" => state.features}),
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
