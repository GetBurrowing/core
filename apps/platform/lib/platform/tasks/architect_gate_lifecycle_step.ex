defmodule Platform.Tasks.ArchitectGateLifecycleStep do
  @moduledoc """
  The plan-time architecture gate as a declared lifecycle pipeline step
  (ADR-0046 Amendment 1, task 019fe1b7-6b6f-7c04-9f3c-d4f44ec87d26 stage 3).

  This is the architect's entry on `Platform.Lifecycle.Edges.architect_edge/0`
  (`"plan.review_requested"`), declared `await: true, can_divert: true` in
  `Platform.Lifecycle.Edges.default_steps/1`. Both flags are read by
  `Platform.Lifecycle.Executor` FROM THE DECLARATION and never from the step's
  position in the pipeline — which is the property
  `architect_gate_pipeline_test.exs` exists to pin, with the gate deliberately
  NOT first.

  ## The structural mismatch, and which way it was resolved

  Member 3's `Platform.Lifecycle.Executor.run_edge/3` is keyed on a TASK and an
  opaque edge NAME. The architect gate does not fire on a task-status
  transition: it fires from `Platform.Tasks.submit_plan_for_review/1` on the
  PLAN transition `draft -> pending_review`. Two options were on the table —
  (a) name a lifecycle edge for the plan-submission boundary and call
  `run_edge/3` from that site, or (b) report that the edge model cannot express
  a plan-status boundary and scope this member to the designer.

  **(a) was chosen, and the reason is that the mismatch is narrower than it
  looks**: the executor never parses the edge name. It is a string on the run
  row. The boundary is nameable, and the run rows it produces are the record
  the migration exists to create. (b) would have been a claim about the frame
  that the frame does not actually make.

  ## What this step OWNS, and what it deliberately does not

  It owns the WAIT and the DIVERT. It does not own the fire, and it must not:

    * `submit_plan_for_review/1` fires `architecture.review_plan`, records the
      planning-step outcome, and opens the gate SYNCHRONOUSLY, in that order,
      before this edge runs. Moving those into `start/2` would make a
      request-path transition asynchronous for five callers — the MCP
      `plan_submit` tool among them — and every caller that reads the gate
      immediately after a submit would start racing it. That is a behavioural
      change to the submit contract, not a migration of a hook.
    * Settlement arrives from `Platform.Tasks.resolve_architecture_gate/3`, and
      this step NEVER calls it. The watcher is a read-only observer of
      `Tasks.architecture_gate/1`. Re-entering the resolver from here would
      re-run `settle_resolved_architecture_gate/2` against a plan that
      `approve_plan/3` may be mid-flight on — the double-approval defect the
      comment at `Platform.Tasks`' settlement tail records, where the human's
      click lands under `"system:auto"`. An observer never gets to change the
      outcome it observes.

  So the pipeline is, at this stage, the architect gate's RECORDER and its
  HALT — not its driver. Stated plainly because the alternative reads as an
  omission: the fire stays where it is, and the diff is small because the
  architect had almost no bespoke lifecycle machinery to delete. See
  `Platform.Lifecycle.Edges`' premise correction.

  ## `submit_plan_for_review/1` does NOT block

  `Platform.Lifecycle.Executor.run_edge/3` awaits in a `receive` in the
  CALLING process. `submit_plan_for_review/1` is synchronous and on a request
  path, and an architecture gate resolves in minutes-to-hours through a human
  or an agent — so awaiting it inline would hold an HTTP request open for the
  edge budget. The edge is therefore run in a spawned process, exactly as the
  designer edge is run off the router's dispatch tick.

  ## The divert is OBSERVED, not caused

  `:reject` routes through `settle_resolved_architecture_gate(resolved,
  :reject)` into `Platform.Tasks.ArchitectureRejection.handle/1`, which owns
  the iteration counter, the feedback body, the bound and the escalation.
  Rejection handling is NOT reimplemented here. This step's `{:diverted,
  :reject}` return is what makes the PIPELINE halt — it stops steps declared
  after the gate from running against a plan that has been sent back.
  """

  @behaviour Platform.Lifecycle.Step

  require Logger

  alias Platform.Lifecycle
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  # Backstop only — the board broadcast is the fast path. Read through
  # `Application.get_env/3` on every use so a test can inject a small value
  # per-case, with no `config/test.exs` entry.
  @gate_poll_ms 1_000

  @impl Platform.Lifecycle.Step
  def kind, do: :async

  @doc """
  Member 1's arity-1 registry contract.

  `Platform.Lifecycle.StepRegistry` entries carry `mfa: {mod, fun, 1}` and its
  drift guard asserts every built-in exports that arity, so this clause is the
  compatibility half of the bridge `Platform.Lifecycle.Executor.invoke/4`
  probes for. It is not a second behaviour: it forwards to `start/2` with an
  empty declaration.

  The bridge is NOT collapsed in this stage. Collapsing it changes the
  registry's entry type and the member-2 tests that pin arity-1 exportedness,
  while member 5 is still to land against that contract — a bigger and riskier
  diff than this stage's, and one that belongs with whoever owns the registry.
  """
  @spec start(map()) :: Platform.Lifecycle.Step.start_result()
  def start(context) when is_map(context), do: start(%{}, context)

  @impl Platform.Lifecycle.Step
  def start(_step_config, %{task: %TaskSchema{} = task} = context) do
    case Tasks.latest_plan(task.id) do
      # No plan to gate. The edge RAN; there was nothing on it.
      nil ->
        {:completed, :no_plan}

      plan ->
        case settled_outcome(plan.id) do
          # Still open (or resolved with a state this module does not know, in
          # which case waiting beats inventing an answer) — wait for it.
          nil -> watch(plan.id, context)
          outcome -> outcome
        end
    end
  end

  @doc """
  Milliseconds between backstop re-reads while the architecture gate is open.
  """
  @spec gate_poll_ms() :: pos_integer()
  def gate_poll_ms do
    Application.get_env(:platform, :architecture_gate_poll_ms, @gate_poll_ms)
  end

  @doc "The shipped backstop interval, independent of any injected config."
  @spec default_gate_poll_ms() :: pos_integer()
  def default_gate_poll_ms, do: @gate_poll_ms

  # ── the watcher ───────────────────────────────────────────────────────────

  defp watch(plan_id, context) do
    ref = make_ref()
    reply_to = Map.get(context, :reply_to, self())
    budget_ms = Map.get(context, :step_timeout_ms, Lifecycle.step_timeout_ms())

    # Supervised, not a bare `spawn/1` — see the note on
    # `Platform.Tasks.run_architect_edge/1` (ticket 01a06638). `poll/4` reads
    # the gate row through `Repo` on every tick; without `$callers` that read
    # raised `DBConnection.OwnershipError` under an `async: true` case, and
    # `settled_outcome/1`'s own rescue turned the raise into a settlement of
    # `{:failed, :watch_read_raised}` — a watcher reporting a verdict it never
    # actually read.
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      try do
        Tasks.subscribe_board()
        poll(plan_id, ref, reply_to, now_ms() + budget_ms)
      rescue
        DBConnection.OwnershipError ->
          # TEST-ENV ONLY, spelled bare for the audit — see the fuller note in
          # `Platform.Tasks.ProofOfLife`. `settled_outcome/1`'s own rescue
          # sits INSIDE this one and normally converts an ownership raise into
          # a `{:failed, :watch_read_raised}` settlement first; this clause is
          # the backstop for a raise anywhere else in the body.
          Logger.warning("[plan.review_requested] gate watcher had no sandbox owner (test env)")
      end
    end)

    {:running, ref}
  end

  defp poll(plan_id, ref, reply_to, deadline) do
    case settled_outcome(plan_id) do
      nil ->
        remaining = deadline - now_ms()

        if remaining <= 0 do
          # Deliberately silent: the executor's budget has expired and a
          # settlement now would resolve a run it has stopped listening for.
          :ok
        else
          receive do
            _board_message -> :ok
          after
            min(gate_poll_ms(), remaining) -> :ok
          end

          poll(plan_id, ref, reply_to, deadline)
        end

      outcome ->
        send(reply_to, {:lifecycle_step_settled, ref, outcome})
    end
  end

  # `nil` means the gate is STILL OPEN. `Tasks.architecture_gate/1` re-reads
  # the row every call and projects an overdue `"pending"` verdict to expired,
  # so the level check cannot be fooled by a stale struct or a missed
  # broadcast.
  defp settled_outcome(plan_id) do
    case Tasks.architecture_gate(plan_id) do
      {:open, _verdict} -> nil
      {:resolved, verdict} -> terminal(Map.get(verdict, "state"))
      # The plan or its verdict vanished mid-step. There is nothing left to
      # wait for; resolving beats spinning until the budget.
      :none -> {:completed, :not_applicable}
    end
  rescue
    error ->
      Logger.warning(
        "[plan.review_requested] gate watcher read raised: #{Exception.message(error)}"
      )

      {:failed, :watch_read_raised}
  catch
    :exit, reason ->
      Logger.warning("[plan.review_requested] gate watcher read exited: #{inspect(reason)}")
      {:failed, :watch_read_exited}
  end

  # THE DIVERT. `"rejected"` is the one verdict that sends the plan back, and
  # `can_divert: true` on the declaration is what lets it halt the pipeline.
  defp terminal("rejected"), do: {:diverted, :reject}

  defp terminal("passed"), do: {:completed, :pass}

  # A human who overrode the gate approved the plan themselves. The gate
  # resolved; nothing was diverted.
  defp terminal("human_override"), do: {:completed, :human_override}

  # BOTH FALL OPEN on the plan, and both are `failed` on the RUN — which is
  # not a contradiction. The plan proceeds (`settle_resolved_architecture_gate/2`'s
  # `fell_open` clause) while the run records that the hook did not do its
  # job, which is exactly the distinction ADR-0046's outcome trio exists for.
  defp terminal("expired"), do: {:failed, :expired}
  defp terminal("dispatch_failed"), do: {:failed, :dispatch_failed}

  # Non-terminal or unknown: keep waiting rather than inventing an answer.
  defp terminal(_other), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)
end
