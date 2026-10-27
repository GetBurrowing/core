defmodule Platform.AgentHost do
  @moduledoc """
  Core's side of the install's AGENT HOST: the daemon that runs native agents
  (task 01a10322 stage 2).

  ## Who dials whom

  The host dials OUT to core, over `PlatformWeb.AgentHostSocket`
  (`/agent-host/websocket`), and core pushes commands down that channel. Core
  never reaches into the host: no container-runtime socket and no host D-Bus
  is mounted into core-platform, so core holds no capability over the
  machine. The host authenticates with `AGENT_HOST_TOKEN`; without it set,
  every connection is refused (`configured?/0`).

  ## What runs where

  On the host, every native agent is a systemd unit `burrow-agent@<agent_id>`
  running the real Claude Code CLI through suite-cli, as its own OS user
  (`agent-<short id>`). Per-agent users stop agents from crossing into each
  other BY ACCIDENT. They are not a security boundary: an install is one trust
  group, and an agent with sudo can read every other agent's files.

  ## Commands (core to host)

    * `agent.start` / `agent.restart` `{agent_id, runtime_id, runtime_token,
      harness, core_url, env, files}`, the token minted fresh every time;
      `files` is `[%{key, content, version}]` (`NativeAgents.start_files/1`),
      written into the agent's work dir AS THE AGENT before it launches;
      `force_keys` names the drifted keys (edited on disk by the agent since the
      host wrote them) the owner has resolved; the host overwrites no other
      drifted key (`NativeAgents.force_keys/1`);
    * `agent.stop` `{agent_id}`;
    * `agent.logs` `{agent_id, lines, ref}`;
    * `agent.pane` `{agent_id, lines, ref}`: the agent's recent pane text, for
      the read-only "Recent output" disclosure (stage 6);
    * `agent.file_read` `{agent_id, key, ref}`: one file of the work dir, redacted,
      answered by `agent.file` `{ref, content, sha256}` or `{ref, error}`;
    * `agent.restart` may carry a `ref`; the host then answers
      `agent.restarted` `{ref, agent_id, outcome, before, after}` with the tool
      snapshots (`restart_with_tools/2`);
    * `agent.check_auth` `{agent_id, ref}`: does the agent's API key still
      work? Asked by the no-reply watchdog (stage 7 round 2,
      `Platform.Chat.ReplyFailure.Watchdog`).

  ## Events (host to core)

    * `host.inventory` `{profile, agents: [{agent_id, state, detail,
      files_applied}]}`. The host REPORTS its capability profile; core
      displays it and never branches on it. `files_applied` is
      `%{key => version}` as of the agent's last start, or nil;
    * `agent.state` `{agent_id, state, detail, files_applied, files_drifted}`;
      `files_drifted` is the keys whose disk copy no longer matches what the host
      wrote;
    * `agent.log` `{ref, agent_id, lines}`;
    * `agent.pane` `{ref, agent_id, lines, hidden}`: `hidden` is `"login"` (and
      `lines` empty) while the pane shows a login screen;
    * `agent.auth` `{ref, agent_id, result}`: `"ok"`, `"rejected"` (the API
      answered 401; the host then also reports the agent `needs_login`) or
      `"unknown"` (no API key, as with a subscription login, or no answer).

  Observed state is broadcast on `"agent_host:status"` as
  `{:agent_host_status, event}`.
  """

  alias Platform.AgentHost.{Reconciler, Redact, State}
  alias Platform.Agents.{Agent, NativeAgents}

  @logs_timeout_ms 5_000
  # The host waits up to 90 s for the agent to come back, then probes.
  @restart_timeout_ms 120_000
  # The host's own request to the API times out at 8 s (auth.ts).
  @auth_timeout_ms 10_000

  @doc "The token the host must present, or nil when none is configured."
  @spec token() :: String.t() | nil
  def token do
    case Application.get_env(:platform, :agent_host_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @doc "True when this install has an `AGENT_HOST_TOKEN`."
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(token())

  @doc "True while an agent host is connected."
  @spec connected?() :: boolean()
  def connected?, do: is_pid(Reconciler.host_pid())

  @doc """
  The connected host, `%{profile, connected_at}`, or nil.
  """
  @spec host() :: map() | nil
  def host do
    cond do
      not connected?() -> nil
      Platform.Role.Peer.remote?() -> Platform.Role.Peer.read(State, :host, [], nil)
      true -> State.host()
    end
  end

  @doc """
  One line describing the host for the UI: "No agent host configured" when
  there is no `AGENT_HOST_TOKEN`, otherwise whether one is connected.
  """
  @spec describe() :: String.t()
  def describe do
    cond do
      not configured?() -> "No agent host configured"
      connected?() -> "Agent host connected"
      true -> "Agent host not connected"
    end
  end

  @doc """
  The URL agents reach core at, sent in every `agent.start`. Read per call
  from `config :platform, :agent_host_core_url` (`AGENT_HOST_CORE_URL`),
  falling back to the endpoint's URL.
  """
  @spec core_url() :: String.t()
  def core_url do
    case Application.get_env(:platform, :agent_host_core_url) do
      url when is_binary(url) and url != "" -> url
      _ -> PlatformWeb.Endpoint.url()
    end
  end

  @doc "Keep `agent` running: record the desire, then converge it."
  @spec start_agent(Agent.t()) :: :ok | {:error, term()}
  def start_agent(%Agent{} = agent), do: set_and_converge(agent, "running")

  @doc "Stop `agent` and keep it stopped."
  @spec stop_agent(Agent.t()) :: :ok | {:error, term()}
  def stop_agent(%Agent{} = agent), do: set_and_converge(agent, "stopped")

  @doc "Restart `agent` with a fresh token. Its desired state becomes running."
  @spec restart_agent(Agent.t()) :: :ok | {:error, term()}
  def restart_agent(%Agent{} = agent) do
    with {:ok, _runtime} <- NativeAgents.set_desired_state(agent, "running") do
      Reconciler.restart(agent.id)
    end
  end

  @doc """
  Restart `agent` and wait for the host's account of it (task 01a17b1c stage
  4): `{:ok, %{outcome, before, after}}`. The host takes a tool snapshot of the
  MCP servers the agent loads (as the agent's user) before it rewrites the
  files and after the agent is back; `before`/`after` are
  `%{"servers" => [...], "tools" => [...]}` or nil (a `needs_login` agent is
  not probed). `outcome` is `ready | needs_login | gone | timeout`.

  The same `agent.restart` command as `restart_agent/1`, with a `ref`; there is
  no second restart command.
  """
  @spec restart_with_tools(Agent.t(), keyword()) ::
          {:ok, %{outcome: String.t(), before: map() | nil, after: map() | nil}}
          | {:error, term()}
  def restart_with_tools(%Agent{} = agent, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @restart_timeout_ms)
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    topic = restart_topic(ref)
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)

    try do
      with {:ok, _runtime} <- NativeAgents.set_desired_state(agent, "running"),
           :ok <- Reconciler.restart(agent.id, ref) do
        receive do
          {:agent_host_restarted, ^ref, payload} ->
            {:ok,
             %{
               outcome: Map.get(payload, "outcome", "gone"),
               before: Map.get(payload, "before"),
               after: Map.get(payload, "after")
             }}
        after
          timeout -> {:error, :timeout}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Platform.PubSub, topic)
    end
  end

  @doc false
  def restart_topic(ref), do: "agent_host:restart:" <> ref

  @doc """
  What the host last reported for `agent` (or an agent id): `%{state, detail,
  files_applied, profile, observed_at}`, or nil when nothing is known — no
  host connected, or the host has not reported this agent.
  """
  @spec status(Agent.t() | binary()) :: State.entry() | nil
  def status(%Agent{id: id}), do: status(id)

  def status(agent_id) when is_binary(agent_id) do
    # Task 01a155a6 stage 4: the observed-state table belongs to the full
    # node's reconciler; a web node with a peer reads the peer's.
    if Platform.Role.Peer.remote?(),
      do: Platform.Role.Peer.read(State, :get, [agent_id], nil),
      else: State.get(agent_id)
  end

  @doc """
  The last `lines` journal lines of `agent`, asked of the host and waited for.
  """
  @spec logs(Agent.t() | binary(), keyword()) ::
          {:ok, [String.t()]} | {:error, :not_connected | :timeout}
  def logs(agent, opts \\ [])
  def logs(%Agent{id: id}, opts), do: logs(id, opts)

  def logs(agent_id, opts) when is_binary(agent_id) do
    lines = Keyword.get(opts, :lines, 200)
    timeout = Keyword.get(opts, :timeout, @logs_timeout_ms)
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    topic = logs_topic(ref)
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)

    try do
      with :ok <- Reconciler.request_logs(agent_id, lines, ref) do
        receive do
          {:agent_host_logs, ^ref, log_lines} -> {:ok, log_lines}
        after
          timeout -> {:error, :timeout}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Platform.PubSub, topic)
    end
  end

  @doc false
  def logs_topic(ref), do: "agent_host:logs:" <> ref

  @doc """
  The last `lines` lines of `agent`'s pane, for the read-only "Recent output"
  disclosure (stage 6), asked of the host and waited for.

  Returns `{:ok, %{lines: [String.t()], hidden: nil | :login}}`. While the
  pane shows a Claude login screen it is withheld whole (`hidden: :login`,
  no lines), and every line that does come back passes through
  `Platform.AgentHost.Redact.lines/1` here, whatever the host already did.
  The caller decides who may see it: only `NativeAgents.can_manage?/2`.
  """
  @spec recent_output(Agent.t() | binary(), keyword()) ::
          {:ok, %{lines: [String.t()], hidden: nil | :login}}
          | {:error, :not_connected | :timeout}
  def recent_output(agent, opts \\ [])
  def recent_output(%Agent{id: id}, opts), do: recent_output(id, opts)

  def recent_output(agent_id, opts) when is_binary(agent_id) do
    lines = Keyword.get(opts, :lines, 80)
    timeout = Keyword.get(opts, :timeout, @logs_timeout_ms)
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    topic = pane_topic(ref)
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)

    try do
      with :ok <- Reconciler.request_pane(agent_id, lines, ref) do
        receive do
          {:agent_host_pane, ^ref, payload} -> {:ok, Redact.pane(payload)}
        after
          timeout -> {:error, :timeout}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Platform.PubSub, topic)
    end
  end

  @doc false
  def pane_topic(ref), do: "agent_host:pane:" <> ref

  @doc """
  One file of `agent`'s work dir as the host sees it on disk, asked of the host
  and waited for: `{:ok, %{content, sha256}}`. The host redacts before it
  sends and `Platform.Agents.Config` redacts again. The sha256 is over the full
  on-disk bytes. Used so a conflict can show the disk copy (Compare).
  """
  @spec file_read(Agent.t() | binary(), String.t(), keyword()) ::
          {:ok, %{content: binary(), sha256: String.t()}}
          | {:error, :not_connected | :timeout | :not_found | :unreadable}
  def file_read(agent, key, opts \\ [])
  def file_read(%Agent{id: id}, key, opts), do: file_read(id, key, opts)

  def file_read(agent_id, key, opts) when is_binary(agent_id) do
    timeout = Keyword.get(opts, :timeout, @logs_timeout_ms)
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    topic = file_topic(ref)
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)

    try do
      with :ok <- Reconciler.request_file(agent_id, key, ref) do
        receive do
          {:agent_host_file, ^ref, %{"content" => c, "sha256" => s}}
          when is_binary(c) and is_binary(s) ->
            {:ok, %{content: c, sha256: s}}

          {:agent_host_file, ^ref, %{"error" => "not_found"}} ->
            {:error, :not_found}

          {:agent_host_file, ^ref, _} ->
            {:error, :unreadable}
        after
          timeout -> {:error, :timeout}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Platform.PubSub, topic)
    end
  end

  @doc false
  def file_topic(ref), do: "agent_host:file:" <> ref

  @doc """
  Ask the host whether `agent`'s API key still works, and wait for the answer:
  `{:ok, :ok | :rejected | :unknown}`.

  The host sends one request to the Anthropic API with the agent's own key,
  which is where Claude Code sends it. A subscription login is never checked
  (`:unknown`). Used by the no-reply watchdog to name the cause honestly.
  """
  @spec check_auth(Agent.t() | binary(), keyword()) ::
          {:ok, :ok | :rejected | :unknown} | {:error, :not_connected | :timeout}
  def check_auth(agent, opts \\ [])
  def check_auth(%Agent{id: id}, opts), do: check_auth(id, opts)

  def check_auth(agent_id, opts) when is_binary(agent_id) do
    timeout = Keyword.get(opts, :timeout, @auth_timeout_ms)
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    topic = auth_topic(ref)
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, topic)

    try do
      with :ok <- Reconciler.request_auth_check(agent_id, ref) do
        receive do
          {:agent_host_auth, ^ref, result} -> {:ok, parse_auth(result)}
        after
          timeout -> {:error, :timeout}
        end
      end
    after
      Phoenix.PubSub.unsubscribe(Platform.PubSub, topic)
    end
  end

  @doc false
  def auth_topic(ref), do: "agent_host:auth:" <> ref

  defp parse_auth("ok"), do: :ok
  defp parse_auth("rejected"), do: :rejected
  defp parse_auth(_), do: :unknown

  @doc "Subscribe the caller to observed-state changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Platform.PubSub, Reconciler.status_topic())

  defp set_and_converge(agent, desired) do
    with {:ok, _runtime} <- NativeAgents.set_desired_state(agent, desired) do
      case Reconciler.converge(agent.id) do
        # The desire is recorded; a host that connects later converges it.
        {:error, :not_connected} -> :ok
        other -> other
      end
    end
  end
end
