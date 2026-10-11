defmodule Platform.Responsibilities.Providers.Janitor do
  @moduledoc """
  Provider shim for the `janitor` feature (task `019fa1ac-6685` stage 1).

  Reached ONLY through the explicit `feature -> provider` registry in
  `Platform.Responsibilities.Providers` (task `019f9b28`). Nothing derives
  this module's name from the feature string; drop `"janitor"` from
  `Providers.@feature_providers` and the Router resolves no provider for
  `janitor.cron_drain`, which `provider_coverage_test.exs` and
  `janitor_registration_test.exs` both report.

  ## No hand-written key switch

  The `architecture` and `feedback` shims map keys to handlers with literal
  `handler_for/1` clauses, a second copy of each key that can drift from the
  handler's own `key/0`. This shim instead derives the map from `@handlers`:
  each handler states its key once, in `key/0`, and `handler_for/1` reads it.
  Adding a janitor key is one entry in `@handlers` plus the handler module.

  Keys owned here:

    * `janitor.cron_drain` → `Handlers.JanitorCronDrain`

  ## `build_prompt/1` contract

  An unmapped or absent key returns exactly `{:error, :no_build_prompt}`, the
  one error the Router reads as "fall back to the template render" rather
  than "refuse this dispatch". See `Providers.Architecture`'s moduledoc.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers.JanitorCronDrain
  alias Platform.Responsibilities.Responsibility

  @handlers [JanitorCronDrain]

  @doc "The handler modules this feature owns, in registration order."
  @spec handlers() :: [module()]
  def handlers, do: @handlers

  @impl true
  def register, do: Enum.flat_map(@handlers, & &1.register())

  @doc """
  Return the concrete handler module for a responsibility (or key), or `nil`
  for any key this feature does not own.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)

  def handler_for(key) when is_binary(key) do
    Enum.find(@handlers, &(&1.key() == key))
  end

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
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      nil -> {:error, :no_build_prompt}
      handler -> handler.build_prompt(context)
    end
  end

  def build_prompt(_), do: {:error, :no_build_prompt}

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[janitor provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add the handler to Providers.Janitor.@handlers or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_janitor_responsibility}
  end
end
