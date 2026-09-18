defmodule Platform.Responsibilities.Providers.Agents do
  @moduledoc """
  Provider shim for the `agents` feature (task `01a0b491` stage 3).

  The Router resolves a responsibility's provider through the explicit
  `feature -> module` registry in `Platform.Responsibilities.Providers`.
  Registering `Handlers.AgentsGoalHeartbeat` in `BuiltIns.providers/0`
  without an entry there would put the `agents` feature in exactly the
  state that registry was built to make visible: it fires, it dispatches,
  and the answer is discarded — and the boot-time
  `[ResponsibilityRegistry] provider_missing feature=agents` line is what
  said so out loud when this file did not exist.

  Structure mirrors `Providers.Architecture`, including its return
  contract: an unmapped key returns exactly `{:error, :no_build_prompt}`
  from `build_prompt/1`, which the Router reads as "fall back to the
  legacy template render". Any OTHER error value is read as a refusal
  that short-circuits the dispatch, so widening that clause would turn a
  routing miss into a dropped call.

  The one deliberate divergence: `AgentsGoalHeartbeat.build_prompt/1`
  DOES return a non-`:no_build_prompt` error — `{:error,
  {:no_measurement, reason}}` — and that refusal is intended. A goal
  that cannot name a number has no heartbeat, and a content-free ping is
  the failure this feature exists to prevent.

  Keys owned here:

    * `agents.goal_heartbeat` → `Handlers.AgentsGoalHeartbeat`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: AgentsGoalHeartbeat.register()

  @doc """
  Return the concrete handler module for a responsibility (or key), or
  `nil` for any key this feature does not own.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("agents.goal_heartbeat"), do: Handlers.AgentsGoalHeartbeat
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{} = responsibility, ctx) when is_map(ctx) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.handle_output(responsibility, parsed)
    end
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      nil -> {:error, :no_build_prompt}
      handler -> handler.build_prompt(context)
    end
  end

  def build_prompt(_), do: {:error, :no_build_prompt}

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[agents provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Agents.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_agents_responsibility}
  end
end
