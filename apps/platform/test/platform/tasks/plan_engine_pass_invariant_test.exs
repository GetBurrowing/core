defmodule Platform.Tasks.PlanEnginePassInvariantTest do
  @moduledoc """
  Task 01a0e8c1 stage 2: the pass invariant is enforced at the ONE write that
  makes a stage `passed` (`transition_stage/4`), not inferred from the verdict.

  After stage 1 the verdict never asks for a pass over an unmet row, so the
  guard is reached here by INJECTING the failing dependency: a telemetry
  handler on `[:platform, :tasks, :validation_evaluated]` fires synchronously,
  in the caller's process and transaction, when `skip_unevaluated_validations/2`
  moves a row to `skipped` — i.e. AFTER the verdict read and BEFORE the
  `passed` transition. The handler inserts one unmet row on the stage, which
  is exactly the window a concurrent writer would hit.

  The refused pass rolls back to the savepoint taken before the skips, so the
  injected row is rolled back with them; the refusal telemetry is what names
  it.

  Assertions (spec letters):
    (a) the stage stays `running`;
    (b) `[:platform, :tasks, :stage_pass_refused]` fires with the row ids;
    (c) the validation write that triggered the refused pass is persisted;
    (d) a zero-validation stage and an all-passed stage still pass;
    (e) no row is left `skipped` on a stage that stayed running.

  Mutations and the test that reddens for each:
    * delete the guard                       -> (1), (2), (3)
    * treat `skipped` as unsatisfied          -> (5); also
                                                plan_engine_unevaluated_review_test (1), (3), (6)
    * keep `{:ok, _} =` in one caller         -> (1)/(2) for `advance_stage/1`,
                                                (3) for `advance/2` (MatchError)
    * drop `failed` from the refused set      -> (2)
  """
  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage, Validation}

  @e2e_payload %{
    "setup" => "open the call page on a dev server",
    "actions" => "join the call and toggle the mic",
    "expected" => "the mic indicator follows the toggle"
  }

  @unevaluated %{"disposition" => "could_not_evaluate", "reason" => "needs a real media device"}

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Pass invariant #{System.unique_integer([:positive])}",
        deploy_config: %{
          "default_strategy" => %{"type" => "pr_merge", "config" => %{}}
        }
      })

    test_pid = self()
    handler_id = "pass-refused-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :tasks, :stage_pass_refused],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:pass_refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{project: project}
  end

  # ── (1) advance_stage/1 path, injected PENDING row ────────────────────

  test "(1) evaluate_validation: a pending row injected before the pass is refused; stage stays running, the write commits, skips roll back",
       %{project: project} do
    ctx = host!(project)
    [a, b] = ctx.cases

    fail!(a, @unevaluated)
    assert Repo.get!(Stage, ctx.host.id).status == "running"

    inject_on_skip!(ctx.host.id, "pending")
    pass!(b)

    assert_received {:injected, injected_id}
    assert_refused(ctx.host.id, [injected_id])

    # (a)
    assert Repo.get!(Stage, ctx.host.id).status == "running"
    assert Repo.get!(Stage, ctx.after.id).status == "pending"

    # (c)
    persisted = Repo.get!(Validation, b.id)
    assert persisted.status == "passed"
    assert persisted.evaluated_at

    # (e)
    assert Repo.get!(Validation, a.id).status == "failed",
           "a skip written for a refused pass must not survive"

    refute Map.has_key?(
             Tasks.get_task_record(ctx.task.id).metadata || %{},
             "unevaluated_review_cases"
           )

    assert engagement_count(ctx.space) == 0
  end

  # ── (2) same path, injected FAILED row ────────────────────────────────

  test "(2) evaluate_validation: a failed row injected before the pass is refused",
       %{project: project} do
    ctx = host!(project)
    [a, b] = ctx.cases

    fail!(a, @unevaluated)
    inject_on_skip!(ctx.host.id, "failed")
    pass!(b)

    assert_received {:injected, injected_id}
    assert_refused(ctx.host.id, [injected_id])

    assert Repo.get!(Stage, ctx.host.id).status == "running"
    assert Repo.get!(Validation, b.id).status == "passed"
    assert Repo.get!(Validation, a.id).status == "failed"
  end

  # ── (3) advance/2 path ────────────────────────────────────────────────

  test "(3) advance/2 over rows written by the bare writer: the refused pass returns the plan and leaves the stage running",
       %{project: project} do
    ctx = host!(project)
    [a, b] = ctx.cases

    # `Tasks.evaluate_validation/3` writes the row and does not advance.
    {:ok, _} = Tasks.evaluate_validation(a.id, "failed", @unevaluated)
    {:ok, _} = Tasks.evaluate_validation(b.id, "passed", %{"summary" => "ok"})

    inject_on_skip!(ctx.host.id, "pending")

    assert {:ok, plan} = PlanEngine.advance(ctx.plan.id, stage_id: ctx.host.id)

    assert_received {:injected, injected_id}
    assert_refused(ctx.host.id, [injected_id])

    assert Enum.find(plan.stages, &(&1.id == ctx.host.id)).status == "running"
    assert Repo.get!(Stage, ctx.host.id).status == "running"
    assert Repo.get!(Stage, ctx.after.id).status == "pending"
    assert Repo.get!(Validation, a.id).status == "failed"
    assert Repo.get!(Validation, b.id).status == "passed"
  end

  # ── (4) positive controls ─────────────────────────────────────────────

  test "(4a) a zero-validation stage still passes (019fec3a)", %{project: project} do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Zero rows"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "No gates"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    assert {:ok, _plan} = PlanEngine.advance(plan.id, stage_id: stage.id)
    assert Repo.get!(Stage, stage.id).status == "passed"
    refute_received {:pass_refused, _, _}
  end

  test "(4b) an all-passed stage still passes", %{project: project} do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "All passed"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, t} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
    {:ok, l} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})
    {:ok, _} = PlanEngine.start_stage(stage.id)

    pass!(t)
    assert Repo.get!(Stage, stage.id).status == "running"
    pass!(l)

    assert Repo.get!(Stage, stage.id).status == "passed"
    refute_received {:pass_refused, _, _}
  end

  # ── (5) skipped counts as satisfied ───────────────────────────────────

  test "(5) the could_not_evaluate skip arm still passes: skipped rows satisfy the guard",
       %{project: project} do
    ctx = host!(project)
    [a, b] = ctx.cases

    fail!(a, @unevaluated)
    pass!(b)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"
    assert Repo.get!(Validation, a.id).status == "skipped"
    assert Repo.get!(Stage, ctx.after.id).status == "running"
    assert engagement_count(ctx.space) == 1
    refute_received {:pass_refused, _, _}
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  defp host!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Pass invariant task",
        status: "in_review",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(build, "running")
    {:ok, _passed} = Tasks.transition_stage(running, "passed")

    {:ok, host} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Task-level review"})

    {:ok, after_stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "After review"})

    cases =
      for i <- 1..2 do
        {:ok, v} =
          Tasks.create_validation(%{
            stage_id: host.id,
            kind: "e2e_behavior",
            evaluation_payload: Map.put(@e2e_payload, "case", "case #{i}")
          })

        v
      end

    {:ok, host} = PlanEngine.start_stage(host.id)

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "exec-pass-invariant-#{n}",
        slug: "exec-pass-invariant-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    %{task: task, plan: plan, host: host, after: after_stage, cases: cases, space: space}
  end

  # Insert ONE unmet row on `stage_id` the first time a row of that stage is
  # moved to `skipped`. Runs in the caller's process, inside its transaction.
  # Must never raise: a raising handler is detached VM-wide.
  defp inject_on_skip!(stage_id, status) do
    test_pid = self()
    handler_id = "inject-#{System.unique_integer([:positive])}"
    flag = {:injected, handler_id}

    :telemetry.attach(
      handler_id,
      [:platform, :tasks, :validation_evaluated],
      fn _event, _measurements, metadata, _ ->
        try do
          if metadata.stage_id == stage_id and metadata.status == "skipped" and
               self() == test_pid and not Process.get(flag, false) do
            Process.put(flag, true)

            row =
              Repo.insert!(%Validation{stage_id: stage_id, kind: "test_pass", status: status})

            send(test_pid, {:injected, row.id})
          end
        rescue
          _ -> :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_refused(stage_id, ids) do
    assert_received {:pass_refused, %{count: count}, metadata}
    assert metadata.stage_id == stage_id
    assert metadata.validation_ids == ids
    assert count == length(ids)
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

  defp engagement_count(space) do
    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.count(&String.contains?(&1.content, "could not evaluate"))
  end
end
