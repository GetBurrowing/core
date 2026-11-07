defmodule Platform.Responsibilities.Providers.Ux do
  @moduledoc """
  Provider shim for the `ux` feature (task 01a1af00 stage 2).

  One key, `ux.friction_watch`, handled by
  `Platform.Responsibilities.Handlers.UxFrictionWatch`. The Router resolves
  providers by feature through `Platform.Responsibilities.Providers`, so this
  shim exists for the same reason `Providers.Hr` does: the feature resolves
  uniformly and `provider_coverage_test.exs` can walk it. It delegates every
  callback and adds nothing.
  """
  @behaviour Platform.Responsibilities.Provider

  alias Platform.Responsibilities.Handlers.UxFrictionWatch
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: UxFrictionWatch.register()

  @doc "The concrete handler for a responsibility or key; `nil` for keys this feature does not own."
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("ux.friction_watch"), do: UxFrictionWatch
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
  def build_prompt(context), do: UxFrictionWatch.build_prompt(context)

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
end
