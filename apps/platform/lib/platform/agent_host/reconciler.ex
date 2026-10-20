defmodule Platform.AgentHost.Reconciler do
  @moduledoc """
  Converges native agents' OBSERVED state to their DESIRED state through the
  install's one agent host (task 01a10322 stage 2).

  ## What it holds

  The connected host's channel process (monitored), and the ETS table of
  observed state (`Platform.AgentHost.State`), which it creates and owns.
  Every command to the host is sent from here, so two callers cannot both
  start one agent: commands are serialised through this process.

  ## When it converges

    * when a host joins and reports `host.inventory`, for every native agent;
    * when a person changes an agent's desired state (`AgentHost.start_agent/1`,
      `stop_agent/1`), for that agent.

  NOT on every `agent.state` event. An agent the host reports `stopped` right
  after a start (the unit failed to come up) would otherwise be started again
  at once, minting a token each time, in a loop no person asked for. A
  `crashed` agent stays crashed until someone presses Restart (stage 4); the
  host's systemd unit already restarts a process that exits non-zero.

  The rules, for a native agent:

    * desired `running`, observed `stopped` or unknown: `agent.start`;
    * desired `stopped`, observed anything but `stopped`: `agent.stop`;
    * otherwise nothing.

  ## Tokens

  Every `agent.start` and `agent.restart` carries a runtime token minted at
  that moment by `Platform.Federation.generate_runtime_token/1`, which
  replaces the stored hash: the previous token stops authenticating. Core keeps
  only the hash. Any socket still connected on the old token is told to
  disconnect. The token is never logged.

  ## One host

  An install has one agent host. A second host joining while one is connected
  is refused.
  """

  use GenServer

  require Logger

  alias Platform.AgentHost.State
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents, NativeLogin}
  alias Platform.Federation
  alias Platform.Role.Peer

  @status_topic "agent_host:status"

  # ── Client ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "PubSub topic every observed-state change is broadcast on."
  def status_topic, do: @status_topic

  @doc "A host's channel process joins. Refused while another host is connected."
  @spec host_joined(pid(), map()) :: :ok | {:error, :already_connected}
  def host_joined(pid, meta \\ %{}), do: GenServer.call(server(), {:host_joined, pid, meta})

  @doc "The host's full report: its profile and every agent it runs."
  @spec inventory(pid(), map()) :: :ok | {:error, :not_host}
  def inventory(pid, payload), do: GenServer.call(server(), {:inventory, pid, payload})

  @doc """
  One agent's observed state changed.

  When the agent has just become `needs_login` or `crashed`, the message last
  delivered to its runtime gets its reply-failure notice
  (`Platform.Chat.ReplyFailure.notify_pending/1`), posted from the CALLER's
  process after the state is recorded, so a slow post never holds this
  server (stage 7).
  """
  @spec agent_state(pid(), map()) :: :ok | {:error, term()}
  def agent_state(pid, payload) do
    before = previous_state(payload)
    result = GenServer.call(server(), {:agent_state, pid, payload})

    with :ok <- result,
         %{"agent_id" => agent_id} <- payload,
         {:ok, now} when now in [:needs_login, :crashed] <- State.parse_state(payload["state"]),
         true <- before != now do
      _ = Platform.Chat.ReplyFailure.notify_pending(agent_id)
    end

    result
  end

  defp previous_state(%{"agent_id" => agent_id}) when is_binary(agent_id) do
    case State.get(agent_id) do
      %{state: state} -> state
      _ -> nil
    end
  end

  defp previous_state(_payload), do: nil

  @doc "Converge one agent (by id), or every native agent (`:all`)."
  @spec converge(binary() | :all) :: :ok | {:error, :not_connected}
  def converge(target), do: GenServer.call(server(), {:converge, target})

  @doc "Restart an agent: stop it and start it again with a fresh token."
  @spec restart(binary()) :: :ok | {:error, term()}
  def restart(agent_id), do: GenServer.call(server(), {:restart, agent_id})

  @doc "Ask the host for the last `lines` log lines of an agent, answered under `ref`."
  @spec request_logs(binary(), pos_integer(), String.t()) :: :ok | {:error, :not_connected}
  def request_logs(agent_id, lines, ref),
    do: GenServer.call(server(), {:logs, agent_id, lines, ref})

  @doc "Ask the host for the last `lines` pane lines of an agent, answered under `ref`."
  @spec request_pane(binary(), pos_integer(), String.t()) :: :ok | {:error, :not_connected}
  def request_pane(agent_id, lines, ref),
    do: GenServer.call(server(), {:pane, agent_id, lines, ref})

  @doc "Ask the host whether an agent's API key still works, answered under `ref`."
  @spec request_auth_check(binary(), String.t()) :: :ok | {:error, :not_connected}
  def request_auth_check(agent_id, ref),
    do: GenServer.call(server(), {:check_auth, agent_id, ref})

  @doc "The connected host's channel pid, or nil."
  @spec host_pid() :: pid() | nil
  def host_pid do
    cond do
      Peer.remote?() -> Peer.read(__MODULE__, :host_pid, [], nil)
      Process.whereis(__MODULE__) -> GenServer.call(__MODULE__, :host_pid)
      true -> nil
    end
  end

  # Task 01a155a6 stage 4. The host connects to the full node, so on a web
  # node with a cluster peer every command goes to the peer's reconciler
  # (`Platform.Role.Peer.server/1`); elsewhere, this node's.
  defp server, do: Peer.server(__MODULE__)

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    State.init_table()
    State.clear()
    {:ok, %{host: nil}}
  end

  @impl true
  def handle_call(msg, from, %{host: %{pid: pid}} = state) when is_pid(pid) do
    # A host whose process has died but whose :DOWN is still in the mailbox is
    # not connected; drop it before answering anything.
    if Process.alive?(pid),
      do: do_call(msg, from, state),
      else: do_call(msg, from, drop_host(state))
  end

  def handle_call(msg, from, state), do: do_call(msg, from, state)

  defp do_call(:host_pid, _from, state), do: {:reply, host_pid_of(state), state}

  defp do_call({:host_joined, pid, meta}, _from, %{host: %{pid: other}} = state)
       when other != pid do
    if Process.alive?(other) do
      {:reply, {:error, :already_connected}, state}
    else
      join(pid, meta, drop_host(state))
    end
  end

  defp do_call({:host_joined, pid, meta}, _from, state), do: join(pid, meta, state)

  defp do_call({:inventory, pid, payload}, _from, state) do
    if host?(state, pid) do
      profile = string_or_nil(payload["profile"])
      host = %{state.host | profile: profile}
      State.put_host(Map.take(host, [:profile, :connected_at]))
      State.clear_agents()

      for agent <- List.wrap(payload["agents"]), is_map(agent) do
        record_observation(agent, profile)
      end

      broadcast(:inventory)
      converge_all(host)
      {:reply, :ok, %{state | host: host}}
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  defp do_call({:agent_state, pid, payload}, _from, state) do
    if host?(state, pid) do
      case record_observation(payload, state.host.profile) do
        {:ok, agent_id} ->
          broadcast({:agent, agent_id})
          {:reply, :ok, state}

        :error ->
          {:reply, {:error, :invalid_state}, state}
      end
    else
      {:reply, {:error, :not_host}, state}
    end
  end

  defp do_call({:converge, _target}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:converge, :all}, _from, state) do
    converge_all(state.host)
    {:reply, :ok, state}
  end

  defp do_call({:converge, agent_id}, _from, state) do
    case native_entry(agent_id) do
      nil -> {:reply, {:error, :not_managed}, state}
      entry -> {:reply, converge_one(state.host, entry), state}
    end
  end

  defp do_call({:restart, _agent_id}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:restart, agent_id}, _from, state) do
    case native_entry(agent_id) do
      nil -> {:reply, {:error, :not_managed}, state}
      entry -> {:reply, send_start(state.host, entry, "agent.restart"), state}
    end
  end

  defp do_call({:logs, _agent_id, _lines, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:logs, agent_id, lines, ref}, _from, state) do
    push(state.host, "agent.logs", %{"agent_id" => agent_id, "lines" => lines, "ref" => ref})
    {:reply, :ok, state}
  end

  defp do_call({:check_auth, _agent_id, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:check_auth, agent_id, ref}, _from, state) do
    push(state.host, "agent.check_auth", %{"agent_id" => agent_id, "ref" => ref})
    {:reply, :ok, state}
  end

  defp do_call({:pane, _agent_id, _lines, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:pane, agent_id, lines, ref}, _from, state) do
    push(state.host, "agent.pane", %{"agent_id" => agent_id, "lines" => lines, "ref" => ref})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{host: %{ref: ref}} = state) do
    {:noreply, drop_host(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────

  defp join(pid, meta, state) do
    ref = Process.monitor(pid)

    host = %{
      pid: pid,
      ref: ref,
      profile: string_or_nil(meta["profile"]),
      connected_at: DateTime.utc_now()
    }

    State.clear()
    State.put_host(Map.take(host, [:profile, :connected_at]))
    broadcast(:host_connected)
    {:reply, :ok, %{state | host: host}}
  end

  defp drop_host(%{host: host} = state) do
    Process.demonitor(host.ref, [:flush])
    State.clear()
    broadcast(:host_disconnected)
    %{state | host: nil}
  end

  defp host?(%{host: %{pid: pid}}, pid), do: true
  defp host?(_state, _pid), do: false

  defp host_pid_of(%{host: %{pid: pid}}), do: pid
  defp host_pid_of(_), do: nil

  defp record_observation(%{"agent_id" => agent_id, "state" => raw} = payload, profile)
       when is_binary(agent_id) do
    case State.parse_state(raw) do
      {:ok, observed} ->
        State.put(agent_id, observed, %{
          detail: string_or_nil(payload["detail"]),
          files_applied: payload["files_applied"],
          login_url: login_url(observed, payload["login"]),
          profile: profile
        })

        {:ok, agent_id}

      :error ->
        :error
    end
  end

  defp record_observation(_payload, _profile), do: :error

  defp converge_all(host) do
    for entry <- NativeAgents.list(), do: converge_one(host, entry)
    :ok
  end

  defp converge_one(host, %{agent: %Agent{id: agent_id}, runtime: runtime} = entry) do
    observed = observed_state(agent_id)

    case {runtime.desired_state, observed} do
      {"running", state} when state in [nil, :stopped] -> send_start(host, entry, "agent.start")
      {"stopped", state} when state not in [nil, :stopped] -> send_stop(host, agent_id)
      _ -> :ok
    end
  end

  defp observed_state(agent_id) do
    case State.get(agent_id) do
      %{state: state} -> state
      nil -> nil
    end
  end

  defp send_start(host, %{agent: agent, runtime: %AgentRuntime{} = runtime}, event) do
    case Federation.generate_runtime_token(runtime) do
      {:ok, updated, raw_token} ->
        # Any socket still on the previous token goes; it no longer
        # authenticates a reconnect either.
        PlatformWeb.Endpoint.broadcast("runtime:#{updated.runtime_id}", "disconnect", %{})

        push(host, event, %{
          "agent_id" => agent.id,
          "runtime_id" => updated.runtime_id,
          "runtime_token" => raw_token,
          "harness" => updated.harness,
          "core_url" => Platform.AgentHost.core_url(),
          # The agent's own login (stage 6): its Anthropic API key, if one is
          # saved, read from the Vault as the agent at this moment. It goes
          # into this push and, on the host, into that agent's 0600 env file
          # only. Never logged.
          "env" => NativeLogin.start_env(agent),
          # The agent's own files (stage 5), written into its work dir as its
          # uid before the unit starts. Read at this moment, so a Restart
          # always carries the latest save.
          "files" => NativeAgents.start_files(agent)
        })

        State.put(agent.id, :starting, %{detail: nil})
        broadcast({:agent, agent.id})
        :ok

      {:error, reason} ->
        Logger.warning("[AgentHost] could not mint a runtime token for agent=#{agent.id}")
        {:error, reason}
    end
  end

  defp send_stop(host, agent_id) do
    push(host, "agent.stop", %{"agent_id" => agent_id})
    :ok
  end

  defp push(%{pid: pid}, event, payload), do: send(pid, {:agent_host_push, event, payload})

  # Through `NativeAgents.list/0`, not a lookup by id: an id that is not a
  # native agent's simply matches nothing.
  defp native_entry(agent_id) do
    Enum.find(NativeAgents.list(), fn %{agent: agent} -> agent.id == agent_id end)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Platform.PubSub, @status_topic, {:agent_host_status, event})
  end

  # The login page a `needs_login` agent reported (`login: {step, url}`), kept
  # only when it is an absolute https URL: it is rendered as a link, so any
  # other scheme (javascript:, data:, a relative path) is dropped.
  defp login_url(:needs_login, %{"url" => url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp login_url(_state, _login), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
