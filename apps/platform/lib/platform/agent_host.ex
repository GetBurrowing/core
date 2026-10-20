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
    * `agent.stop` `{agent_id}`;
    * `agent.logs` `{agent_id, lines, ref}`;
    * `agent.pane` `{agent_id, lines, ref}`: the agent's recent pane text, for
      the read-only "Recent output" disclosure (stage 6);
    * `agent.check_auth` `{agent_id, ref}`: does the agent's API key still
      work? Asked by the no-reply watchdog (stage 7 round 2,
      `Platform.Chat.ReplyFailure.Watchdog`).

  ## Events (host to core)

    * `host.inventory` `{profile, agents: [{agent_id, state, detail,
      files_applied}]}`. The host REPORTS its capability profile; core
      displays it and never branches on it. `files_applied` is
      `%{key => version}` as of the agent's last start, or nil;
    * `agent.state` `{agent_id, state, detail, files_applied}`;
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
