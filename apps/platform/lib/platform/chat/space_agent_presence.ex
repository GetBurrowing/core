defmodule Platform.Chat.SpaceAgentPresence do
  @moduledoc """
  Computes individual agent status and composite status for a space's roster.

  ## Individual status

  Derives from RuntimePresence (for external agents) and process health
  (for built-in agents):

    * `:active`  — connected and responsive
    * `:idle`    — connected but not engaged
    * `:busy`    — executing a run/task
    * `:error`   — disconnected, crashed, or unresponsive
    * `:offline` — not running

  ## Composite status (worst wins)

  Folds over all non-dismissed roster entries:

    * `:error`  — any agent is in error state
    * `:busy`   — no errors, any agent is busy
    * `:active` — all agents healthy, at least one active
    * `:idle`   — all agents idle
    * `:none`   — no active agents in roster
  """

  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
  alias Platform.Federation.RuntimePresence

  @doc """
  Determine the runtime status of an individual agent.
  """
  @spec agent_status(Agent.t()) :: :active | :idle | :busy | :error | :offline
  def agent_status(%Agent{runtime_type: "external"} = agent) do
    if agent.runtime_id && RuntimePresence.online?(agent.runtime_id) do
      :active
    else
      :error
    end
  end

  def agent_status(%Agent{} = agent) do
    case AgentServer.whereis(agent) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :active, else: :error

      nil ->
        :offline
    end
  end

  def agent_status(_), do: :offline

  @doc """
  Compute the composite status for all non-dismissed agents in a space.

  Pure function — folds over a list of individual statuses.
  """
  @spec composite_status([atom()]) :: :error | :busy | :active | :idle | :none
  def composite_status(statuses) when is_list(statuses) do
    Enum.reduce(statuses, :none, fn
      :error, _acc -> :error
      _any, :error -> :error
      :busy, acc when acc != :error -> :busy
      _any, :busy -> :busy
      :active, acc when acc not in [:error, :busy] -> :active
      _any, :active -> :active
      :idle, :none -> :idle
      _any, acc -> acc
    end)
  end

  @doc """
  Compute composite status for a space by querying its roster and
  checking each agent's runtime status.
  """
  @spec composite_status_for_space(binary()) :: :error | :busy | :active | :idle | :none
  def composite_status_for_space(space_id) do
    space_id
    |> Chat.list_active_space_agents()
    |> Enum.map(fn sa -> agent_status(sa.agent) end)
    |> composite_status()
  end

  @doc """
  Build a list of `{space_agent, status}` tuples for UI rendering.
  """
  @spec roster_with_status(binary()) :: [{Chat.SpaceAgent.t(), atom()}]
  def roster_with_status(space_id) do
    space_id
    |> Chat.list_space_agents()
    |> Enum.map(fn sa ->
      status = if sa.role == "dismissed", do: :dismissed, else: agent_status(sa.agent)
      {sa, status}
    end)
  end

  @doc "Return the CSS color class for a given status."
  @spec status_color(atom()) :: String.t()
  def status_color(:error), do: "text-red-500"
  def status_color(:busy), do: "text-blue-500"
  def status_color(:active), do: "text-green-500"
  def status_color(:idle), do: "text-green-400"
  def status_color(:offline), do: "text-zinc-500"
  def status_color(:none), do: "text-zinc-500"
  def status_color(_), do: "text-zinc-500"

  @doc "Return the dot color class for composite status."
  @spec dot_color(atom()) :: String.t()
  def dot_color(:error), do: "bg-red-500"
  def dot_color(:busy), do: "bg-blue-500"
  def dot_color(:active), do: "bg-green-500"
  def dot_color(:idle), do: "bg-green-400"
  def dot_color(:none), do: "bg-zinc-500"
  def dot_color(_), do: "bg-zinc-500"
end
