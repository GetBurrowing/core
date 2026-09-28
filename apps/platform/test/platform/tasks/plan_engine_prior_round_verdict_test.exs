defmodule Platform.Tasks.PlanEnginePriorRoundVerdictTest do
  @moduledoc """
  Task 01a0e8c1 stage 1: an e2e host stage is judged on ITS OWN round. A
  `failed` row whose `evaluated_at` is strictly before the stage's
  `started_at` is a PRIOR-ROUND verdict and is treated as owed, exactly like
  a `pending` row, so it can neither satisfy the `could_not_evaluate` skip arm
  nor let the stage count as resolved.

  The specimen (task 01a0d4a0, stage 4, 2026-09-28 04:13:15): a previous
  review round left all five e2e rows `failed(could_not_evaluate)`, the stage
  was put back to `running` WITHOUT re-pending them, the reviewer passed case
  1, and the four stale cne siblings satisfied `{:passed_with_unevaluated, _}`
  -> the stage passed with four cases skipped. The reviewer's four genuine
  FAILs then landed on a stage already `passed`.

  Everything is driven through `PlanEngine.evaluate_validation/2`. A prior-
  round row is built by writing `evaluated_at` directly (`Repo.update_all`)
  to a time BEFORE the stage's `started_at`.

  Mutations and the test that reddens for each:
    * drop the prior-round clause from the hold arm        -> (1), (2)
    * `<=` instead of `<` (equal timestamps go stale)       -> (6) boundary
    * `all_validations_resolved?/1` counts only pending/running
                                                            -> (1b) agreement
    * reset `started_at` in the flip-reopen                 -> (5)
    * apply the prior-round clause to PASSED rows too       -> (4c)
  """
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{DeployStageBuilder, PlanEngine, Stage, Validation}

  @e2e_payload %{
    "setup" => "open the call page on a dev server",
    "actions" => "join the call and barge in",
    "expected" => "the agent stops speaking"
  }

  @unevaluated %{"disposition" => "could_not_evaluate", "reason" => "no LiveKit route"}

  @genuine %{"summary" => "the agent kept speaking over the barge-in"}

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Prior round #{System.unique_integer([:positive])}",
        deploy_config: %{
          "default_strategy" => %{"type" => "pr_merge", "config" => %{}}
        }
      })

    %{project: project}
  end

  # ── (1) specimen replay ───────────────────────────────────────────────

  test "(1) specimen: four PRIOR-ROUND cne rows cannot satisfy the skip arm when the fifth passes",
       %{project: project} do
    ctx = specimen!(project)
    [c1 | stale] = ctx.cases

    pass!(c1)

    host = Repo.get!(Stage, ctx.host.id)

    assert host.status == "running",
           "prior-round could_not_evaluate rows are owed, not a settled round"

    assert Enum.map(stale, &Repo.get!(Validation, &1.id).status) ==
             ~w(failed failed failed failed),
           "stale rows must stay failed, never be skipped"

    task = Tasks.get_task_record(ctx.task.id)
    refute Map.has_key?(task.metadata || %{}, "unevaluated_review_cases")
    assert Repo.get!(Stage, ctx.after.id).status == "pending", "no next stage may start"
    refute deploy_stage(ctx.plan)
  end

  test "(1b) all_validations_resolved?/1 agrees with the verdict on a prior-round row",
       %{project: project} do
    ctx = specimen!(project)
    [c1 | stale] = ctx.cases
    pass!(c1)

    host = Repo.get!(Stage, ctx.host.id)

    refute PlanEngine.all_validations_resolved?(host),
           "a prior-round failed row is owed; the resolved predicate must say so too"

    # Re-judging each stale row in the current round resolves it.
    for c <- stale, do: fail!(c, @genuine)

    host = Repo.get!(Stage, ctx.host.id)
    assert PlanEngine.all_validations_resolved?(host)
  end

  # ── (2) the round then settles on genuine failures ────────────────────

  test "(2) genuine failures written onto the stale rows fail the stage once the round settles, and remediation opens",
       %{project: project} do
    ctx = specimen!(project)
    [c1 | stale] = ctx.cases
    pass!(c1)

    [s1, s2, s3, s4] = stale

    for c <- [s1, s2, s3] do
      fail!(c, @genuine)

      assert Repo.get!(Stage, ctx.host.id).status == "running",
             "the round is not settled while any prior-round row is owed"
    end

    fail!(s4, @genuine)

    host = Repo.get!(Stage, ctx.host.id)
    assert host.status == "failed"
    refute host.status == "passed"

    assert {:ok, _remediation} = PlanEngine.open_remediation_stage(host.id, "feedback")
    assert Repo.get!(Stage, ctx.host.id).status == "pending"
  end

  # ── (3) two e2e rows, both pending ────────────────────────────────────

  test "(3) two pending e2e rows: a pass holds, a genuine failure then fails the stage",
       %{project: project} do
    ctx = host!(project, 2)
    [a, b] = ctx.cases

    pass!(a)
    assert Repo.get!(Stage, ctx.host.id).status == "running"

    fail!(b, @genuine)
    assert Repo.get!(Stage, ctx.host.id).status == "failed"
  end

  # ── (4) positive controls ─────────────────────────────────────────────

  test "(4a) every row passed completes the stage", %{project: project} do
    ctx = host!(project, 3)
    for c <- ctx.cases, do: pass!(c)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"
  end

  test "(4b) CURRENT-round 4 passed + 1 could_not_evaluate still takes the skip arm (01a0665e)",
       %{project: project} do
    ctx = host!(project, 5)
    [c1, c2, c3, c4, c5] = ctx.cases

    for c <- [c1, c2, c3, c4], do: pass!(c)
    fail!(c5, @unevaluated)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"
    assert Repo.get!(Validation, c5.id).status == "skipped"

    task = Tasks.get_task_record(ctx.task.id)
    assert [%{"validation_id" => id}] = task.metadata["unevaluated_review_cases"]
    assert id == c5.id
  end

  test "(4c) a PRIOR-ROUND passed row plus a current pass completes the stage",
       %{project: project} do
    ctx = host!(project, 2)
    [a, b] = ctx.cases

    stamp!(a, "passed", %{"summary" => "observed last round"}, before(ctx.host))
    pass!(b)

    assert Repo.get!(Stage, ctx.host.id).status == "passed",
           "a passed verdict is a verdict whatever round wrote it; only failed rows go stale"
  end

  # ── (5) flip-reopen re-judges its own round ───────────────────────────

  test "(5) failed -> passed flip reopens and passes; the reopen does not make its own round stale",
       %{project: project} do
    ctx = host!(project, 3)
    [p, c, g] = ctx.cases
    started_at = Repo.get!(Stage, ctx.host.id).started_at

    pass!(p)
    fail!(c, %{"disposition" => "could_not_evaluate", "reason" => "needs a media device"})
    fail!(g, @genuine)

    assert Repo.get!(Stage, ctx.host.id).status == "failed"

    pass!(g)

    host = Repo.get!(Stage, ctx.host.id)
    assert host.status == "passed", "the designed failed->passed flip must still land"
    assert Repo.get!(Validation, c.id).status == "skipped"

    assert DateTime.compare(host.started_at, started_at) == :eq,
           "the flip-reopen must not reset started_at"

    task = Tasks.get_task_record(ctx.task.id)
    assert [%{"validation_id" => id}] = task.metadata["unevaluated_review_cases"]
    assert id == c.id
  end

  # ── (6) boundary: equal timestamps are current ────────────────────────

  test "(6) a failed row evaluated in the SAME microsecond as started_at counts as current",
       %{project: project} do
    ctx = host!(project, 2)
    [a, b] = ctx.cases
    host = Repo.get!(Stage, ctx.host.id)

    stamp!(a, "failed", @unevaluated, host.started_at)
    pass!(b)

    assert Repo.get!(Stage, ctx.host.id).status == "passed",
           "strictly-before is the rule: evaluated_at == started_at is this round"

    assert Repo.get!(Validation, a.id).status == "skipped"
  end

  test "(7) nil evaluated_at on a failed row counts as current (legacy rows)",
       %{project: project} do
    ctx = host!(project, 2)
    [a, b] = ctx.cases

    stamp!(a, "failed", @unevaluated, nil)
    pass!(b)

    assert Repo.get!(Stage, ctx.host.id).status == "passed"
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  # The 01a0d4a0 stage-4 shape: test_pass + lint_pass passed, five e2e rows,
  # four of them failed(could_not_evaluate) by a PRIOR round.
  defp specimen!(project) do
    ctx = host!(project, 5, gates: true)
    [_c1 | stale] = ctx.cases

    for gate <- ctx.gates, do: pass!(gate)

    for c <- stale, do: stamp!(c, "failed", @unevaluated, before(ctx.host))

    assert Repo.get!(Stage, ctx.host.id).status == "running"
    ctx
  end

  defp host!(project, count, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Prior round task",
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

    gates =
      if Keyword.get(opts, :gates, false) do
        for kind <- ~w(test_pass lint_pass) do
          {:ok, v} = Tasks.create_validation(%{stage_id: host.id, kind: kind})
          v
        end
      else
        []
      end

    cases =
      for i <- 1..count do
        {:ok, validation} =
          Tasks.create_validation(%{
            stage_id: host.id,
            kind: "e2e_behavior",
            evaluation_payload: Map.put(@e2e_payload, "case", "case #{i}")
          })

        validation
      end

    {:ok, host} = PlanEngine.start_stage(host.id)
    assert host.started_at, "the fixture's stage must carry a started_at or the rule is vacuous"

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "exec-prior-round-#{n}",
        slug: "exec-prior-round-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    %{
      task: task,
      plan: plan,
      host: host,
      after: after_stage,
      gates: gates,
      cases: cases,
      space: space
    }
  end

  defp before(%Stage{id: id}) do
    %Stage{started_at: started_at} = Repo.get!(Stage, id)
    DateTime.add(started_at, -60, :second)
  end

  defp stamp!(validation, status, evidence, evaluated_at) do
    {1, _} =
      Repo.update_all(from(v in Validation, where: v.id == ^validation.id),
        set: [
          status: status,
          evidence: evidence,
          evaluated_by: "reviewer",
          evaluated_at: evaluated_at
        ]
      )
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

  defp deploy_stage(plan) do
    plan.id
    |> Tasks.list_stages()
    |> Enum.find(&DeployStageBuilder.deploy_stage_name?(&1.name))
  end
end
