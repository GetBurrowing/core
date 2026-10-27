defmodule Platform.Agents.Burrow do
  @moduledoc """
  The install's own native agent, "Burrow" (task 01a17b10, stage 2): a Claude
  Code agent every install with an owner and an `AGENT_HOST_TOKEN` gets, acting
  as the orchestrator / infra desk.

  ## Creation: `ensure/1`

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

  The owner is the earliest root-org admin (by membership insert time); admins
  are every root-org admin. `admins_section/0` reads them from the database
  each time and renders name and principal id (the user id). `start_files/1`
  in `NativeAgents` appends that section to Burrow's instructions file, so
  every `agent.start` carries the current list and a removed admin is gone at
  the next start. The section is generated, never stored.

  ## Hook

  `ensure_async/0` is called after a user is inserted
  (`Platform.Accounts.find_or_create_from_oidc/1`), from a supervised
  one-shot task, so a failure there never breaks login.
  """

  import Ecto.Query
  require Logger

  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @name "Burrow"
  @slug "burrow"
  @harness "claude_code"

  @doc "The agent's display name."
  def name, do: @name

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

  @doc "Root-org admins as `%{id, name}`, earliest membership first."
  @spec admins() :: [%{id: String.t(), name: String.t()}]
  def admins do
    case Tenancy.get_root_org() do
      nil ->
        []

      org ->
        from(m in OrgMembership,
          join: u in Platform.Accounts.User,
          on: u.id == m.user_id,
          where: m.org_id == ^org.id and m.role == "admin" and is_nil(u.archived_at),
          order_by: [asc: m.inserted_at, asc: m.id],
          select: %{id: u.id, name: u.name}
        )
        |> Repo.all()
    end
  end

  @doc "The install owner: the earliest root-org admin, or nil."
  def owner, do: List.first(admins())

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

  @doc "Burrow's CLAUDE.md template: role and the bundles it uses."
  @spec identity_template(String.t()) :: String.t()
  def identity_template(name \\ @name) do
    NativeAgents.identity_template(name, @harness) <>
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
      """
  end
end
