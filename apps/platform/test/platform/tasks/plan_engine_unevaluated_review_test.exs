defmodule Platform.Tasks.PlanEngineUnevaluatedReviewTest do
  @moduledoc """
  Task 01a0665e stage 3: a behavioural review gate whose ONLY failures are
  `could_not_evaluate` cases advances to deploy with the unevaluated cases
  listed on the task — instead of sitting `failed` forever because the case
  can never be run (01a03f4e: needs a real media device; 01a0666d: the branch
  the case was written for did not occur).

  Two fixes, both driven through `PlanEngine.evaluate_validation/2` directly:

    (a) `stage_verdict/1` for an e2e host stage — every failed row
        `could_not_evaluate` with a reason AND at least one `e2e_behavior`
        row `passed` -> the rows go `failed -> skipped` (evidence retained),
        the task is stamped `metadata["unevaluated_review_cases"]`, one
        engagement is posted, the stage passes;
    (b) `maybe_inject_deploy_or_complete/2` lifts a task the watchdog knocked
        to `blocked` (or a bounce returned to `in_progress`) back to
        `in_review` when its e2e host stage is `passed`, so the deploy edge
        fires. `@deployable_statuses` itself is unchanged (019ff788 control).

  Anti-vacuity mutations (each must redden the named test):
    * revert the verdict change            -> (1), (3), (6)
    * remove the in_review lift in (b)     -> (6) red, (1) green
    * drop the "at least one passed" rule  -> (4)
    * treat `:malformed` as could_not_evaluate -> (5)
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{DeployStageBuilder, Plan, PlanEngine, Stage, Validation}

  @e2e_payload %{
    "setup" => "open the call page on a dev server",
    "actions" => "join the call and toggle the mic",
    "expected" => "the mic indicator follows the toggle"
  }

  @unevaluated %{
    "disposition" => "could_not_evaluate",
    "reason" => "needs a real media device"
  }

  @genuine %{"summary" => "the mic indicator stayed muted after the toggle"}

  @malformed %{"disposition" => "could_not_evaluate", "reason" => "   "}

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Unevaluated review #{System.unique_integer([:positive])}",
        deploy_config: %{
          "default_strategy" => %{"type" => "pr_merge", "config" => %{}}
        }
      })

    %{project: project}
  end

  # ── (1) the shipped shape ─────────────────────────────────────────────

  test "(1) four passed + one could_not_evaluate passes the gate, skips the case, stamps the task, deploys",
       %{project: project} do
    ctx = reviewed_task(project)
    [c1, c2, c3, c4, c5] = ctx.cases

    for c <- [c1, c2, c3, c4], do: pass!(c)
    fail!(c5, @unevaluated)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"

    skipped = Repo.get!(Validation, c5.id)
    assert skipped.status == "skipped"

    assert skipped.evidence["disposition"] == "could_not_evaluate",
           "skipping must retain the reviewer's evidence, not blank it"

    assert Enum.map([c1, c2, c3, c4], &Repo.get!(Validation, &1.id).status) ==
             ~w(passed passed passed passed)

    task = Tasks.get_task_record(ctx.task.id)

    assert [entry] = task.metadata["unevaluated_review_cases"]
    assert entry["validation_id"] == c5.id
    assert entry["reason"] == "needs a real media device"
    assert {:ok, _, _} = DateTime.from_iso8601(entry["skipped_at"])

    assert task.status == "deploying"
    assert running_deploy_stage(ctx.plan)

    assert task.review_round_count == ctx.task.review_round_count,
           "a gate that passes spends no review round"

    assert engagement_count(ctx.space) == 1,
           "exactly ONE engagement lists the unevaluated cases for a human"

    [message] = engagements(ctx.space)
    assert message.content =~ c5.id
    assert message.content =~ "needs a real media device"
  end

  # ── (2) a genuine failure still fails ─────────────────────────────────

  test "(2) four passed + one GENUINE failure fails the gate and does not deploy",
       %{project: project} do
    ctx = reviewed_task(project)
    [c1, c2, c3, c4, c5] = ctx.cases

    for c <- [c1, c2, c3, c4], do: pass!(c)
    fail!(c5, @genuine)

    assert Repo.get!(Stage, ctx.host.id).status == "failed"
    assert Repo.get!(Validation, c5.id).status == "failed"

    task = Tasks.get_task_record(ctx.task.id)
    refute task.status == "deploying"
    assert task.status == "in_review"
    refute Map.has_key?(task.metadata || %{}, "unevaluated_review_cases")
    refute running_deploy_stage(ctx.plan)
    assert engagement_count(ctx.space) == 0
  end

  # ── (3) could_not_evaluate recorded FIRST ─────────────────────────────

  test "(3) a could_not_evaluate recorded first leaves the stage running; the later passes settle it",
       %{project: project} do
    ctx = reviewed_task(project)
    [c1, c2, c3, c4, c5] = ctx.cases

    fail!(c5, @unevaluated)

    assert Repo.get!(Stage, ctx.host.id).status == "running",
           "an unevaluated case recorded before its siblings must not fail the stage"

    assert Repo.get!(Validation, c5.id).status == "failed",
           "the row stays failed until the verdict is in"

    assert Tasks.get_task_record(ctx.task.id).status == "in_review"

    for c <- [c1, c2, c3, c4], do: pass!(c)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"
    assert Repo.get!(Validation, c5.id).status == "skipped"

    task = Tasks.get_task_record(ctx.task.id)
    assert [%{"validation_id" => id}] = task.metadata["unevaluated_review_cases"]
    assert id == c5.id
    assert task.status == "deploying"
    assert running_deploy_stage(ctx.plan)
    assert engagement_count(ctx.space) == 1
  end

  # ── (4) nothing passed: the gate did not run ──────────────────────────

  test "(4) every case could_not_evaluate and none passed still fails the gate",
       %{project: project} do
    ctx = reviewed_task(project)

    for c <- ctx.cases, do: fail!(c, @unevaluated)

    assert Repo.get!(Stage, ctx.host.id).status == "failed",
           "a gate with zero passed cases did not run; that is the router's bounce, not a pass"

    assert Enum.all?(ctx.cases, &(Repo.get!(Validation, &1.id).status == "failed"))

    task = Tasks.get_task_record(ctx.task.id)
    refute task.status == "deploying"
    refute Map.has_key?(task.metadata || %{}, "unevaluated_review_cases")
    refute running_deploy_stage(ctx.plan)
    assert engagement_count(ctx.space) == 0
  end

  # ── (5) the marker without a reason is a genuine failure ──────────────

  test "(5) a could_not_evaluate marker with a blank reason is malformed and fails the gate",
       %{project: project} do
    ctx = reviewed_task(project)
    [c1, c2, c3, c4, c5] = ctx.cases

    for c <- [c1, c2, c3, c4], do: pass!(c)
    fail!(c5, @malformed)

    assert Repo.get!(Stage, ctx.host.id).status == "failed"
    assert Repo.get!(Validation, c5.id).status == "failed"

    task = Tasks.get_task_record(ctx.task.id)
    refute task.status == "deploying"
    refute Map.has_key?(task.metadata || %{}, "unevaluated_review_cases")
    refute running_deploy_stage(ctx.plan)
  end

  # ── (6) the watchdog shape ────────────────────────────────────────────

  test "(6) a task the watchdog moved to blocked before the last verdict still ends deploying",
       %{project: project} do
    ctx = reviewed_task(project)
    [c1, c2, c3, c4, c5] = ctx.cases

    for c <- [c1, c2, c3, c4], do: pass!(c)

    # Stage 1's stamp and stage 2's hold are both on the task when the lift
    # runs. The lift is a `:system` actor: it must clear neither.
    {:ok, _} =
      Tasks.stamp_delivered_but_open(ctx.task.id, %{
        "pr_url" => "https://github.com/example/core/pull/1",
        "merge_commit_sha" => "abc123"
      })

    hold = file_needs_human_hold!(ctx)
    assert hold.status == "blocked"

    # The no-ack watchdog: `in_review -> blocked` with a reason.
    {:ok, blocked} =
      Tasks.stamp_blocked_reason(ctx.task.id, "Executor never acked the dispatch")

    assert blocked.status == "blocked"

    fail!(c5, @unevaluated)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"

    task = Tasks.get_task_record(ctx.task.id)

    assert task.status == "deploying",
           "a reviewed task must not be stranded at blocked by the deploy guard"

    assert running_deploy_stage(ctx.plan)
    assert [%{"validation_id" => id}] = task.metadata["unevaluated_review_cases"]
    assert id == c5.id

    assert Map.has_key?(task.metadata, "delivered_but_open"),
           "a system-actor lift must not clear stage 1's stamp (only done/cancelled do)"

    assert Repo.get!(ExecutionLease, hold.id).status == "blocked",
           "a system-actor lift must not release stage 2's needs_human hold"
  end

  # ── (7) 019ff788 control: no e2e host stage, no lift ──────────────────

  test "(7) a plan with no e2e host stage completing at in_progress still injects nothing",
       %{project: project} do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unreviewed task",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, tests} = Tasks.create_validation(%{stage_id: build.id, kind: "test_pass"})
    {:ok, _} = PlanEngine.start_stage(build.id)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pass!(tests)
      end)

    assert Repo.get!(Plan, plan.id).status == "completed"
    refute running_deploy_stage(plan)

    task = Tasks.get_task_record(task.id)
    assert task.status == "in_progress"
    refute task.status == "deploying"

    assert log =~ "NOT injecting deploy stage for task #{task.id}"
    assert log =~ "status in_progress is not in @deployable_statuses"
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  # A task at `in_review` (where the router puts it when the review gate
  # opens) with an approved plan: one settled implementation stage and a
  # RUNNING e2e host stage carrying five `e2e_behavior` cases. The project
  # supplies the `pr_merge` deploy strategy; the task supplies its target.
  defp reviewed_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Reviewed task",
        status: "in_review",
        deploy_target: "production"
      })

    assert Tasks.resolve_deploy_strategy(task)["type"] == "pr_merge",
           "the fixture must resolve the project's pr_merge strategy or the deploy assertions are vacuous"

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(build, "running")
    {:ok, _passed} = Tasks.transition_stage(running, "passed")

    {:ok, host} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Task-level review"})

    cases =
      for i <- 1..5 do
        {:ok, validation} =
          Tasks.create_validation(%{
            stage_id: host.id,
            kind: "e2e_behavior",
            evaluation_payload: Map.put(@e2e_payload, "case", "case #{i}")
          })

        validation
      end

    {:ok, _running} = PlanEngine.start_stage(host.id)

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "exec-unevaluated-#{n}",
        slug: "exec-unevaluated-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    %{task: task, plan: plan, host: host, cases: cases, space: space}
  end

  defp pass!(validation) do
    {:ok, _} =
      PlanEngine.evaluate_validation(validation.id, %{
        status: "passed",
        evidence: %{"summary" => "observed as expected"},
        evaluated_by: "test"
      })
  end

  defp fail!(validation, evidence) do
    {:ok, _} =
      PlanEngine.evaluate_validation(validation.id, %{
        status: "failed",
        evidence: evidence,
        evaluated_by: "test"
      })
  end

  # A `report_blocker(needs_human: true)` lease, the stage-2 hold shape.
  defp file_needs_human_hold!(ctx) do
    {:ok, _event} =
      Platform.Orchestration.record_runtime_event(%{
        "task_id" => ctx.task.id,
        "phase" => "execution",
        "runtime_id" => "runtime-unevaluated-#{System.unique_integer([:positive])}",
        "event_type" => "execution.blocked",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{
          "stage_id" => ctx.host.id,
          "description" => "A person must rule on the unevaluated case.",
          "needs_human" => true,
          "reported_by" => "agent"
        }
      })

    Repo.one!(
      from(l in ExecutionLease,
        where: l.task_id == ^ctx.task.id,
        order_by: [desc: l.inserted_at],
        limit: 1
      )
    )
  end

  defp running_deploy_stage(plan) do
    plan.id
    |> Tasks.list_stages()
    |> Enum.find(&(DeployStageBuilder.deploy_stage_name?(&1.name) and &1.status == "running"))
  end

  defp engagements(space) do
    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.filter(&String.contains?(&1.content, "could not evaluate"))
  end

  defp engagement_count(space), do: length(engagements(space))
end
