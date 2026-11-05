defmodule Platform.Responsibilities.Providers.Hr do
  @moduledoc """
  Provider shim for the `hr` feature (task 01a1aa47 stage 4).

  The Router resolves the per-feature provider module by camelcasing the
  responsibility's `feature` field, so any row with `feature == "hr"` looks
  up this module. Both `hr.*` keys are handled by one module,
  `Platform.Responsibilities.Handlers.Hr`; this shim exists so the feature
  resolves the way `Providers.Memory` does and `provider_coverage_test.exs`
  can walk it uniformly. It delegates every callback and adds nothing.
  """
  @behaviour Platform.Responsibilities.Provider

  alias Platform.Responsibilities.Handlers.Hr
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: Hr.register()

  @doc "The concrete handler for a responsibility or key; `nil` for keys this feature does not own."
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("hr.daily_sweep"), do: Hr
  def handler_for("hr.meeting_completed"), do: Hr
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
  def build_prompt(context), do: Hr.build_prompt(context)

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed) do
    case handler_for(key) do
      nil -> :ok
      mod -> mod.handle_output(responsibility, parsed)
    end
  end

  def handle_output(_responsibility, _parsed), do: :ok

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
