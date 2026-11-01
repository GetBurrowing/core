defmodule Platform.Agents.Burrow do
  @moduledoc """
  The install's own native agent, "Burrow" (task 01a17b10, stage 2): a Claude
  Code agent every install with an owner and an `AGENT_HOST_TOKEN` gets, acting
  as the orchestrator / infra desk.

  ## The install's first agent: `ensure/2` (task 01a19505)

  `ensure/2` creates, or reuses, the ONE native agent named "Burrow" (slug
  `burrow`) with the harness the owner chose on `/setup/connect-ai`, and starts
  it. The harness follows the connect option (`harness_for/1`): ChatGPT
  (Codex) runs `codex`; an API key and a Claude Pro or Max subscription run
  `claude_code`. A Burrow that is already running keeps its harness; one that
  is not running and runs a different harness is stopped, switched
  (`NativeAgents.set_harness/2`) and started. Whatever the harness, its
  instructions file carries the role and the setup guide
  (`identity_template/2`). On an empty install it is the first external agent,
  so it takes the first-agent grant (`Platform.Federation.provision_agent_runtime/3`).

  The "Getting started" space it opens once connected lives in
  `Platform.Agents.Burrow.GettingStarted`.

  ## Creation at boot / user insert: `ensure/1` (removed in stage 2 of 01a19505)

  `ensure/1` is idempotent. It is a logged no-op when the install has no
  `AGENT_HOST_TOKEN` or no owner, and a no-op when a Burrow already exists.
  Otherwise it calls `Platform.Agents.NativeAgents.create/2`, which goes through
  `Platform.Federation.provision_agent_runtime/3`. There is NO second grant
  path: the first-agent grant is that function's existing rule.

    * On an empty install Burrow is the first external agent, so it gets
      `metadata.first_agent_grant = true` and a tool profile equal to
      `Platform.Federation.first_agent_bundles/0`.
    * If a federated agent already exists, Burrow is still created but does NOT
      take the first-agent grant; it gets
      `Platform.Agents.AgentRuntime.default_tool_profile/0`.

  Burrow does not touch the login mode: it runs under the install's
  `Platform.Agents.NativeLogin.login_mode/0` (shipped default `api_key`).

  ## Owner and admins

  The owner is `Platform.Accounts.install_owner/0` (the earliest non-archived
  root-org admin); admins are `Platform.Accounts.install_admins/0`. `admins_section/0` reads them from the database
  each time and renders name and principal id (the user id). `start_files/1`
  in `NativeAgents` appends that section to Burrow's instructions file, so
  every `agent.start` carries the current list and a removed admin is gone at
  the next start. The section is generated, never stored.

  ## Hooks

  `run_at_boot/0` runs once at boot from a supervised one-shot, so installs that
  already have users get Burrow too.

  `ensure_async/0` is called after a user is inserted
  (`Platform.Accounts.find_or_create_from_oidc/1`), from a supervised
  one-shot task, so a failure there never breaks login.
  """

  require Logger

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}

  @name "Burrow"
  @slug "burrow"
  @harness "claude_code"

  @doc "The agent's display name."
  def name, do: @name

  @doc "The harness each connect option runs."
  @spec harness_for(atom()) :: String.t()
  def harness_for(:codex), do: "codex"
  def harness_for(:api_key), do: "claude_code"
  def harness_for(:claude_subscription), do: "claude_code"

  @doc "The Burrow agent's runtime harness, or nil."
  @spec harness(Agent.t() | nil) :: String.t() | nil
  def harness(nil), do: nil

  def harness(%Agent{} = agent) do
    case NativeAgents.get_managed_runtime(agent) do
      %AgentRuntime{harness: harness} -> harness
      nil -> nil
    end
  end

  @doc "True when the Burrow agent exists and the agent host reports it running."
  @spec connected?() :: boolean()
  def connected?, do: running?(get())

  @doc "True when `agent` is observed running."
  @spec running?(Agent.t() | nil) :: boolean()
  def running?(nil), do: false
  def running?(%Agent{} = agent), do: match?(%{state: :running}, AgentHost.status(agent))

  @doc """
  Create or reuse the Burrow agent owned by `owner_id`, running `harness`, and
  start it. A Burrow that is already running keeps its harness; one that is
  not running and runs a different harness is switched. Returns `{:ok, agent}`
  or `{:error, reason}`.
  """
  @spec ensure(binary(), String.t()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure(owner_id, harness) when is_binary(owner_id) and harness in ~w(claude_code codex) do
    case get() do
      nil ->
        create(owner_id, harness)

      %Agent{} = agent ->
        cond do
          running?(agent) ->
            {:ok, agent}

          harness(agent) == harness ->
            start(agent)

          true ->
            switch(agent, harness)
        end
    end
  end

  defp create(owner_id, harness) do
    case NativeAgents.create(owner_id, %{name: @name, harness: harness}) do
      {:ok, agent, _runtime} ->
        start(agent)

      {:error, reason} ->
        # Lost a race with another tab: the agent the winner made is ours too.
        case get() do
          %Agent{} = agent -> ensure(owner_id, harness_or(agent, harness))
          nil -> {:error, reason}
        end
    end
  end

  defp harness_or(agent, fallback), do: harness(agent) || fallback

  defp switch(agent, harness) do
    _ = AgentHost.stop_agent(agent)

    case NativeAgents.set_harness(agent, harness) do
      {:ok, _runtime} -> start(agent)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start(agent) do
    # Not connected to a host is not an error here: the screen says so, and
    # the reconciler starts the agent when the host joins.
    _ = AgentHost.start_agent(agent)
    {:ok, agent}
  end

  @doc """
  The OS account the agent host runs `agent` as: `agent-<last 12 hex of its
  id>` (services/agent-host/src/ids.ts `userName`; the tail, because the head
  of a UUIDv7 is a clock).
  """
  @spec os_user(Agent.t()) :: String.t()
  def os_user(%Agent{id: id}), do: "agent-" <> String.slice(id, -12, 12)

  @doc """
  Create Burrow if this install needs one. Returns `{:ok, :created, agent}`,
  `{:ok, :exists, agent}`, `{:ok, :skipped, reason}` or `{:error, reason}`.
  """
  @spec ensure(keyword()) ::
          {:ok, :created | :exists, Agent.t()} | {:ok, :skipped, atom()} | {:error, term()}
  def ensure(_opts \\ []) do
    cond do
      not Platform.AgentHost.configured?() ->
        Logger.warning("[Burrow] no AGENT_HOST_TOKEN, not creating the Burrow agent")
        {:ok, :skipped, :no_agent_host_token}

      is_nil(owner()) ->
        Logger.info("[Burrow] install has no owner yet, not creating the Burrow agent")
        {:ok, :skipped, :no_owner}

      agent = get() ->
        {:ok, :exists, agent}

      true ->
        create_for(owner())
    end
  end

  defp create_for(owner) do
    case NativeAgents.create(owner.id, %{name: @name, harness: @harness}) do
      {:ok, agent, _runtime} -> {:ok, :created, agent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Boot-time entry point (supervised one-shot, `:transient`): create Burrow on
  an install that already has users. Never raises. Guarded by
  `AGENT_HOST_TOKEN` and at least one root admin, both checked in `ensure/1`.
  """
  @spec run_at_boot() :: :ok
  def run_at_boot do
    case ensure() do
      {:error, reason} -> Logger.warning("[Burrow] boot ensure failed: #{inspect(reason)}")
      _ -> :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("[Burrow] boot ensure crashed: #{Exception.message(e)}")
      :ok
  end

  @doc "Run `ensure/1` in a supervised one-shot task; failures are logged, never raised."
  @spec ensure_async() :: :ok
  def ensure_async do
    if Platform.AgentHost.configured?() do
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        try do
          case ensure() do
            {:error, reason} -> Logger.warning("[Burrow] ensure failed: #{inspect(reason)}")
            _ -> :ok
          end
        rescue
          # A test's sandbox owner can be gone by the time this runs.
          DBConnection.OwnershipError -> :ok
          e -> Logger.warning("[Burrow] ensure crashed: #{Exception.message(e)}")
        end
      end)
    end

    :ok
  end

  @doc "The Burrow agent (a native agent with slug `burrow`), or nil."
  @spec get() :: Agent.t() | nil
  def get do
    Enum.find_value(NativeAgents.list(), fn %{agent: a} -> a.slug == @slug && a end)
  end

  @doc "True when `agent` is the Burrow agent."
  def burrow?(%Agent{slug: @slug} = agent), do: NativeAgents.managed?(agent)
  def burrow?(_), do: false

  @doc "Root-org admins as `%{id, name}`; see `Platform.Accounts.install_admins/0`."
  defdelegate admins, to: Platform.Accounts, as: :install_admins

  @doc "The install owner; see `Platform.Accounts.install_owner/0`."
  defdelegate owner, to: Platform.Accounts, as: :install_owner

  @doc "The generated owner / admins section appended to Burrow's instructions file."
  @spec admins_section() :: String.t()
  def admins_section do
    admins = admins()

    owner_line =
      case admins do
        [o | _] -> "- Owner: #{o.name} (principal #{o.id})"
        [] -> "- Owner: none"
      end

    admin_lines =
      case admins do
        [] -> ["- none"]
        list -> Enum.map(list, &"- #{&1.name} (principal #{&1.id})")
      end

    """

    ## Owner and admins (generated at start)

    #{owner_line}

    Admins of this install:

    #{Enum.join(admin_lines, "\n")}
    """
  end

  @doc """
  Burrow's instructions file (`CLAUDE.md` or `AGENTS.md`) for `harness`: the
  shared native-agent identity, its role and bundles, and the setup guide.
  """
  @spec identity_template(String.t(), String.t()) :: String.t()
  def identity_template(name, harness) do
    NativeAgents.identity_template(name, harness) <>
      """

      ## Your role

      You are the orchestrator and infra desk for this install. You plan and route
      work, keep the machine and its services healthy, and answer for the install's
      state to its owner and admins (listed at the end of this file).

      ## Bundles you use

      - `task` and `plan`: read tasks, draft and submit plans.
      - `messaging` and `space`: talk to people and agents in spaces.
      - `memory`: keep durable notes about this install.
      - `context_read`: read shared context.
      - `admin`: install administration, when your tool profile includes it.

      Use only what your profile gives you.

      ## Helping your owner finish setup

      You are the first agent on a new install, and your owner may not be technical.
      In the "Getting started" space, help them finish setting up, one step at a time:

      1. Ask what their business does and which tools they already use (email,
         calendar, files, chat). Suggest connecting the ones that matter most first.
      2. Help them create a first space for real work, and say what it is for.
      3. Offer to add more agents later, once the first space is in use.

      Use plain words, not technical ones. Never ask them to open a terminal. When a
      step needs their consent or a sign-in, give them the link or button in Burrow
      and wait for them to finish it; never do it for them.
      """
  end
end
