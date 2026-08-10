defmodule Platform.Chat.SpaceAgentPresence do
  @moduledoc """
  Computes individual agent status and composite status for a space's roster.

  ## Individual status

  Derives from RuntimePresence (for external agents) and process health
  (for built-in agents):

    * `:active`  — connected and responsive
    * `:idle`    — connected but not engaged
    * `:busy`    — executing a run/task
    * `:error`   — linked (or previously running) and actually broken
    * `:offline` — linked at some point, not present right now
    * `:absent`  — never linked to any runtime at all

  ### Absent is deliberately not error

  An external agent with no runtime record has never been linked. That is a
  fact about *configuration*, not about health: nothing has failed, because
  nothing was ever connected. Classifying it `:error` (the previous
  behaviour) meant a single never-linked federated agent on any roster pinned
  the indicator red permanently. `:error` is no longer reachable from the
  external clause; only a linked agent that is genuinely broken earns it.

  ## Composite status (healthy-over-total ratio)

  `composite/1` returns `%{healthy:, total:, state:}`. `total` counts every
  roster status *including* `:absent` — absent agents belong in the
  denominator, because "9/12 linked" is exactly the number the ratio exists
  to communicate. `healthy` counts `:active`, `:idle` and `:busy`. `state` is
  derived from the ratio:

    * `:none`     — `total == 0`
    * `:error`    — any status is `:error`
    * `:healthy`  — `healthy == total`
    * `:degraded` — otherwise

  ### This reverses a documented decision

  This ratio replaced a documented worst-wins fold (`:error` absorbed
  everything) because worst-wins made the indicator stop varying: one bad
  agent out of twenty read identically to twenty bad agents, so the signal
  carried no information. It is not a fold someone broke — it was removed on
  purpose, and a one-bit composite must not be reintroduced.
  """

  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
  alias Platform.Federation.RuntimePresence

  @doc """
  Determine the runtime status of an individual agent.
  """
  @spec agent_status(Agent.t()) :: :active | :idle | :busy | :error | :offline | :absent
  def agent_status(%Agent{runtime_type: "external"} = agent) do
    # Use the same logic as Agent Resources: get_runtime_for_agent returns the
    # AgentRuntime struct whose runtime_id is the connection string — not the
    # UUID stored on agent.runtime_id.
    case Platform.Federation.get_runtime_for_agent(agent) do
      # Never linked to any runtime: a configuration fact, not a failure.
      nil -> :absent
      runtime -> if RuntimePresence.online?(runtime.runtime_id), do: :active, else: :offline
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

  @healthy_statuses [:active, :idle, :busy]

  @typedoc "Healthy-over-total roster summary. See the moduledoc for why this replaced a fold."
  @type composite :: %{
          healthy: non_neg_integer(),
          total: non_neg_integer(),
          state: :healthy | :degraded | :error | :none
        }

  @doc """
  Summarise a list of individual statuses as a healthy-over-total ratio.

  Pure function. `total` includes `:absent` — see the moduledoc.
  """
  @spec composite([atom()]) :: composite()
  def composite(statuses) when is_list(statuses) do
    total = length(statuses)
    healthy = Enum.count(statuses, &(&1 in @healthy_statuses))

    state =
      cond do
        total == 0 -> :none
        Enum.any?(statuses, &(&1 == :error)) -> :error
        healthy == total -> :healthy
        true -> :degraded
      end

    %{healthy: healthy, total: total, state: state}
  end

  @doc """
  Composite state atom only. Thin delegate over `composite/1` for callers that
  assign a bare atom.
  """
  @spec composite_status([atom()]) :: :healthy | :degraded | :error | :none
  def composite_status(statuses) when is_list(statuses), do: composite(statuses).state

  @doc """
  Compute the composite ratio for a space by querying its roster and
  checking each agent's runtime status.
  """
  @spec composite_for_space(binary()) :: composite()
  def composite_for_space(space_id) do
    space_id
    |> Chat.list_active_space_agents()
    |> Enum.map(fn sa -> agent_status(sa.agent) end)
    |> composite()
  end

  @doc """
  Composite state atom for a space. Thin delegate over `composite_for_space/1`.
  """
  @spec composite_status_for_space(binary()) :: :healthy | :degraded | :error | :none
  def composite_status_for_space(space_id), do: composite_for_space(space_id).state

  @doc """
  Build a list of `{space_agent, status}` tuples for UI rendering.
  """
  @spec roster_with_status(binary()) :: [{Chat.roster_entry(), atom()}]
  def roster_with_status(space_id) do
    space_id
    |> Chat.list_space_agents()
    |> Enum.map(fn entry ->
      status = agent_status(entry.agent)
      {entry, status}
    end)
  end

  @doc """
  Human-readable label for an individual status.

  `:absent` reads "never linked" rather than the bare atom: "absent" invites
  the reading "it went away", when the fact is that it was never connected in
  the first place. Every other status is already a word a reader can use.
  """
  @spec status_label(atom()) :: String.t()
  def status_label(:absent), do: "never linked"
  def status_label(status) when is_atom(status), do: Atom.to_string(status)

  @doc "Return the brand semantic text color class for a given status."
  @spec status_color(atom()) :: String.t()
  def status_color(:error), do: "text-error"
  def status_color(:healthy), do: "text-success"
  def status_color(:active), do: "text-success"
  def status_color(:degraded), do: "text-warning"
  def status_color(:busy), do: "text-warning"
  def status_color(:idle), do: "text-warning"
  def status_color(_), do: "text-neutral"

  @doc """
  Return the brand semantic dot color class for a composite or individual status.

  `:absent`, `:offline` and `:none` share the neutral token: nothing is wrong,
  there is simply nothing connected to report on.
  """
  @spec dot_color(atom()) :: String.t()
  def dot_color(:error), do: "bg-error"
  def dot_color(:healthy), do: "bg-success"
  def dot_color(:active), do: "bg-success"
  def dot_color(:degraded), do: "bg-warning"
  def dot_color(:busy), do: "bg-warning"
  def dot_color(:idle), do: "bg-warning"
  def dot_color(_), do: "bg-neutral"
end
