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

  ## Claude subscription login: one pending login per agent (task 01a1b365)

  `claude_login_start/4` records a pending login for the agent, bound to the
  user who started it AND the process that asked (the owner's LiveView), and
  pushes `agent.claude_login_start`. While it is pending, a start by anyone
  else is refused `:busy`, and `claude_login_code/5` takes a code only from
  that same user and process (`:forbidden` otherwise, `:no_session` when
  nothing is pending). The pending login ends when its code is pushed, when
  the starter's process exits, when `claude_login_end/2` is called, on logout,
  or after 10 minutes, the host's own idle limit
  (services/agent-host/src/claude_login.ts `IDLE_MS`).

  The pending record holds ids, a pid, a monitor and a ref: never the sign-in
  URL or the code. The code (a `Platform.AgentHost.LoginCode`) passes through
  this process inside one call and is put into the push to the host channel,
  which unwraps it as it serialises the push. Nothing here stores, logs or
  broadcasts it.
  """

  use GenServer

  require Logger

  alias Platform.AgentHost.{LoginCode, State}
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents, NativeLogin}
  alias Platform.Federation
  alias Platform.Role.Peer

  @status_topic "agent_host:status"
  # The host ends a login nobody finished after 10 minutes (claude_login.ts IDLE_MS).
  @login_ttl_ms 10 * 60_000

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

  @doc """
  Restart an agent: stop it and start it again with a fresh token. With a
  `ref`, the host answers `agent.restarted` under it once the agent is back
  (or the wait ran out), carrying the tool snapshots taken before and after
  (task 01a17b1c stage 4).
  """
  @spec restart(binary(), String.t() | nil) :: :ok | {:error, term()}
  def restart(agent_id, ref \\ nil), do: GenServer.call(server(), {:restart, agent_id, ref})

  @doc "Ask the host for the last `lines` log lines of an agent, answered under `ref`."
  @spec request_logs(binary(), pos_integer(), String.t()) :: :ok | {:error, :not_connected}
  def request_logs(agent_id, lines, ref),
    do: GenServer.call(server(), {:logs, agent_id, lines, ref})

  @doc "Ask the host for the last `lines` pane lines of an agent, answered under `ref`."
  @spec request_pane(binary(), pos_integer(), String.t()) :: :ok | {:error, :not_connected}
  def request_pane(agent_id, lines, ref),
    do: GenServer.call(server(), {:pane, agent_id, lines, ref})

  @doc "Ask the host for one file of an agent's work dir (redacted by the host), answered under `ref`."
  @spec request_file(binary(), String.t(), String.t()) :: :ok | {:error, :not_connected}
  def request_file(agent_id, key, ref),
    do: GenServer.call(server(), {:file, agent_id, key, ref})

  @doc "Ask the host whether an agent's API key still works, answered under `ref`."
  @spec request_auth_check(binary(), String.t()) :: :ok | {:error, :not_connected}
  def request_auth_check(agent_id, ref),
    do: GenServer.call(server(), {:check_auth, agent_id, ref})

  @doc """
  Push any command `event` to the host (task 01a17b10 stage 3); the host
  answers with `host.reply` under the `ref` carried in `payload`.
  """
  @spec host_call(String.t(), map()) :: :ok | {:error, :not_connected}
  def host_call(event, payload) when is_binary(event) and is_map(payload),
    do: GenServer.call(server(), {:host_call, event, payload})

  @doc """
  Record a pending Claude login for `agent_id`, bound to `actor_id` and
  `caller`, and ask the host to start one, answered under `ref`. `:ok`, or
  `{:error, :busy}` while someone else's login is pending for that agent, or
  `{:error, :not_connected}`, or `{:error, :host_outdated}` when the connected
  host's hello does not list the `claude_login` feature: a host built before
  Claude login ignores the push, so nothing is pushed and the caller hears so
  at once rather than after its whole timeout.
  """
  @spec claude_login_start(binary(), binary(), pid(), String.t()) ::
          :ok | {:error, :busy | :not_connected | :host_outdated}
  def claude_login_start(agent_id, actor_id, caller, ref),
    do: GenServer.call(server(), {:claude_login_start, agent_id, actor_id, caller, ref})

  @doc """
  Push `code` into `agent_id`'s pending Claude login, answered under `ref`.
  Taken only from the user and process that started that login; the pending
  login then ends. `:ok`, or `{:error, :no_session | :forbidden |
  :not_connected}`.
  """
  @spec claude_login_code(binary(), binary(), pid(), String.t(), LoginCode.t()) ::
          :ok | {:error, :no_session | :forbidden | :not_connected}
  def claude_login_code(agent_id, actor_id, caller, ref, %LoginCode{} = code),
    do: GenServer.call(server(), {:claude_login_code, agent_id, actor_id, caller, ref, code})

  @doc "End `agent_id`'s pending Claude login if it is the one started under `ref`."
  @spec claude_login_end(binary(), String.t()) :: :ok
  def claude_login_end(agent_id, ref),
    do: GenServer.call(server(), {:claude_login_end, agent_id, ref})

  @doc "End any pending Claude login for `agent_id` and ask the host to log it out, answered under `ref`."
  @spec claude_logout(binary(), String.t()) :: :ok | {:error, :not_connected}
  def claude_logout(agent_id, ref), do: GenServer.call(server(), {:claude_logout, agent_id, ref})

  @doc false
  # Whether a Claude login is pending for `agent_id` (tests).
  @spec claude_login_pending?(binary()) :: boolean()
  def claude_login_pending?(agent_id),
    do: GenServer.call(server(), {:claude_login_pending?, agent_id})

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
    {:ok, %{host: nil, logins: %{}}}
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
      State.put_host(Map.take(host, [:profile, :connected_at, :full_root]))
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

  defp do_call({:restart, _agent_id, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:restart, agent_id, ref}, _from, state) do
    extra = if is_binary(ref), do: %{"ref" => ref}, else: %{}

    case native_entry(agent_id) do
      nil -> {:reply, {:error, :not_managed}, state}
      entry -> {:reply, send_start(state.host, entry, "agent.restart", extra), state}
    end
  end

  defp do_call({:logs, _agent_id, _lines, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:logs, agent_id, lines, ref}, _from, state) do
    push(state.host, "agent.logs", %{"agent_id" => agent_id, "lines" => lines, "ref" => ref})
    {:reply, :ok, state}
  end

  defp do_call({:file, _agent_id, _key, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:file, agent_id, key, ref}, _from, state) do
    push(state.host, "agent.file_read", %{"agent_id" => agent_id, "key" => key, "ref" => ref})
    {:reply, :ok, state}
  end

  defp do_call({:check_auth, _agent_id, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:check_auth, agent_id, ref}, _from, state) do
    push(state.host, "agent.check_auth", %{"agent_id" => agent_id, "ref" => ref})
    {:reply, :ok, state}
  end

  defp do_call({:host_call, _event, _payload}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:host_call, event, payload}, _from, state) do
    push(state.host, event, payload)
    {:reply, :ok, state}
  end

  defp do_call({:claude_login_pending?, agent_id}, _from, state) do
    {:reply, live_login(state, agent_id) != nil, state}
  end

  defp do_call(
         {:claude_login_start, _agent_id, _actor, _caller, _ref},
         _from,
         %{host: nil} = state
       ),
       do: {:reply, {:error, :not_connected}, state}

  defp do_call(
         {:claude_login_start, _agent_id, _actor, _caller, _ref},
         _from,
         %{host: %{features: features}} = state
       )
       when not is_map_key(features, "claude_login"),
       do: {:reply, {:error, :host_outdated}, state}

  defp do_call({:claude_login_start, agent_id, actor_id, caller, ref}, _from, state) do
    case live_login(state, agent_id) do
      %{actor_id: other_actor, caller: other_caller}
      when other_actor != actor_id or other_caller != caller ->
        {:reply, {:error, :busy}, state}

      _mine_or_none ->
        # A second start by the same caller replaces the first; so does the
        # host, which ends a running login on a new start.
        state = drop_login(state, agent_id)

        login = %{
          actor_id: actor_id,
          caller: caller,
          monitor: Process.monitor(caller),
          ref: ref,
          started_at: System.monotonic_time(:millisecond)
        }

        push(state.host, "agent.claude_login_start", %{"agent_id" => agent_id, "ref" => ref})
        {:reply, :ok, put_in(state.logins[agent_id], login)}
    end
  end

  defp do_call(
         {:claude_login_code, _agent_id, _actor, _caller, _ref, _code},
         _from,
         %{host: nil} = state
       ),
       do: {:reply, {:error, :not_connected}, state}

  defp do_call({:claude_login_code, agent_id, actor_id, caller, ref, code}, _from, state) do
    case live_login(state, agent_id) do
      nil ->
        {:reply, {:error, :no_session}, drop_login(state, agent_id)}

      %{actor_id: ^actor_id, caller: ^caller} ->
        # The host ends its login after one code, whatever the outcome, so the
        # pending login ends here too.
        push(state.host, "agent.claude_login_code", %{
          "agent_id" => agent_id,
          "ref" => ref,
          "code" => code
        })

        {:reply, :ok, drop_login(state, agent_id)}

      _someone_else ->
        {:reply, {:error, :forbidden}, state}
    end
  end

  defp do_call({:claude_login_end, agent_id, ref}, _from, state) do
    case Map.get(state.logins, agent_id) do
      %{ref: ^ref} -> {:reply, :ok, drop_login(state, agent_id)}
      _ -> {:reply, :ok, state}
    end
  end

  defp do_call({:claude_logout, _agent_id, _ref}, _from, %{host: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  defp do_call({:claude_logout, agent_id, ref}, _from, state) do
    state = drop_login(state, agent_id)
    push(state.host, "agent.claude_logout", %{"agent_id" => agent_id, "ref" => ref})
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

  # The process that started a pending Claude login went away: so does the login.
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Enum.find(state.logins, fn {_agent_id, login} -> login.monitor == mref end) do
      {agent_id, _login} -> {:noreply, %{state | logins: Map.delete(state.logins, agent_id)}}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────

  defp join(pid, meta, state) do
    ref = Process.monitor(pid)

    host = %{
      pid: pid,
      ref: ref,
      profile: string_or_nil(meta["profile"]),
      # The host's hello says whether the install enabled `[agents] full_root`.
      full_root: meta["full_root"] == true,
      # Commands the host handles beyond the original set (agent-host
      # host.ts HOST_FEATURES). A host older than the list sends none.
      features: features(meta["features"]),
      connected_at: DateTime.utc_now()
    }

    State.clear()
    State.put_host(Map.take(host, [:profile, :connected_at, :full_root]))
    broadcast(:host_connected)
    {:reply, :ok, %{state | host: host}}
  end

  defp features(list) when is_list(list),
    do: for(f <- list, is_binary(f), into: %{}, do: {f, true})

  defp features(_), do: %{}

  defp drop_host(%{host: host} = state) do
    Process.demonitor(host.ref, [:flush])
    State.clear()
    broadcast(:host_disconnected)
    # A host that goes away takes its running logins with it.
    for {_agent_id, login} <- state.logins, do: Process.demonitor(login.monitor, [:flush])
    %{state | host: nil, logins: %{}}
  end

  # The pending login for `agent_id`, or nil when there is none or it outlived
  # the host's idle limit.
  defp live_login(state, agent_id) do
    case Map.get(state.logins, agent_id) do
      %{started_at: at} = login ->
        if System.monotonic_time(:millisecond) - at < @login_ttl_ms, do: login, else: nil

      nil ->
        nil
    end
  end

  defp drop_login(state, agent_id) do
    case Map.pop(state.logins, agent_id) do
      {nil, _} ->
        state

      {login, logins} ->
        Process.demonitor(login.monitor, [:flush])
        %{state | logins: logins}
    end
  end

  defp host?(%{host: %{pid: pid}}, pid), do: true
  defp host?(_state, _pid), do: false

  defp host_pid_of(%{host: %{pid: pid}}), do: pid
  defp host_pid_of(_), do: nil

  defp record_observation(%{"agent_id" => agent_id, "state" => raw} = payload, profile)
       when is_binary(agent_id) do
    case State.parse_state(raw) do
      {:ok, observed} ->
        # `payload["login"]` is read for ONE thing (task 01a10315 stage 4):
        # Codex's device login. Anything else a host sends there, a Claude
        # login page or code above all, is never stored or passed on (task
        # 01a17b10).
        device = device_login(observed, payload["login"])

        State.put(agent_id, observed, %{
          detail: string_or_nil(payload["detail"]),
          files_applied: payload["files_applied"],
          files_drifted: drifted_list(payload["files_drifted"]),
          profile: profile,
          login_code: device[:code],
          device_url: device[:url]
        })

        {:ok, agent_id}

      :error ->
        :error
    end
  end

  defp record_observation(_payload, _profile), do: :error

  @device_code ~r/\A[A-Z0-9-]{4,16}\z/

  @doc """
  The Codex device login an observation carries, as `%{url: url, code: code}`,
  or `%{}`. Kept only when the agent is `needs_login` at step `device_code`,
  the code matches `^[A-Z0-9-]{4,16}$` and the URL is https on
  `auth.openai.com`, exactly as `codex login --device-auth` prints it
  (services/agent-host/src/codex_login.ts). Otherwise both are dropped: a
  code that does not fit is not shown with a URL, nor a URL without its code.
  """
  @spec device_login(State.observed() | term(), term()) ::
          %{url: String.t(), code: String.t()} | %{}
  def device_login(:needs_login, %{"step" => "device_code", "code" => code, "url" => url})
      when is_binary(code) and is_binary(url) do
    if Regex.match?(@device_code, code) and openai_device_url?(url),
      do: %{url: url, code: code},
      else: %{}
  end

  def device_login(_observed, _login), do: %{}

  defp openai_device_url?(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "auth.openai.com",
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil
      } ->
        true

      _ ->
        false
    end
  end

  defp drifted_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp drifted_list(_), do: nil

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

  defp send_start(host, entry, event, extra \\ %{})

  defp send_start(host, %{agent: agent, runtime: %AgentRuntime{} = runtime}, event, extra) do
    case Federation.generate_runtime_token(runtime) do
      {:ok, updated, raw_token} ->
        # Any socket still on the previous token goes; it no longer
        # authenticates a reconnect either.
        PlatformWeb.Endpoint.broadcast("runtime:#{updated.runtime_id}", "disconnect", %{})

        push(
          host,
          event,
          %{
            "agent_id" => agent.id,
            "runtime_id" => updated.runtime_id,
            "runtime_token" => raw_token,
            "harness" => updated.harness,
            "core_url" => Platform.AgentHost.core_url(),
            # The agent's own login (stage 6): its Anthropic API key, if one is
            # saved, read from the Vault as the agent at this moment. It goes
            # into this push and, on the host, into that agent's 0600 env file
            # only. Never logged. In operator login mode (task 01a17b10) this
            # is `%{}` and the Vault is not read.
            "env" => NativeLogin.start_env(agent),
            # The agent's own files (stage 5), written into its work dir as its
            # uid before the unit starts. Read at this moment, so a Restart
            # always carries the latest save.
            "files" => NativeAgents.start_files(agent),
            # Drifted keys the owner has resolved; the host overwrites no other.
            "force_keys" => NativeAgents.force_keys(agent)
          }
          |> Map.merge(extra)
        )

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

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
