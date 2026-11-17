defmodule Platform.Responsibilities.Providers.Showrunner do
  @moduledoc """
  Provider shim for the `showrunner` feature (task 01a1eaf6 stage 3).

  Keys owned here, one handler each:

    * `showrunner.weekly_pitch` → `Handlers.ShowrunnerWeeklyPitch`
    * `showrunner.research_brief` → `Handlers.ShowrunnerResearchBrief`
    * `showrunner.run_sheet` → `Handlers.ShowrunnerRunSheet`

  The Router probes `build_prompt/1` and `output_meta/2` on the PROVIDER, so
  this shim dispatches both by the fired key (`context[:__responsibility__]`).
  An unmapped key returns exactly `{:error, :no_build_prompt}`, the one error
  the Router reads as "use the legacy template render" (see
  `Providers.Design`).
  """
  @behaviour Platform.Responsibilities.Provider

  alias Platform.Responsibilities.Handlers.ShowrunnerResearchBrief
  alias Platform.Responsibilities.Handlers.ShowrunnerRunSheet
  alias Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch
  alias Platform.Responsibilities.Responsibility

  @handlers [ShowrunnerWeeklyPitch, ShowrunnerResearchBrief, ShowrunnerRunSheet]

  @impl true
  def register, do: Enum.flat_map(@handlers, & &1.register())

  @doc "The concrete handler for a responsibility or key; `nil` for keys this feature does not own."
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for(key) when is_binary(key), do: Enum.find(@handlers, &(&1.key() == key))
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{key: key} = responsibility, ctx) when is_map(ctx) do
    case handler_for(key) do
      nil -> {:ok, %{}}
      mod -> mod.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      nil -> {:error, :no_build_prompt}
      mod -> mod.build_prompt(context)
    end
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  @impl true
  def output_meta(context, trigger_meta) when is_map(context) do
    mod = handler_for(Map.get(context, :__responsibility__))

    if mod && function_exported?(mod, :output_meta, 2),
      do: mod.output_meta(context, trigger_meta),
      else: trigger_meta
  end

  def output_meta(_context, trigger_meta), do: trigger_meta

  @impl true
  def handle_output(responsibility, parsed), do: handle_output(responsibility, parsed, %{})

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    case handler_for(key) do
      nil -> :ok
      mod -> mod.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  def handle_output(_responsibility, _parsed, _trigger_meta), do: :ok

  @impl true
  def handle_refusal(%Responsibility{key: key} = responsibility, refusal, trigger_meta) do
    case handler_for(key) do
      nil -> :ok
      mod -> mod.handle_refusal(responsibility, refusal, trigger_meta)
    end
  end
end
