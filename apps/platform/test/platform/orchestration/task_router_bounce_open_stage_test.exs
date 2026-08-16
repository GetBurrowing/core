defmodule Platform.Orchestration.TaskRouterBounceOpenStageTest do
  @moduledoc """
  A failed review gate must leave the task with SOMEWHERE TO WORK.

  Task `01a006e7`. Written RED in stage 1 (tagged `:pending_fix`, excluded via
  `Platform.PendingFix`) and turned GREEN in stage 4, which wired
  `TaskRouter.bounce_to_in_progress/4` to
  `PlanEngine.open_remediation_stage/2`. The tag and its registry entry were
  deleted in the same commit as the fix, so this now runs in the default
  suite — which is the only run that proves the fix holds.

  ## The defect

  `TaskRouter.handle_review_stage_failure/3` routes every genuine review
  failure to `bounce_to_in_progress/3`, which does exactly one thing:
  `Tasks.transition_task(task, "in_progress")`. NO STAGE IS TOUCHED. The gate
  stage stays `failed` and every implementation stage stays `passed`, so the
  plan has no `pending` or `running` stage at all. The router then refuses to
  dispatch — `unresolved_stage_dispatch?/3` logs
  `no running or pending stage for a task at in_progress` on a loop — and a
  human has to spawn the fixing executor by hand.

  Observed first-hand on task `01a006c2` (2026-08-15): 5 `e2e_behavior`
  validations on the task-level gate, one failed, and the router logged
  `Stage failure bounced task back to in_progress` followed by the withheld
  dispatch line indefinitely.

  ## ANTI-VACUITY (binding)

  ASSERT ON THE POST-BOUNCE STATE, NOT ON THE BOUNCE FIRING.
  `task.status == "in_progress"` is ALREADY TRUE in every broken instance —
  it is precisely the assertion that passes while the bug is live. The only
  discriminating observation is over the PLAN's stages:

      Enum.any?(stages, & &1.status in ["pending", "running"])

  ## FIXTURE TRAP (binding)

  A plan whose failing stage is also its only implementation stage cannot
  distinguish "reopen the owning stage" from "reopen the last stage" from
  "open a new stage" — all three look identical. So the fixture carries
  THREE passed implementation stages plus the synthesized task-level gate,
  and the test records WHICH stage reopened, so those three candidate fixes
  give three different observable outcomes.

  ## Do not break the recovery path

  `PlanEngine.maybe_advance_resolved_stage/1` already reopens a `failed`
  stage whose validations ALL flip to `passed`. That is why the live instance
  self-healed once its validation was re-dispositioned, and it must keep
  working. The second test here pins it as a standing fact and is GREEN on
  `main` today — it is the direction control for whatever stage 2 changes.

  No `Process.sleep`. The barrier is `TaskRouter.current_status/1`, a
  `GenServer.call` answered only after every queued message is handled.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  @e2e_payload %{
    "setup" => "A task sits at its task-level review gate.",
    "actions" => "Fail one behavioural check.",
    "expected" => "The task bounces to in_progress WITH a stage to work in."
  }

  setup do
    # The router is a separate process that hits the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Bounce Open Stage Project",
        repo_url: "https://github.com/test/bounce-open-stage"
      })

    %{project: project}
  end

  describe "a failed review gate bounces the task to in_progress" do
    test "and leaves an open stage for the executor to land in", %{project: project} do
      %{task: task, gate_stage: gate_stage, impl_stages: impl_stages} = gated_task(project)

      _pid = start_router!(task)

      {:ok, _running} = PlanEngine.start_stage(gate_stage.id)
      barrier(task)
      assert Tasks.get_task_record(task.id).status == "in_review"

      # One genuine behavioural failure — no `could_not_evaluate` marker, so
      # the router spends a review round and bounces.
      [failing | _rest] = Tasks.list_validations(gate_stage.id)

      log =
        capture_log(fn ->
          {:ok, _failed} =
            PlanEngine.evaluate_validation(failing.id, %{
              status: "failed",
              evaluated_by: "test",
              evidence: %{"summary" => "cross-org denial did not hold"}
            })

          barrier(task)
        end)

      plan = Tasks.get_plan(Tasks.current_plan(task.id).id)
      stages = plan.stages

      # The bounce itself. TRUE ON BROKEN CODE — asserted only so a failure of
      # the real assertion below cannot be misread as "the bounce never ran".
      assert Tasks.get_task_record(task.id).status == "in_progress",
             "precondition: the failed gate must bounce the task to in_progress"

      # ── THE DISCRIMINATING ASSERTION ──────────────────────────────────
      open = Enum.filter(stages, &(&1.status in ["pending", "running"]))

      assert open != [],
             "a task bounced to in_progress has no running or pending stage — " <>
               "the router will withhold every dispatch for it. Stage statuses: " <>
               inspect(Enum.map(stages, &{&1.position, &1.name, &1.status}))

      # ── AND THE DISPATCH ACTUALLY WENT OUT ────────────────────────────
      # A stage that exists but is never dispatched is a half fix: the human
      # still has to spawn the executor. `suppress_unresolved_stage_dispatch/3`
      # is the exact line the live instance logged on a loop, so its ABSENCE
      # is the observation, and a `running` stage is the positive half — the
      # router only starts one once it has resolved a dispatch subject.
      refute log =~ "suppressed stage-scoped dispatch",
             "the router withheld the dispatch even though a stage was open"

      assert Enum.any?(stages, &(&1.status == "running")),
             "no stage was started for the bounced task — nothing was dispatched. " <>
               "Stage statuses: " <> inspect(Enum.map(stages, &{&1.position, &1.name, &1.status}))

      # WHICH stage reopened is deliberately NOT asserted here — stage 2 owns
      # that choice. The three passed implementation stages exist so the choice
      # is OBSERVABLE: reopening the owning gate, the last implementation stage,
      # or a freshly appended stage each produce a different tuple list below.
      # A single-stage fixture would collapse all three into one outcome.
      assert length(impl_stages) == 3
    end
  end

  describe "fixture guard (must fire before the silence above means anything)" do
    test "the plan really carries three passed impl stages plus a gate", %{project: project} do
      %{task: task, gate_stage: gate_stage} = gated_task(project)

      plan = Tasks.get_plan(Tasks.current_plan(task.id).id)

      assert Enum.count(plan.stages, &(&1.status == "passed")) == 3
      assert Enum.find(plan.stages, &(&1.id == gate_stage.id)).status == "pending"
      assert length(Tasks.list_validations(gate_stage.id)) == 3
    end
  end

  describe "direction control: the existing recovery path still works" do
    # `PlanEngine.maybe_advance_resolved_stage/1` is what let the live instance
    # self-heal when a human re-dispositioned the failed validation.
    #
    # NO ROUTER HERE, and that is a deliberate change made in stage 4. This
    # test pins a PLAN-ENGINE property: a `failed` stage whose validations all
    # flip to `passed` reopens. With a router attached, the stage never sits
    # `failed` long enough to re-disposition — the bounce now immediately
    # calls `open_remediation_stage/2`, which resets the gate to `pending` by
    # design. Driving the engine directly is the only way left to CONSTRUCT
    # the failed-then-repassed state this test was written to observe;
    # keeping the router would have left it asserting a state the fix makes
    # unreachable, i.e. passing while proving nothing.
    test "re-passing every validation reopens and advances the failed stage", %{
      project: project
    } do
      %{gate_stage: gate_stage} = gated_task(project)

      {:ok, _running} = PlanEngine.start_stage(gate_stage.id)

      validations = Tasks.list_validations(gate_stage.id)
      [failing | rest] = validations

      {:ok, _failed} =
        PlanEngine.evaluate_validation(failing.id, %{status: "failed", evaluated_by: "test"})

      assert reload_stage(gate_stage.id).status == "failed",
             "guard: the failed state this test recovers from must actually be reached"

      for v <- rest do
        {:ok, _} = PlanEngine.evaluate_validation(v.id, %{status: "passed", evaluated_by: "test"})
      end

      {:ok, _repassed} =
        PlanEngine.evaluate_validation(failing.id, %{status: "passed", evaluated_by: "test"})

      refute reload_stage(gate_stage.id).status == "failed",
             "a failed stage whose validations all flip to passed must reopen — " <>
               "this is the recovery path task 01a006e7 must not break"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # An `in_progress` task with an approved FOUR-stage plan: three settled
  # implementation stages and a pending task-level review gate carrying three
  # `e2e_behavior` validations.
  #
  # FIXTURE TRAP, restated: three implementation stages, not one. With a single
  # stage, "reopen the owning stage", "reopen the last stage" and "append a new
  # stage" are indistinguishable outcomes.
  defp gated_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Bounced review task",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    impl_stages =
      for {name, position} <- [{"Schema", 1}, {"Context", 2}, {"LiveView", 3}] do
        {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
        {:ok, running} = Tasks.transition_stage(stage, "running")
        {:ok, passed} = Tasks.transition_stage(running, "passed")
        passed
      end

    {:ok, gate_stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 4, name: "Task-level review"})

    for _ <- 1..3 do
      {:ok, _validation} =
        Tasks.create_validation(%{
          stage_id: gate_stage.id,
          kind: "e2e_behavior",
          evaluation_payload: @e2e_payload
        })
    end

    %{task: task, plan: plan, impl_stages: impl_stages, gate_stage: gate_stage}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp start_router!(task) do
    assignee = %{type: :federated, id: "runtime-test-#{System.unique_integer([:positive])}"}
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

    barrier(task)

    pid
  end

  defp barrier(task), do: TaskRouter.current_status(task.id)

  defp reload_stage(id), do: Platform.Repo.get!(Platform.Tasks.Stage, id)
end
