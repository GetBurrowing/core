defmodule Platform.Orchestration.TaskRouterNoUnmetGateSuppressionTest do
  @moduledoc """
  Task `01a01b00` stage 3 — the `:no_unmet_gate` dispatch guard.

  ## The shape

  A stage RESOLVES (it is `running`, so `unresolved_stage_dispatch?/3` declines)
  but owes no unmet validation, while `task.status` still reads `"in_review"`.
  `DispatchPhase.status_phase/1` is that module's documented LAST resort and is
  stale for a full dispatch cycle, so the review body was rendered for a stage
  carrying no gate at all — a review round manufactured out of a status field.
  Observed on stage `01a0180b` of task `01a01796`, four times.

  Stage 3 answers it at BOTH altitudes, because they are two different
  symptoms:

    * `DispatchPhase.resolve/3` stops ANSWERING a reviewer slug for that shape
      (`review_status_without_unmet_gate?/2`). Pinned by
      `dispatch_phase_unmet_gate_test.exs`, case "an all-passed stage on an
      in_review task must NOT resolve a review slug".
    * `TaskRouter` withholds the dispatch OUTRIGHT when the rest of the plan
      also has nothing owed. Pinned here.

  Neither implies the other: suppression in the router does not change one byte
  of what `resolve/3` returns, and an honest `resolve/3` still sends a generic
  body to a stage that needs no prompt at all.

  ## THE FAILURE MODE THIS FILE EXISTS TO CATCH IS THE INVERSE ONE

  Same standing order as `task_router_dispatch_suppression_test.exs`: a guard
  that suppresses too much strangles a live agent silently — no log, no
  telemetry an operator would think to look at, just a task that never gets its
  prompt. So the two negative controls below carry more weight than the
  positive case.

  A negative control cannot "go green at the fix" — it was green before. Its
  evidence is that it goes RED under a plausible WIDENING of the guard. Each
  one names the mutant it kills, and every mutant below was actually run
  against `test/platform/orchestration/` (1039 tests) or the named subset:

    * M1 — drop the review-status conjunct (suppress on "nothing owed
      anywhere" regardless of `task.status`). Reds NINE tests, including
      `task_router_dispatch_suppression_test.exs` "a task whose current plan
      is approved with a RUNNING stage still dispatches" — a task at
      `deploying` whose only stage is `running` with ZERO validations and no
      pending stage, indistinguishable from the suppressed shape without the
      status half — plus both UNGATED controls below and the unresolved-stage
      counterfactuals.
    * M2 — drop the pending-stage conjunct. Reds exactly "a task whose next
      stage is PENDING still dispatches" below. This is the strangulation
      mutant `HeartbeatScheduler.select_review_template/3`'s moduledoc warns
      about by name.
    * M3 — revert stage 2 of this task: read "unmet" as the literal
      `"pending"` again. Reds five, including "a stage whose e2e_behavior gate
      came back FAILED still dispatches" below — i.e. this guard would have
      turned stage 2's own fix into a strangler.
    * M4 — read the gate conjunct as "nothing unmet" instead of "every gate
      met", which is the same sentence about a stage carrying NO gates. Reds
      four: both UNGATED controls (here and in
      `dispatch_phase_unmet_gate_test.exs`) and two provider-guidance cases in
      `heartbeat_scheduler_test.exs`, whose fixture stage carries
      `validations: []`. THIS IS THE MUTANT THAT ACTUALLY BIT — it was the
      first draft of the predicate, and the two heartbeat cases are what
      caught it. See the UNGATED control below for why an ungated stage can
      never be withheld from.

  ONE MUTANT SURVIVED AND THE CODE WAS DELETED RATHER THAN THE TEST WEAKENED.
  A third conjunct, "no OTHER running stage owes a gate", failed nothing when
  removed (1039 tests, 0 failures). It was dead: `PlanEngine` resolves the
  running stage the same way the router does, so two running stages is not a
  shape the engine produces, and `do_dispatch/2` hands the predicate the very
  stage the withheld dispatch would have named. The reasoning is recorded on
  `no_unmet_gate_dispatch?/3` so it is not re-added.

  Evidence is the actual runtime broadcast, not a log line: `dispatch_attention/5`
  publishes on `runtime:<id>`, so subscribing to that topic observes exactly the
  thing a prompt-to-nobody would have cost. (`config :logger, level: :warning`
  in `config/test.exs` drops the `Logger.info` dispatch line before any capture
  handler sees it, so a log assertion would silently be vacuous.)

  No `Process.sleep` anywhere; the barrier is `sync_router/1` +
  `TaskRouter.current_status/1`, as in the sibling file.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  @e2e_payload %{
    "setup" => "A review round has already run against this stage.",
    "actions" => "Re-read the behaviour the planner specified.",
    "expected" => "It holds."
  }

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "No Unmet Gate Project",
        repo_url: "https://github.com/test/no-unmet-gate"
      })

    %{project: project}
  end

  describe "an in_review task whose running stage owes nothing" do
    test "withholds the dispatch and reports reason :no_unmet_gate", %{project: project} do
      # THE POSITIVE CASE. Red before stage 3: the router dispatched, and
      # `DispatchPhase.resolve/3` handed it `dispatch.in_review` — a reviewer
      # summoned to judge a stage with no `manual_approval` gate on it.
      %{task: task} = fixture = all_gates_met_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      assert_received {:dispatch_suppressed, %{task_id: task_id, reason: reason}}
      assert task_id == task.id
      assert reason == :no_unmet_gate

      # The point of the guard: no prompt payload reached the runtime.
      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "FIXTURE FLOOR — the stage really is running, really is all-passed, and is the only stage",
         %{project: project} do
      # Without this, every assertion above could be green for the wrong
      # reason: a stage that failed to reach `running` would be suppressed by
      # `unresolved_stage_dispatch?/3` instead, and a validation row that never
      # persisted would make "all gates met" vacuously true of an empty list.
      %{task: task, stage: stage} = all_gates_met_task(project)

      assert task.status == "in_review"

      plan = Tasks.current_plan(task.id)
      assert length(plan.stages) == 1
      assert Enum.all?(plan.stages, &(&1.status != "pending"))

      reloaded = Enum.find(plan.stages, &(&1.id == stage.id))
      assert reloaded.status == "running"

      assert length(reloaded.validations) == 2,
             "fixture collapsed to #{length(reloaded.validations)} validation(s)"

      assert Enum.all?(reloaded.validations, &(&1.status == "passed"))
    end
  end

  describe "negative controls — the guard must not strangle live work" do
    test "a stage with one unmet gate still dispatches", %{project: project} do
      # KILLS M3. Identical to the suppressed fixture in every respect except
      # that one `test_pass` is still `pending`, so the stage genuinely owes
      # work and the agent is the only thing that can do it.
      %{task: task} = fixture = one_unmet_gate_task(project, "test_pass", "pending")
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "a stage whose e2e_behavior gate came back FAILED still dispatches", %{project: project} do
      # KILLS M3 in its subtler form, and is the exact shape stage 2 of this
      # task widened "unmet" to cover: after one review round the behavioural
      # case sits at `failed` and `PlanEngine` re-opens the stage to `running`.
      # A guard reading "unmet" as the literal `"pending"` would see nothing
      # owed here and withhold the one dispatch that can get the rework done —
      # turning this task's own stage-2 fix into a strangler.
      %{task: task} = fixture = one_unmet_gate_task(project, "e2e_behavior", "failed")
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "a task whose next stage is PENDING still dispatches", %{project: project} do
      # KILLS M2 — THE strangulation guard. Every gate on the running stage is
      # met, exactly as in the suppressed case, but stage 2 is `pending` and
      # has never been prompted. This is the transient window
      # `HeartbeatScheduler.select_review_template/3`'s moduledoc documents as
      # a DELIBERATE divergence: validations all evaluated, stage not yet
      # auto-advanced. The dispatch is the only thing that will ever get an
      # agent to call `stage_start`; withholding it parks the task forever
      # with no operator signal.
      %{task: task} = fixture = pending_next_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "an in_review task whose running stage is UNGATED still dispatches", %{project: project} do
      # KILLS M4, and it is the mutant that actually bit: a first draft of
      # `review_status_without_unmet_gate?/2` said "nothing unmet" rather than
      # "every gate met", which is the same sentence about a stage with NO
      # gates. It red two provider-guidance cases in
      # `heartbeat_scheduler_test.exs` whose fixture stage carries
      # `validations: []`.
      #
      # Why an ungated stage is categorically different from an all-met one:
      # `PlanEngine` auto-advances a stage from exactly ONE place, the `cond`
      # inside `evaluate_validation/2`. Reaching it requires dispositioning a
      # validation. An all-met stage has therefore ALREADY had its advance
      # fired and is in a window that closes by itself, so withholding costs
      # nothing. An UNGATED stage will never have `evaluate_validation/2`
      # called for it at all — the only thing that can move it is an agent
      # calling `stage_complete`, and the only thing that makes an agent do
      # that is this dispatch. Withholding it parks the task forever, which is
      # strictly worse than the defect this guard fixes.
      #
      # Zero-validation running stages are not hypothetical: the sibling
      # `task_router_dispatch_suppression_test.exs` builds one as its live-work
      # control.
      %{task: task} = fixture = ungated_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "an in_progress task with an all-met running stage and no pending stage still dispatches",
         %{project: project} do
      # KILLS M1 locally, so the review scope of the guard is pinned in this
      # file and not only by the sibling suite. Same plan shape as the
      # suppressed case — nothing owed, no pending stage — differing ONLY in
      # `task.status`. A redundant `dispatch.in_progress` nudges an agent that
      # is already working; a redundant `dispatch.in_review` manufactures a
      # review round. The guard is scoped to the second.
      %{task: task} = fixture = all_gates_met_task(project, status: "in_progress")
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # An `in_review` task with a single `running` stage whose every validation is
  # `passed`, and no other stage. Neither validation is a `manual_approval`, so
  # there is no human gate anywhere in this plan — the review template the old
  # path rendered had nothing to point the reviewer at.
  defp all_gates_met_task(project, opts \\ []) do
    status = Keyword.get(opts, :status, "in_review")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "No unmet gate all met",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    pass!(stage, "lint_pass")
    pass!(stage, "test_pass")

    task = maybe_transition(task, status)

    %{task: task, plan: plan, stage: stage}
  end

  # The same plan with ONE gate left owing, at the given kind and status.
  defp one_unmet_gate_task(project, kind, unmet_status) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "No unmet gate one owing",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    pass!(stage, "lint_pass")

    {:ok, owed} =
      Tasks.create_validation(
        %{stage_id: stage.id, kind: kind}
        |> put_e2e_payload(kind)
      )

    if unmet_status != "pending" do
      {:ok, _} = Tasks.evaluate_validation(owed.id, unmet_status, %{"note" => "review round 1"})
    end

    {:ok, task} = Tasks.transition_task(task, "in_review")

    %{task: task, plan: plan, stage: stage}
  end

  # All gates met on the running stage, but a `pending` stage 2 exists.
  defp pending_next_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "No unmet gate pending next",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    pass!(stage, "lint_pass")
    pass!(stage, "test_pass")

    {:ok, next} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Harden"})
    assert next.status == "pending"

    {:ok, task} = Tasks.transition_task(task, "in_review")

    %{task: task, plan: plan, stage: stage, next_stage: next}
  end

  # An `in_review` task whose only stage is `running` and carries NO validations
  # at all. "Nothing unmet" is true of it; "every gate met" is not.
  defp ungated_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "No unmet gate ungated stage",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")

    assert Tasks.list_validations(stage.id) == [],
           "fixture floor — this stage must carry NO gates"

    {:ok, task} = Tasks.transition_task(task, "in_review")

    %{task: task, plan: plan, stage: stage}
  end

  defp pass!(stage, kind) do
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: kind})
    {:ok, passed} = Tasks.evaluate_validation(validation.id, "passed", %{"note" => "green"})
    passed
  end

  defp put_e2e_payload(attrs, "e2e_behavior"),
    do: Map.put(attrs, :evaluation_payload, @e2e_payload)

  defp put_e2e_payload(attrs, _kind), do: attrs

  defp maybe_transition(task, status) when task.status == status, do: task

  defp maybe_transition(task, status) do
    {:ok, task} = Tasks.transition_task(task, status)
    task
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_router!(%{task: task}) do
    runtime_id = "runtime-test-#{System.unique_integer([:positive])}"
    assignee = %{type: :federated, id: runtime_id}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    # `init/1` schedules a boot dispatch; drain it so the assertions observe the
    # dispatch WE inject rather than boot noise.
    barrier(task)

    %{pid: pid, runtime_id: runtime_id}
  end

  defp watch_dispatches!(runtime_id) do
    handler_id = "no-unmet-gate-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @suppressed_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dispatch_suppressed, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

    :ok
  end

  defp barrier(task) do
    :ok = sync_router(task.id)
    TaskRouter.current_status(task.id)
  end
end
