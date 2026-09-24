defmodule Platform.Responsibilities.Providers.Experiments do
  @moduledoc """
  Provider shim for the `experiments` feature (task 01a0d415 stage 3, the
  experimentation-layer ADR-0052).

  `Handlers.ExperimentsLabelSignal` registers `experiments.label_signal` so
  the `scientist` role's bundle resolves and `Roles.assignee_for/1` can name
  the labeler's agent. Without an entry in
  `Platform.Responsibilities.Providers` the feature would boot as
  `provider_missing` — the state that registry exists to make loud.

  The Router never fires `experiments.label_signal` (its topic is a null
  topic; labelling runs through `Platform.Experiments.Signals.MailSubscriber`
  and the tool-less `Platform.Experiments.Labeler`). So `build_prompt/1`
  returns `{:error, :no_build_prompt}` for it, the Router's "fall back to the
  template" value, and output handling delegates to the handler, which logs
  and does nothing.

  `experiments.scientist` (stage 5) is a real cron fire, and its handler owns
  its prompt: `build_prompt/1` routes it to
  `Handlers.ExperimentsScientist.build_prompt/1`, exactly as
  `Providers.Agents` routes the goal heartbeat. Structure mirrors
  `Providers.Agents`.

  Keys owned here:

    * `experiments.label_signal` → `Handlers.ExperimentsLabelSignal`
    * `experiments.scientist` → `Handlers.ExperimentsScientist`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers.ExperimentsLabelSignal
  alias Platform.Responsibilities.Handlers.ExperimentsScientist
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: ExperimentsLabelSignal.register() ++ ExperimentsScientist.register()

  @doc """
  Return the concrete handler module for a responsibility (or key), or
  `nil` for any key this feature does not own.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("experiments.label_signal"), do: ExperimentsLabelSignal
  def handler_for("experiments.scientist"), do: ExperimentsScientist
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

  # Only the Scientist builds its own prompt. The labeler key keeps
  # `:no_build_prompt` (it is never fired), so it stays in the builder-less
  # set that `builderless_key_template_coverage_test.exs` pins.
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, :no_build_prompt}
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      ExperimentsScientist -> ExperimentsScientist.build_prompt(context)
      _ -> {:error, :no_build_prompt}
    end
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[experiments provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Experiments.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_experiments_responsibility}
  end
end
