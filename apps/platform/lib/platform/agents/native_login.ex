defmodule Platform.Agents.NativeLogin do
  @moduledoc """
  How a native (install-managed) agent logs in to its model provider (task
  01a10322 stage 6).

  ## What ships: an Anthropic API key, or the owner's own Claude sign-in

  Claude Code 2.1.295 (the CLI the agent host pins) has no subscription login
  that finishes on its own. `claude auth login` prints a claude.com authorize
  URL whose redirect is Anthropic's code page, then waits at "Paste code here
  if prompted >". The only other variant redirects to `localhost:<port>`, so it
  finishes only in a browser on the agent's own machine. (Measured on the test
  rig on 2026-10-09 and again for task 01a1b365; see the org journal.)

  Anthropic's Claude Code terms
  (code.claude.com/docs/en/legal-and-compliance) say developers "may not
  collect, store, or intermediate Claude.ai credentials or session tokens",
  and that sign-in must complete through Anthropic's own flow. Task 01a1b365
  replaces task 01a17b10's "no Burrow surface accepts a Claude login code"
  with this narrower rule, for an owner logging in THEIR OWN agent on the
  same install:

    * sign-in itself happens on Anthropic's page, in the owner's browser. The
      URL comes from the agent's own, unmodified `claude auth login` on the
      agent host (`Platform.AgentHost.claude_login_start/3`), whose PKCE
      verifier the code is bound to;
    * the code that page shows is pasted once and passes through core's
      process for ONE request, `agent.claude_login_code`, to the agent host on
      the same install, over the install's agents network (core is reached as
      `core-platform` only inside its container networks, config/prod.exs),
      which writes it to that login's stdin
      (`Platform.AgentHost.claude_login_submit/4`);
    * it is held as a `Platform.AgentHost.LoginCode`, which never prints, and
      is never persisted, logged, broadcast, audited, put in
      `Platform.AgentHost.State` or returned by a tool. The reply carries the
      account and plan only;
    * only `NativeAgents.can_manage?/2` may start or finish one, checked in
      core, and a code goes only into the login its own caller started.

  `api_key_shape/1` still refuses anything that is not shaped like an
  Anthropic API key, so a login code cannot be stored as one by mistake.

  An API key saved for the agent wins over a subscription login (it is in the
  agent's env file at its next start, and Claude Code prefers it), so an
  agent with a saved key stays on `:api_key` in `login_view/1`.

  ## The API key

    * Stored with `Platform.Vault.put/4`, scope `{:agent, agent_id}`, slug
      `anthropic-api-key`: encrypted at rest, one per agent.
    * Read only by `start_env/1`, as the agent itself (`accessor: {:agent,
      agent_id}`), when the reconciler builds that agent's `agent.start`.
    * Delivered ONLY in that agent's env file (`/etc/burrow-agents/<id>.env`,
      0600, owned by the agent's uid), as `ANTHROPIC_API_KEY`. Never in the
      agent's files, the agent host's own environment or another agent's unit.
    * suite-cli answers Claude Code's "use this API key?" confirmation only for
      the key in the agent's own environment.
    * Never logged, never put in an assign, never rendered.

  Only `NativeAgents.can_manage?/2` may set or remove it.

  ## Login mode: `api_key` (default) or `operator` (task 01a17b10 stage 1)

  Install config, `config :platform, :native_agent_login`, set from the env
  `NATIVE_AGENT_LOGIN` (the installer renders it from the manifest's
  `[agents] login`). `api_key` is the shipped default and what an unset or
  unrecognised value means. `operator` is opt-in: the agent carries NO API key
  (`start_env/1` returns `%{}` without reading the Vault, even when a key is
  saved), its pane waits at Claude Code's own login, and a human operator
  attaches to that pane and logs in there (README, "Operator login"). In this
  mode Burrow never sees, relays or stores the login code or the login URL.
  """

  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Vault

  @slug "anthropic-api-key"
  @env_name "ANTHROPIC_API_KEY"

  @modes [:api_key, :operator]

  @doc """
  The install's native-agent login mode: `:api_key` unless the install opted in
  to `:operator` (`config :platform, :native_agent_login`, env
  `NATIVE_AGENT_LOGIN`). Anything other than exactly `operator` is `:api_key`.
  """
  @spec login_mode() :: :api_key | :operator
  def login_mode, do: parse_mode(Application.get_env(:platform, :native_agent_login))

  @doc "Every login mode, the default first."
  def login_modes, do: @modes

  @doc "True when the install runs native agents in operator login mode."
  @spec operator?() :: boolean()
  def operator?, do: login_mode() == :operator

  defp parse_mode(:operator), do: :operator
  defp parse_mode("operator"), do: :operator
  defp parse_mode(_), do: :api_key

  @doc """
  The command an operator runs to reach a native agent's pane, as a template:
  placeholders only, filled in by the person. Mirrors how the host reads the
  pane (services/agent-host/src/pane.ts `captureArgv`); see the agent-host
  README, "Operator login".
  """
  @spec attach_command_template() :: String.t()
  def attach_command_template do
    "docker exec -it <agent-host container> " <>
      "runuser -u agent-<12 hex> -- " <>
      "env TMUX_TMPDIR=/run/burrow-agents/<agent id> tmux attach -t suite-agent"
  end

  @doc "The Vault slug an agent's Anthropic API key is stored under."
  def slug, do: @slug

  @doc "The environment variable the key reaches the agent as."
  def env_name, do: @env_name

  @doc """
  Can this harness log in with an Anthropic API key here? Claude Code only.
  Codex logs in with its own device login instead (`device_login?/1`).
  """
  @spec api_key_harness?(String.t() | nil) :: boolean()
  def api_key_harness?("claude_code"), do: true
  def api_key_harness?(_), do: false

  @doc """
  Does this harness log in with a device code the owner enters on the
  provider's own page (task 01a10315 stage 4)? Codex only: `codex login
  --device-auth` runs on the agent host as the agent, prints an
  auth.openai.com URL and a one-time code, and finishes by itself once the
  person approves there. Burrow shows the code and relays nothing back.

  Claude Code has no such login: its subscription login finishes only when
  the code Anthropic's page shows is pasted back. Burrow takes that code from
  the owner and passes it, for one request, to the agent's own login on the
  agent host on the same install (task 01a1b365; the rule is in this
  module's doc, under Anthropic's terms at
  code.claude.com/docs/en/legal-and-compliance). That is not a device login:
  false.
  """
  @spec device_login?(String.t() | nil) :: boolean()
  def device_login?("codex"), do: true
  def device_login?(_), do: false

  @typedoc "What the owner is shown to log an agent in (`login_view/1`)."
  @type login_view ::
          %{kind: :device_code, url: String.t() | nil, code: String.t() | nil}
          | %{kind: :claude_subscription, account: String.t() | nil, plan: String.t() | nil}
          | :api_key
          | :subscription_terminal_only
          | :unsupported

  @doc """
  How `agent` logs in, for a screen to render:

    * `%{kind: :device_code, url: url, code: code}` for Codex. `url` and
      `code` are the ones the agent host last observed
      (`Platform.AgentHost.State`, kept only in the shapes the reconciler
      accepts), or nil until the host has printed one. Display only.
    * `%{kind: :claude_subscription, account: account, plan: plan}` for Claude
      Code in the default `:api_key` login mode when no API key is saved: the
      owner signs in on Anthropic's page and pastes the code
      (`Platform.AgentHost.claude_login_start/3` and `claude_login_submit/4`).
      `account` and `plan` come from the `login` given, the `{:ok, %{account,
      plan}}` of a submit; nil until then. Nothing about a Claude login is
      read from the host's observed state.
    * `:api_key` for Claude Code in the `:api_key` login mode when an
      Anthropic API key is saved (`put_api_key/3`): the key wins over a
      subscription login.
    * `:subscription_terminal_only` for Claude Code in `:operator` mode: a
      Claude Pro or Max login happens at a terminal on the agent's machine,
      never through Burrow.
    * `:unsupported` for an agent this install does not run or a harness it
      does not know.
  """
  @spec login_view(Agent.t(), %{account: String.t(), plan: String.t()} | nil) :: login_view()
  def login_view(%Agent{} = agent, login \\ nil) do
    case NativeAgents.get_managed_runtime(agent) do
      %AgentRuntime{harness: harness} ->
        key_set? = api_key_harness?(harness) and api_key_set?(agent)

        login_view(harness, Platform.AgentHost.status(agent.id), login_mode(),
          key_set?: key_set?,
          login: login
        )

      nil ->
        :unsupported
    end
  end

  @doc """
  `login_view/1` from a harness, an observed entry, a login mode and `opts`:
  `key_set?` (an Anthropic API key is saved; default false) and `login` (a
  submit's `%{account, plan}`, or nil). Pure.
  """
  @spec login_view(String.t() | nil, map() | nil, :api_key | :operator, keyword()) ::
          login_view()
  def login_view(harness, observed, mode, opts \\ []) do
    cond do
      device_login?(harness) ->
        observed = observed || %{}

        %{
          kind: :device_code,
          url: Map.get(observed, :device_url),
          code: Map.get(observed, :login_code)
        }

      api_key_harness?(harness) and mode == :operator ->
        :subscription_terminal_only

      api_key_harness?(harness) and Keyword.get(opts, :key_set?, false) ->
        :api_key

      api_key_harness?(harness) ->
        login = Keyword.get(opts, :login) || %{}

        %{
          kind: :claude_subscription,
          account: string_or_nil(Map.get(login, :account)),
          plan: string_or_nil(Map.get(login, :plan))
        }

      true ->
        :unsupported
    end
  end

  @doc """
  `:ok` when `value` is shaped like an Anthropic API key: one token, starting
  `sk-ant-`, 28 to 512 characters of letters, digits, `-` and `_`. Anything
  else, including a Claude login code, is refused.
  """
  @spec api_key_shape(term()) :: :ok | {:error, :invalid_api_key}
  def api_key_shape(value) when is_binary(value) do
    if byte_size(value) in 28..512 and Regex.match?(~r/\Ask-ant-[A-Za-z0-9_-]+\z/, value),
      do: :ok,
      else: {:error, :invalid_api_key}
  end

  def api_key_shape(_), do: {:error, :invalid_api_key}

  @doc "True when `agent` has an Anthropic API key saved. Reads metadata only."
  @spec api_key_set?(Agent.t()) :: boolean()
  def api_key_set?(%Agent{id: id}) do
    [scope: {:agent, id}]
    |> Vault.list()
    |> Enum.any?(&(&1.slug == @slug))
  end

  @doc """
  Save `key` as `agent`'s Anthropic API key, as `actor`. Replaces a key
  already saved. Refused, storing nothing, with:

    * `{:error, :not_managed}` for an agent this install does not run;
    * `{:error, :forbidden}` unless `NativeAgents.can_manage?(actor, agent)`,
      checked before anything about the key;
    * `{:error, :unsupported_harness}` for a harness other than Claude Code;
    * `{:error, :invalid_api_key}` unless `api_key_shape/1` accepts it.

  Returns `:ok`; the key is never returned.
  """
  @spec put_api_key(map() | binary() | nil, Agent.t(), term()) ::
          :ok
          | {:error, :not_managed | :forbidden | :unsupported_harness | :invalid_api_key | term()}
  def put_api_key(actor, %Agent{} = agent, key) do
    key = if is_binary(key), do: String.trim(key), else: key

    with {:ok, runtime} <- managed_runtime(agent),
         true <- NativeAgents.can_manage?(actor, agent) || {:error, :forbidden},
         true <- api_key_harness?(runtime.harness) || {:error, :unsupported_harness},
         :ok <- api_key_shape(key) do
      store(agent, key)
    end
  end

  @doc """
  Remove `agent`'s Anthropic API key, as `actor`. `:ok` when there was none.
  Refused like `put_api_key/3`.
  """
  @spec remove_api_key(map() | binary() | nil, Agent.t()) ::
          :ok | {:error, :not_managed | :forbidden | term()}
  def remove_api_key(actor, %Agent{} = agent) do
    with {:ok, _runtime} <- managed_runtime(agent),
         true <- NativeAgents.can_manage?(actor, agent) || {:error, :forbidden} do
      case Vault.delete(@slug, scope: {:agent, agent.id}, accessor: {:agent, agent.id}) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The env `agent.start` carries for `agent`: `%{"ANTHROPIC_API_KEY" => key}`
  when a key is saved and the harness is Claude Code, else `%{}`. Read as the
  agent itself, at the moment of the start. The result goes into the start
  command and nowhere else.

  In `:operator` login mode it is always `%{}` and the Vault is not read.

  One exception, in both modes: an agent marked as running on Burrow's starter
  allowance (`Platform.Agents.Burrow.Starter`) gets the install's starter key
  as `ANTHROPIC_API_KEY`, read from config, not the Vault. It stops the moment
  the agent is retired from the starter.
  """
  @spec start_env(Agent.t()) :: %{optional(String.t()) => String.t()}
  def start_env(%Agent{} = agent) do
    case Platform.Agents.Burrow.Starter.key_for(agent) do
      nil -> vault_env(agent)
      key -> %{@env_name => key}
    end
  end

  defp vault_env(agent) do
    with :api_key <- login_mode(),
         %AgentRuntime{harness: harness} <- NativeAgents.get_managed_runtime(agent),
         true <- api_key_harness?(harness),
         {:ok, key} <- Vault.get(@slug, scope: {:agent, agent.id}, accessor: {:agent, agent.id}) do
      %{@env_name => key}
    else
      _ -> %{}
    end
  end

  @doc """
  Which login step the detail pane shows for a managed agent, from its
  observed state and whether a key is saved:

    * `:needs_key` — the agent is waiting for a login and no key is saved;
    * `:key_refused` — it is waiting for a login although a key is saved (the
      key did not reach it, or Claude Code did not take it);
    * `:waiting` — a key is saved and the agent is starting with it;
    * `:logged_in` — a key is saved and the agent is running;
    * `:idle` — anything else (stopped, crashed, no observation).

  In `:operator` mode (`step/3`) a saved key is irrelevant:

    * `:needs_operator` — the agent is waiting at Claude's login for a human
      to attach to its pane;
    * `:waiting` / `:logged_in` — starting / running;
    * `:idle` — anything else.
  """
  @spec step(map() | nil, boolean()) ::
          :needs_key | :needs_operator | :key_refused | :waiting | :logged_in | :idle
  def step(observed, key_set?), do: step(observed, key_set?, login_mode())

  @doc "`step/2` for an explicit login mode."
  @spec step(map() | nil, boolean(), :api_key | :operator) ::
          :needs_key | :needs_operator | :key_refused | :waiting | :logged_in | :idle
  def step(%{state: :needs_login}, _key_set?, :operator), do: :needs_operator
  def step(%{state: :starting}, _key_set?, :operator), do: :waiting
  def step(%{state: :running}, _key_set?, :operator), do: :logged_in
  def step(_observed, _key_set?, :operator), do: :idle
  def step(observed, key_set?, _api_key), do: api_key_step(observed, key_set?)

  defp api_key_step(%{state: :needs_login}, false), do: :needs_key
  defp api_key_step(%{state: :needs_login}, true), do: :key_refused
  defp api_key_step(%{state: :starting}, true), do: :waiting
  defp api_key_step(%{state: :running}, true), do: :logged_in
  defp api_key_step(_observed, _key_set?), do: :idle

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp managed_runtime(agent) do
    case NativeAgents.get_managed_runtime(agent) do
      nil -> {:error, :not_managed}
      runtime -> {:ok, runtime}
    end
  end

  defp store(agent, key) do
    opts = [scope: {:agent, agent.id}, accessor: {:agent, agent.id}]

    result =
      if api_key_set?(agent) do
        Vault.rotate(@slug, key, opts)
      else
        Vault.put(@slug, :api_key, key,
          scope: {:agent, agent.id},
          provider: "anthropic",
          name: "Anthropic API key"
        )
      end

    case result do
      {:ok, _credential} -> :ok
      {:error, %Ecto.Changeset{}} -> {:error, :not_saved}
      {:error, reason} -> {:error, reason}
    end
  end
end
