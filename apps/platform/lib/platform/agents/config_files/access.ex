defmodule Platform.Agents.ConfigFiles.Access do
  @moduledoc """
  Who may read and write an agent's configuration files.

  ## Native agents (install-managed)

  `NativeAgents.can_manage?/2`: the runtime owner OR an install root admin.
  Root admins keep edit rights (a sponsor ruling on task 01a17b1c).

  ## Federated agents

  The decision is a product, never a bare boolean:

      (federation kind) x (opt-in)

    * kind: `runtime_kind/1`. Today only `:own_agent_in_member_install`;
      anything else is hard-off through
      `Platform.Federation.RemoteAccess.allowed_kind?/1`, with no override.
    * opt-in: chosen on the agent's machine and sent in the host's hello:
      `:off` (default, nothing allowed), `:owner_only` (the runtime owner),
      `:admins` (the owner plus install root admins).

  The remote terminal (task 01a17b17) shares `RemoteAccess` for the kind
  lock, so the two surfaces cannot disagree about which kinds are ever
  permitted. The CLI enforces the opt-in on its side as well (stage 3); core
  refuses first.

  An agent token is never an actor here: it is `{:error, :forbidden}`
  everywhere.
  """

  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Federation
  alias Platform.Federation.{RemoteAccess, RuntimeHosts}
  alias Platform.Tenancy

  @opt_ins [:off, :owner_only, :admins]

  @type ctx :: %{
          agent: Agent.t(),
          runtime: AgentRuntime.t(),
          actor: map(),
          backend: :workspace_store | :host,
          adapter: module(),
          opt_in: atom() | nil
        }

  @doc "Every opt-in level."
  def opt_ins, do: @opt_ins

  @doc """
  The federation kind of a runtime. A runtime whose owner is a member of this
  install is the member's own agent; an owner who is not (or no owner) is
  `:other_federation`, which is hard-off.
  """
  @spec runtime_kind(term()) :: RemoteAccess.kind()
  def runtime_kind(%AgentRuntime{owner_user_id: owner}) when is_binary(owner) do
    if Tenancy.root_member?(%{id: owner}),
      do: :own_agent_in_member_install,
      else: :other_federation
  end

  def runtime_kind(_), do: :other_federation

  @doc """
  The pure decision: may `role` (`:owner`, `:admin` or `:other`) edit a
  federated agent of `kind` whose host opted in at `opt_in`?
  """
  @spec decide(term(), term(), :owner | :admin | :other) :: boolean()
  def decide(kind, opt_in, role) do
    RemoteAccess.permitted?(kind, opt_in in [:owner_only, :admins]) and
      case {opt_in, role} do
        {:owner_only, :owner} -> true
        {:admins, r} when r in [:owner, :admin] -> true
        _ -> false
      end
  end

  @doc "True for a signed-in person. An agent, an agent token or a bare map is not."
  @spec user_actor?(term()) :: boolean()
  def user_actor?(%Agent{}), do: false

  def user_actor?(%{id: id} = actor) when is_binary(id) do
    Map.get(actor, :actor_type) not in ["agent", :agent] and Map.get(actor, :type) != :agent and
      not Map.has_key?(actor, :agent_id)
  end

  def user_actor?(_), do: false

  @doc "Authorize `actor` for `agent`'s config. Returns the context the backends use."
  @spec authorize(term(), Agent.t() | nil) :: {:ok, ctx()} | {:error, atom()}
  def authorize(actor, %Agent{} = agent) do
    runtime = Federation.get_runtime_for_agent(agent)

    cond do
      not user_actor?(actor) -> {:error, :forbidden}
      is_nil(runtime) -> {:error, :forbidden}
      runtime.managed_by == "install" -> native(actor, agent, runtime)
      true -> federated(actor, agent, runtime)
    end
  end

  def authorize(_actor, _agent), do: {:error, :forbidden}

  defp native(actor, agent, runtime) do
    with true <- NativeAgents.can_manage?(actor, agent) || {:error, :forbidden},
         {:ok, adapter} <- adapter(runtime.harness) do
      {:ok,
       %{
         agent: agent,
         runtime: runtime,
         actor: actor,
         backend: :workspace_store,
         adapter: adapter,
         opt_in: nil
       }}
    end
  end

  defp federated(actor, agent, runtime) do
    kind = runtime_kind(runtime)
    owner? = runtime.owner_user_id == actor.id
    admin? = not owner? and Tenancy.root_admin?(actor)
    host = RuntimeHosts.lookup(runtime.runtime_id)
    opt_in = if host, do: host.hello.config_opt_in, else: nil

    cond do
      not RemoteAccess.allowed_kind?(kind) ->
        {:error, :forbidden}

      not (owner? or admin?) ->
        {:error, :forbidden}

      is_nil(host) and owner? ->
        {:error, :host_offline}

      is_nil(host) ->
        {:error, :forbidden}

      decide(kind, opt_in, if(owner?, do: :owner, else: :admin)) ->
        with_adapter(actor, agent, runtime, host, opt_in)

      owner? and opt_in == :off ->
        {:error, :opt_in_required}

      true ->
        {:error, :forbidden}
    end
  end

  defp with_adapter(actor, agent, runtime, host, opt_in) do
    with {:ok, adapter} <- adapter(host.hello.harness) do
      {:ok,
       %{
         agent: agent,
         runtime: runtime,
         actor: actor,
         backend: :host,
         adapter: adapter,
         opt_in: opt_in
       }}
    end
  end

  defp adapter(harness) do
    case Platform.Agents.Harness.adapter_for(harness) do
      {:ok, mod} -> {:ok, mod}
      :unsupported -> {:error, :unsupported_harness}
    end
  end
end
