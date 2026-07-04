defmodule Platform.Responsibilities.Providers.Tasks do
  @moduledoc """
  Provider shim for the `tasks` feature (task 019f2455 stage 4).

  The M6 Router resolves the per-feature provider module by camelcasing
  the responsibility's `feature` field and prepending
  `Platform.Responsibilities.Providers.` (see
  `Platform.Responsibilities.Router.provider_module_for/1`). So a row
  with `feature == "tasks"` looks up
  `Platform.Responsibilities.Providers.Tasks` — **this module** — for
  its Provider callbacks.

  The `tasks` feature owns three responsibilities that make up the
  Triage Officer role bundle:

    * `tasks.triage` → handled by `Handlers.TaskTriage`
    * `tasks.unblock` → handled by `Handlers.TaskUnblock`
    * `tasks.weekly_review` → handled by `Handlers.TaskWeeklyReview`

  So this shim dispatches on `responsibility.key` via `handler_for/1`
  and hands off to the concrete handler module. Any unmapped key logs a
  warning and returns `{:error, :unknown_tasks_responsibility}` — the
  smoke signal for a drift between the built-ins list and this
  dispatch table.

  ## Why a shim instead of one big "Tasks" handler

  Each key has its own trigger surface (weekday cron vs chat_pattern vs
  Friday cron), its own output contract (triage rows vs unblock
  suggestions vs weekly review), and its own context_provided set.
  Keeping them as separate handler units means an operator can assign
  different agents to "triage the backlog" vs "propose unblocks" vs
  "write the weekly review". This module is the routing seam, not the
  implementation.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.TaskTriage
  alias Platform.Responsibilities.Handlers.TaskUnblock
  alias Platform.Responsibilities.Handlers.TaskWeeklyReview
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    TaskTriage.register() ++
      TaskUnblock.register() ++
      TaskWeeklyReview.register()
  end

  @doc """
  Return the concrete handler module for a given responsibility (or key).
  Public so integration tests can assert the role → bundle →
  responsibility → handler wiring lands on the expected module without
  reaching through the M6 Router.

  Returns `nil` for any key not owned by this feature so callers can
  branch on the missing case explicitly.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("tasks.triage"), do: Handlers.TaskTriage
  def handler_for("tasks.unblock"), do: Handlers.TaskUnblock
  def handler_for("tasks.weekly_review"), do: Handlers.TaskWeeklyReview
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

  # ── internals ─────────────────────────────────────────────────────────────

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[tasks provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Tasks.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_tasks_responsibility}
  end
end
