defmodule Platform.Lifecycle.Executor do
  @moduledoc """
  Runs the ordered step pipeline configured on one lifecycle edge
  (ADR-0046 Amendment 1, task 019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95 stage 3).

  `run_edge/3` resolves the project's steps for an edge, starts each in
  declared order, applies two budgets, halts on the first divert, and writes
  one `Platform.Lifecycle.StepRun` row per step it actually ran.

  ## This member has NO real callers, deliberately

  Nothing calls `run_edge/3` outside its tests. It is not wired into
  `Platform.Tasks.transition_task_status/2` and does not intercept anything.
  Member 4 migrates the existing designer and architect hooks onto this
  frame, and that migration is what proves the executor — a self-wiring
  executor would be proved only by its own tests.

  ## Constraint on member 4: wrapping the facade is NOT enough

  Recorded here because a member-4 planner who has to rediscover it will not.

  `Platform.Responsibilities.fire/2` is a one-line delegate to
  `Platform.Responsibilities.Router.fire/2`. The facade has three lib call
  sites — but `Platform.Meetings.Summarizer` calls the **Router directly**,
  bypassing the facade entirely.

  DECISION for this member: the summarizer is **out of scope**, and this
  member wraps **neither** seam. The executor is standalone with no
  interception at all.

  The constraint that imposes: **if member 4 intends to intercept every
  fire, wrapping the facade is insufficient and will silently miss the
  meetings summary path.** It will look complete — every facade call site
  intercepted, tests green — and the summary path will simply never enter
  the pipeline. Member 4 must therefore either intercept `Router.fire/2`
  itself, or move the summarizer onto the facade first and prove it moved.

  ## Ordering, and why the halt is `reduce_while`

  Steps run in declared list order, and the FIRST divert halts the
  remainder. This is implemented with `Enum.reduce_while/3` and it is the
  single most likely place for this module to be silently wrong: a plain
  `Enum.reduce/3` runs the whole list, so a task diverting back to planning
  would still fire the "entering execution" webhook. Nothing turns red — the
  steps all succeed, the rows all look fine, and the pipeline publishes a
  claim that is false. Steps after a halt get NO run row and are reported in
  `:not_run`.

  ## `can_divert` comes from the DECLARATION, never the index

  A step's authority to divert is read from `step["can_divert"]` in its own
  config (string keys — this round-trips through jsonb). A step that returns
  `{:diverted, _}` while declared `can_divert: false` does **not** divert:
  it is recorded `completed`, flagged `divert_ignored: true` in the summary,
  and the pipeline continues. Amendment 1 decision 3 is the reason — if
  divert authority came from position, inserting a notify at the top of a
  pipeline would silently demote a gate to advisory.

  ## Two budgets, two mechanisms, two distinguishable reasons

  The edge deadline is computed ONCE at run start from
  `System.monotonic_time/:millisecond` plus the edge budget. Each awaited
  step then waits `min(step_timeout_ms, remaining_edge_ms)`.

    * the step's own budget expired → `status: "timed_out"`,
      `reason: "step_budget"`, and the pipeline CONTINUES (one slow step is
      not a reason to abandon the edge)
    * the edge deadline passed → `status: "timed_out"`,
      `reason: "edge_budget"`, and the remainder is HALTED

  Those reasons must stay distinguishable. If both surfaced as a bare
  `:timeout` the two budget tests could not tell which mechanism fired, and
  both would pass against an implementation that has only one budget.

  ## `kind/0` is not consulted

  The executor branches on what `start/2` actually RETURNED, never on the
  step module's `kind/0`. The return value is the fact; `kind/0` is a claim
  about it. A step that declares `:sync` and returns `{:running, ref}` must
  not be able to hang the pipeline, and one that declares `:async` and
  returns terminally must not be waited on.

  ## Bridging the registry's arity-1 MFA entries

  `Platform.Lifecycle.StepRegistry` entries carry `mfa: {mod, fun, 1}` —
  written in member 1, before member 2 defined the `Platform.Lifecycle.Step`
  behaviour. The two invocation contracts coexist here:

    * the entry's module exports `start/2` → it is a `Step`; call it
    * otherwise → apply the arity-1 MFA and adapt `{:ok, _}` to
      `{:completed, _}`

  The branch tests an exported function, which is a FACT about the module,
  not a self-declaration. Name resolution still goes through the registry
  allowlist and nowhere else: no `String.to_existing_atom/1`, no
  `Code.ensure_loaded?/1` as an admission test, no `apply/3` on anything
  derived from configuration. This bridge is a seam, not a design; member 4
  should collapse the registry onto the behaviour and delete it.

  ## Outcomes

    * `:complete` — every step that ran resolved without a divert
    * `:diverted` — a step with divert authority sent the task back
    * `:failed` — a step ran and errored, or timed out
    * `:not_applicable` — the edge RAN and had NO steps configured
    * `:suppressed` — reserved for member 4's re-entry bound; this member
      never returns it

  `:not_applicable` is specifically NOT what a never-occurring edge
  produces. An edge that is never reached does not call `run_edge/3` at all,
  writes no rows and yields no outcome (Amendment 1 decision 2). Conflating
  "ran, nothing configured" with "never ran" is the defect ADR-0046 exists
  to prevent.
  """

  alias Platform.Lifecycle
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @type outcome :: :complete | :not_applicable | :failed | :diverted | :suppressed

  @doc """
  Run the pipeline configured on `edge_name` for this task's project.

  Options:

    * `:step_timeout_ms` / `:edge_budget_ms` — millisecond budgets. Tests
      MUST inject these; a test that waits out the shipped 30-minute default
      is a defect, not thoroughness.
    * `:project` — skip the project load (the caller usually holds it).
    * `:registry` — the `StepRegistry` server to resolve names against.
    * `:reply_to` — where async steps deliver settlement. Defaults to
      `self()`, which is the process doing the awaiting.
  """
  @spec run_edge(TaskSchema.t(), binary(), keyword()) :: {outcome(), map()}
  def run_edge(%TaskSchema{} = task, edge_name, opts \\ []) when is_binary(edge_name) do
    project = Keyword.get_lazy(opts, :project, fn -> Tasks.get_project(task.project_id) end)
    steps = if project, do: Lifecycle.resolve_steps(project, edge_name), else: []

    run_seq = Runs.next_run_seq(task.id, edge_name)

    state = %{
      task: task,
      edge: edge_name,
      run_seq: run_seq,
      registry: Keyword.get(opts, :registry, StepRegistry.server()),
      reply_to: Keyword.get(opts, :reply_to, self()),
      step_timeout_ms: Keyword.get(opts, :step_timeout_ms, Lifecycle.step_timeout_ms()),
      deadline: now_ms() + Keyword.get(opts, :edge_budget_ms, Lifecycle.edge_budget_ms())
    }

    run_steps(steps, state)
  end

  # ── the pipeline ──────────────────────────────────────────────────────────

  defp run_steps([], state) do
    {:not_applicable, %{edge: state.edge, run_seq: state.run_seq, steps: [], not_run: []}}
  end

  defp run_steps(steps, state) do
    indexed = Enum.with_index(steps)

    {results, halted_at} =
      Enum.reduce_while(indexed, {[], nil}, fn {step, position}, {acc, _halt} ->
        result = run_one(step, position, state)
        acc = [result | acc]

        # THE HALT. A plain `reduce` here would run every remaining step
        # after a divert — silently, with everything green.
        if result.halts, do: {:halt, {acc, position}}, else: {:cont, {acc, nil}}
      end)

    results = Enum.reverse(results)

    not_run =
      case halted_at do
        nil -> []
        position -> steps |> Enum.drop(position + 1) |> Enum.map(&step_name/1)
      end

    summary = %{
      edge: state.edge,
      run_seq: state.run_seq,
      steps: results,
      not_run: not_run
    }

    {outcome_of(results), summary}
  end

  defp run_one(step, position, state) do
    name = step_name(step)
    awaited = truthy(Map.get(step, "await"))
    can_divert = truthy(Map.get(step, "can_divert"))

    base = %{
      position: position,
      step: name,
      awaited: awaited,
      can_divert: can_divert,
      divert_ignored: false,
      halts: false,
      reason: nil
    }

    cond do
      expired?(state) ->
        settle(base, "timed_out", "edge_budget", true, state)

      true ->
        started_at = DateTime.utc_now()

        case start_step(step, name, state) do
          {:running, ref} when awaited ->
            await_settlement(base, ref, started_at, state)

          {:running, _ref} ->
            # Not awaited: the row records that it STARTED and the pipeline
            # moves on. Late settlement is member 4's problem.
            settle(base, "started", nil, false, state, started_at, nil)

          terminal ->
            terminal_row(base, terminal, started_at, state)
        end
    end
  end

  defp await_settlement(base, ref, started_at, state) do
    remaining = remaining_ms(state)
    wait = min(state.step_timeout_ms, remaining)

    receive do
      {:lifecycle_step_settled, ^ref, outcome} ->
        terminal_row(base, outcome, started_at, state)
    after
      max(wait, 0) ->
        # WHICH budget expired is the whole point. If the edge's remaining
        # window was the binding constraint it is an edge kill and the
        # remainder halts; otherwise the step overran its own budget and the
        # pipeline continues.
        if remaining <= state.step_timeout_ms do
          settle(base, "timed_out", "edge_budget", true, state, started_at, DateTime.utc_now())
        else
          settle(base, "timed_out", "step_budget", false, state, started_at, DateTime.utc_now())
        end
    end
  end

  defp terminal_row(base, {:completed, _term}, started_at, state) do
    settle(base, "completed", nil, false, state, started_at, DateTime.utc_now())
  end

  defp terminal_row(base, {:failed, term}, started_at, state) do
    settle(base, "failed", inspect(term), false, state, started_at, DateTime.utc_now())
  end

  defp terminal_row(%{can_divert: true} = base, {:diverted, term}, started_at, state) do
    settle(base, "diverted", inspect(term), true, state, started_at, DateTime.utc_now())
  end

  defp terminal_row(%{can_divert: false} = base, {:diverted, _term}, started_at, state) do
    # Declared advisory, tried to divert. It does NOT divert — recorded as a
    # completed run with the attempt flagged, and the pipeline continues.
    base
    |> Map.put(:divert_ignored, true)
    |> settle("completed", "divert_ignored", false, state, started_at, DateTime.utc_now())
  end

  defp terminal_row(base, other, started_at, state) do
    settle(
      base,
      "failed",
      "unexpected step return: #{inspect(other)}",
      false,
      state,
      started_at,
      DateTime.utc_now()
    )
  end

  defp settle(base, status, reason, halts, state),
    do: settle(base, status, reason, halts, state, nil, nil)

  defp settle(base, status, reason, halts, state, started_at, finished_at) do
    {:ok, _run} =
      Runs.record(%{
        task_id: state.task.id,
        edge: state.edge,
        run_seq: state.run_seq,
        step_name: base.step,
        position: base.position,
        awaited: base.awaited,
        can_divert: base.can_divert,
        status: status,
        reason: reason,
        started_at: started_at,
        finished_at: finished_at
      })

    %{base | reason: reason, halts: halts}
    |> Map.put(:status, status)
  end

  # ── invoking a step ───────────────────────────────────────────────────────

  defp start_step(step, name, state) do
    case StepRegistry.fetch(name, state.registry) do
      {:ok, %{mfa: {mod, fun, 1}}} ->
        context = %{task: state.task, edge: state.edge, reply_to: state.reply_to}
        invoke(mod, fun, step, context)

      {:error, :unknown_step} ->
        {:failed, {:unknown_step, name}}
    end
  end

  defp invoke(mod, fun, step, context) do
    # `Code.ensure_loaded/1` before `function_exported?/3`: on a cold module
    # the latter answers FALSE for a function that exists, so the branch would
    # be decided by whether some earlier test happened to load the module —
    # green or red depending on seed order. This is a load, NOT an admission
    # test: `mod` came from the registry allowlist, never from configuration.
    Code.ensure_loaded(mod)

    if function_exported?(mod, :start, 2) do
      mod.start(step, context)
    else
      case apply(mod, fun, [context]) do
        {:ok, term} -> {:completed, term}
        other -> other
      end
    end
  rescue
    error -> {:failed, error}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp outcome_of(results) do
    cond do
      Enum.any?(results, &(&1.status == "diverted")) -> :diverted
      Enum.any?(results, &(&1.status in ["failed", "timed_out"])) -> :failed
      true -> :complete
    end
  end

  defp step_name(step) when is_map(step), do: Map.get(step, "step")
  defp step_name(_step), do: nil

  defp truthy(true), do: true
  defp truthy(_other), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining_ms(state), do: state.deadline - now_ms()
  defp expired?(state), do: remaining_ms(state) <= 0
end
