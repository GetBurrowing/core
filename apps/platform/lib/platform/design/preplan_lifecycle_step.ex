defmodule Platform.Design.PreplanLifecycleStep do
  @moduledoc """
  The pre-plan design step as a declared lifecycle pipeline step
  (ADR-0046 Amendment 1, task 019fe1b7-6b6f-7c04-9f3c-d4f44ec87d26 stage 2).

  This is the designer's entry on `Platform.Lifecycle.Edges.designer_edge/0`.
  It implements `Platform.Lifecycle.Step` with `kind/0` `:async`, because the
  designer takes minutes and can die silently — which is the case the async
  shape exists for.

  ## What this module is NOT

  It is not a second implementation of the design step. Every write still
  belongs to `Platform.Design.PreplanStep`: `start/1` fires the responsibility
  and moves the cursor, `settle/2` closes it when the canvas lands, `decline/3`
  closes it when the designer says no, `expire/2` closes it on a budget. This
  module is the ADAPTER that lets the pipeline frame START that step and WAIT
  for it. A second writer of `planning_step_outcomes` would be two sources of
  truth for one fact, which is the defect ADR-0046 exists to prevent.

  Consequence worth stating plainly, because it looks like an omission: this
  module never writes an outcome. `Platform.Lifecycle.Edges.run_outcome/1`
  translates the RUN's status for the pipeline's own record; the
  `complete / not_applicable / failed` entry on the task is written by
  `PreplanStep`, where it always was.

  ## Settlement is watched, not awaited

  `start/2` cannot block: the `Step` contract forbids it, and the closing
  signal arrives from somewhere else entirely — a canvas attachment
  (`Platform.Tasks.CanvasAttachments`), an MCP decline
  (`task_design_decline`), or a human. So `start/2` returns `{:running, ref}`
  and spawns a WATCHER that resolves the ref when the step closes.

  The watcher is level-triggered with an edge-triggered accelerator, in that
  order of authority:

    * it re-reads the task and asks `PreplanStep.open?/1` — the cursor IS the
      state, and it is the same field the router's hold predicate reads, so
      there is no second source of truth to drift;
    * it subscribes to the board so a close is observed at broadcast latency
      rather than at poll latency. `settle/2` emits more than one
      `{:task_updated, _}` and the watcher resolves exactly once, so the
      duplicate broadcasts cannot produce duplicate settlements.

  Losing the broadcast costs latency and nothing else. That ordering is the
  same argument the router's own design hold was built on, and it is why the
  poll is a backstop rather than the mechanism.

  **The watcher does not bound the wait.** It gives up at the budget it was
  handed and sends nothing, because a watcher that outlived the pipeline would
  deliver a settlement for a run the executor has already timed out. The BUDGET
  is what bounds the wait — `Platform.Lifecycle.step_timeout_ms/0` and
  `edge_budget_ms/0` — exactly as `Platform.Lifecycle.Step` requires.
  """

  @behaviour Platform.Lifecycle.Step

  require Logger

  alias Platform.Design.PreplanStep
  alias Platform.Lifecycle
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  # Backstop only — the board broadcast is the fast path. Read through
  # `Application.get_env/3` on every use so a test can inject a small value
  # per-case, with no `config/test.exs` entry: a test-only value silently
  # becoming the production one is the failure this stack is written against.
  @settle_poll_ms 1_000

  @impl Platform.Lifecycle.Step
  def kind, do: :async

  @doc """
  Member 1's arity-1 registry contract.

  `Platform.Lifecycle.StepRegistry` entries carry `mfa: {mod, fun, 1}`, and its
  drift guard asserts every built-in exports that arity. The executor prefers
  `start/2` when a module exports it (`Platform.Lifecycle.Executor.invoke/4`),
  so this clause is the compatibility half of that bridge and not a second
  behaviour: it forwards to `start/2` with an empty declaration.

  Collapsing the registry onto the behaviour — and deleting the executor's
  capability probe with it — changes the registry's ENTRY TYPE and the three
  member-2 tests that pin it. That is not this stage's diff.
  """
  @spec start(map()) :: Platform.Lifecycle.Step.start_result()
  def start(context) when is_map(context), do: start(%{}, context)

  @impl Platform.Lifecycle.Step
  def start(_step_config, %{task: %TaskSchema{} = task} = context) do
    case PreplanStep.start(task) do
      # Fired and dispatched, or already open from an earlier run: the cursor
      # is `"designing"` and somebody else closes it.
      {:ok, open} when open in [:open, :already_open] ->
        watch(task, context)

      # Nothing to wait for — all three resolved inside `start/1` and are
      # already recorded on the task.
      {:ok, :already_settled} ->
        {:completed, :already_settled}

      {:ok, :not_applicable} ->
        {:completed, :not_applicable}

      # RAN and errored. The edge outcome is `failed`; the planner is still
      # released, because design fails open in every direction.
      {:ok, :failed} ->
        {:failed, :design_dispatch_failed}

      {:error, reason} ->
        {:failed, reason}
    end
  end

  defp watch(%TaskSchema{} = task, context) do
    ref = make_ref()
    reply_to = Map.get(context, :reply_to, self())
    budget_ms = Map.get(context, :step_timeout_ms, Lifecycle.step_timeout_ms())

    spawn(fn -> watch_loop(task.id, ref, reply_to, deadline(budget_ms)) end)

    {:running, ref}
  end

  @doc """
  Milliseconds between backstop re-reads while a design step is open.

  The board broadcast is the fast path; this bounds how long a MISSED
  broadcast can cost.
  """
  @spec settle_poll_ms() :: pos_integer()
  def settle_poll_ms do
    Application.get_env(:platform, :design_settle_poll_ms, @settle_poll_ms)
  end

  @doc "The shipped backstop interval, independent of any injected config."
  @spec default_settle_poll_ms() :: pos_integer()
  def default_settle_poll_ms, do: @settle_poll_ms

  # ── the watcher ───────────────────────────────────────────────────────────

  defp watch_loop(task_id, ref, reply_to, deadline) do
    Tasks.subscribe_board()
    poll(task_id, ref, reply_to, deadline)
  end

  defp poll(task_id, ref, reply_to, deadline) do
    case closed_outcome(task_id) do
      nil ->
        remaining = deadline - now_ms()

        if remaining <= 0 do
          # Deliberately silent. The executor's budget has already expired, so
          # a settlement now would resolve a run it has stopped listening for.
          :ok
        else
          receive do
            _board_message -> :ok
          after
            min(settle_poll_ms(), remaining) -> :ok
          end

          poll(task_id, ref, reply_to, deadline)
        end

      outcome ->
        send(reply_to, {:lifecycle_step_settled, ref, outcome})
    end
  end

  # `nil` means STILL OPEN. Anything else is a terminal outcome for the run.
  #
  # A task that vanished mid-step resolves rather than spinning until the
  # budget: there is no cursor left to close and no planner left to release.
  defp closed_outcome(task_id) do
    case Tasks.get_task_detail(task_id) do
      nil ->
        {:completed, :task_not_found}

      %TaskSchema{} = task ->
        if PreplanStep.open?(task) do
          nil
        else
          terminal(PreplanStep.persisted_outcome(task))
        end
    end
  rescue
    error ->
      Logger.warning("[design.preplan] settle watcher read raised: #{Exception.message(error)}")
      {:failed, :watch_read_raised}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] settle watcher read exited: #{inspect(reason)}")
      {:failed, :watch_read_exited}
  end

  # `:not_applicable` is a step that RAN and had nothing to do — a decline, or
  # a task with no UI surface. It is `{:completed, _}` at the STEP level and
  # keeps its own meaning on the task, where `PreplanStep` wrote it.
  defp terminal(:complete), do: {:completed, :complete}
  defp terminal(:not_applicable), do: {:completed, :not_applicable}
  defp terminal(:failed), do: {:failed, :design_failed}

  # The cursor closed with nothing recorded. `PreplanStep.start/1` returns the
  # cursor on a persistence fault precisely so a task is never stranded, so
  # this is a real reachable state and not a defensive branch.
  defp terminal(nil), do: {:completed, :closed_unrecorded}

  defp deadline(budget_ms), do: now_ms() + budget_ms
  defp now_ms, do: System.monotonic_time(:millisecond)
end
