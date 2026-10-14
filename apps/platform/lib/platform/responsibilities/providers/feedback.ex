defmodule Platform.Responsibilities.Providers.Feedback do
  @moduledoc """
  Provider shim for the `feedback` feature (task 01a11ec3 stage 3).

  `Handlers.FeedbackIntake` registers `feedback.intake` so the
  `triage_officer` bundle resolves and `Roles.assignee_for/1` can name the
  agent whose model classifies external issues. Without an entry in
  `Platform.Responsibilities.Providers` the feature would boot as
  `provider_missing`.

  The Router never fires `feedback.intake` (null topic). `build_prompt/1`
  therefore answers `{:error, :feedback_intake_not_router_dispatched}` — NOT
  `:no_build_prompt`, which the Router reads as "fall back to the template
  render". Any other error is propagated and aborts the dispatch, which is the
  wanted outcome for a stray fire.

  Keys owned here:

    * `feedback.intake` → `Handlers.FeedbackIntake`
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers.FeedbackIntake
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register, do: FeedbackIntake.register()

  @doc """
  Return the concrete handler module for a responsibility (or key), or `nil`
  for any key this feature does not own.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("feedback.intake"), do: FeedbackIntake
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
  def build_prompt(_context), do: FeedbackIntake.build_prompt(%{})

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[feedback provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Feedback.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_feedback_responsibility}
  end
end
