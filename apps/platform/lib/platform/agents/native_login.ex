defmodule Platform.Agents.NativeLogin do
  @moduledoc """
  How a native (install-managed) agent logs in to its model provider (task
  01a10322 stage 6).

  ## What ships: an Anthropic API key, and nothing else

  Claude Code 2.1.295 (the CLI the agent host pins) has no subscription login
  that finishes on its own. `claude auth login` prints a claude.com authorize
  URL whose redirect is Anthropic's code page, then waits at "Paste code here
  if prompted >". The only other variant redirects to `localhost:<port>`, so it
  finishes only in a browser on the agent's own machine. (Measured on the test rig on
  2026-10-09; see the org journal for that date.)

  Anthropic's Claude Code terms say developers "may not collect, store, or
  intermediate Claude.ai credentials or session tokens", and that sign-in must
  complete through Anthropic's own flow. A Burrow field that took the pasted
  code and relayed it to the agent's pane would be exactly that. So Burrow
  OFFERS NO SUBSCRIPTION LOGIN: the detail pane says it is not available yet,
  and the way in is an Anthropic API key.

  **No Burrow surface accepts a Claude login code.** There is no paste field,
  no event that takes one, and nothing in core, the agent host or suite-cli
  that types into an agent's pane. `api_key_shape/1` refuses anything that is
  not shaped like an Anthropic API key, so a login code cannot be stored as
  one by mistake.

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
  """

  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Vault

  @slug "anthropic-api-key"
  @env_name "ANTHROPIC_API_KEY"

  @doc "The Vault slug an agent's Anthropic API key is stored under."
  def slug, do: @slug

  @doc "The environment variable the key reaches the agent as."
  def env_name, do: @env_name

  @doc """
  Can this harness log in with an API key here? Claude Code only: Codex is
  not offered on this install yet.
  """
  @spec api_key_harness?(String.t() | nil) :: boolean()
  def api_key_harness?("claude_code"), do: true
  def api_key_harness?(_), do: false

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
  """
  @spec start_env(Agent.t()) :: %{optional(String.t()) => String.t()}
  def start_env(%Agent{} = agent) do
    with %AgentRuntime{harness: harness} <- NativeAgents.get_managed_runtime(agent),
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
  """
  @spec step(map() | nil, boolean()) :: :needs_key | :key_refused | :waiting | :logged_in | :idle
  def step(%{state: :needs_login}, false), do: :needs_key
  def step(%{state: :needs_login}, true), do: :key_refused
  def step(%{state: :starting}, true), do: :waiting
  def step(%{state: :running}, true), do: :logged_in
  def step(_observed, _key_set?), do: :idle

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
