defmodule Platform.Tasks.PlanEngineTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks
  alias Platform.Tasks.DeployStageBuilder
  alias Platform.Tasks.PlanEngine

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Engine Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Engine Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    %{project: project, task: task, plan: plan}
  end

  # ── start_stage/1 ─────────────────────────────────────────────────────

  describe "start_stage/1" do
    test "transitions pending stage to running", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      assert {:ok, started} = PlanEngine.start_stage(stage.id)
      assert started.status == "running"
      assert started.started_at != nil
    end

    test "rejects starting a non-pending stage", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(stage.id)

      # Already running — can't start again
      assert {:error, :invalid_transition} = PlanEngine.start_stage(stage.id)
    end

    test "returns error for nonexistent stage" do
      assert {:error, :not_found} = PlanEngine.start_stage(Ecto.UUID.generate())
    end
  end

  # ── evaluate_validation/2 ─────────────────────────────────────────────

  describe "evaluate_validation/2" do
    setup %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(stage.id)
      stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)

      {:ok, v1} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      {:ok, v2} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

      %{stage: stage, v1: v1, v2: v2}
    end

    test "records pass result on a validation", %{v1: v1} do
      result = %{status: "passed", evidence: %{"exit_code" => 0}, evaluated_by: "system"}
      assert {:ok, updated} = PlanEngine.evaluate_validation(v1.id, result)
      assert updated.status == "passed"
      assert updated.evidence == %{"exit_code" => 0}
      assert updated.evaluated_by == "system"
      assert updated.evaluated_at != nil
    end

    test "records fail result on a validation", %{v1: v1} do
      result = %{status: "failed", evidence: %{"error" => "tests failed"}}
      assert {:ok, updated} = PlanEngine.evaluate_validation(v1.id, result)
      assert updated.status == "failed"
    end

    test "auto-advances stage when all validations pass", %{stage: stage, v1: v1, v2: v2} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "passed"
    end

    test "auto-advances stage to failed when a validation fails", %{stage: stage, v1: v1, v2: v2} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "failed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert updated_stage.status == "failed"
    end

    test "reopens a failed stage when its last failed validation later passes", %{
      stage: stage,
      v1: v1,
      v2: v2
    } do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})
      PlanEngine.evaluate_validation(v2.id, %{status: "failed"})

      failed_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert failed_stage.status == "failed"
      assert failed_stage.completed_at != nil

      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      recovered_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      assert recovered_stage.status == "passed"
      assert recovered_stage.started_at != nil
      assert recovered_stage.completed_at != nil
    end

    test "does not advance when validations are still pending", %{stage: stage, v1: v1} do
      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})

      updated_stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)
      # v2 still pending, so stage stays running
      assert updated_stage.status == "running"
    end

    test "raises on invalid result status", %{v1: v1} do
      assert_raise ArgumentError, fn ->
        PlanEngine.evaluate_validation(v1.id, %{status: "unknown"})
      end
    end
  end

  # ── advance/1 ─────────────────────────────────────────────────────────

  # ── advance/2 stage scoping (task 019fec3a) ───────────────────────────

  describe "advance/2 :stage_id scoping" do
    test "no-ops when the asserted stage is not the current stage", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Ship"})

      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id, stage_id: s1.id)

      # s1 passed, s2 auto-started. Asserting s1 again must not touch s2,
      # which has zero validations and would otherwise sweep to "passed".
      assert {:ok, updated} = PlanEngine.advance(plan.id, stage_id: s1.id)

      by_position = Enum.sort_by(updated.stages, & &1.position)
      assert Enum.map(by_position, & &1.status) == ["passed", "running"]
      assert Enum.find(by_position, &(&1.id == s2.id)).status == "running"
    end

    test "advances normally when the asserted stage IS the current stage", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Ship"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      assert {:ok, updated} = PlanEngine.advance(plan.id, stage_id: s1.id)

      by_position = Enum.sort_by(updated.stages, & &1.position)
      assert Enum.map(by_position, & &1.status) == ["passed", "running"]
    end

    test "advance/1 stays plan-scoped so existing callers are unchanged", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Ship"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      assert {:ok, updated} = PlanEngine.advance(plan.id)
      by_position = Enum.sort_by(updated.stages, & &1.position)
      assert Enum.map(by_position, & &1.status) == ["passed", "running"]
    end

    test "passed-transition telemetry carries completed_by when asserted", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      handler_id = "stage-scope-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :tasks, :stage_transitioned],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:stage_transitioned, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} = PlanEngine.advance(plan.id, stage_id: s1.id, completed_by: "agent-dalton")

      assert_receive {:stage_transitioned, %{to: "passed", completed_by: "agent-dalton"}}
    end

    test "swept passed-transitions omit completed_by entirely", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      handler_id = "stage-scope-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :tasks, :stage_transitioned],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:stage_transitioned, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} = PlanEngine.advance(plan.id)

      assert_receive {:stage_transitioned, %{to: "passed"} = metadata}
      refute Map.has_key?(metadata, :completed_by)
    end
  end

  describe "advance/1" do
    test "advances to next stage when current passes (auto-starts next)", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      # No validations on s1 → all passed → next stage auto-starts
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      stage_statuses = Enum.map(updated_plan.stages, & &1.status)
      assert List.first(stage_statuses) == "passed"
      # Next stage is auto-started to "running" (not left as "pending")
      assert List.last(stage_statuses) == "running"
    end

    test "completes plan when last stage passes", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      {:ok, _} = PlanEngine.start_stage(s1.id)

      # No validations → auto-passes
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      assert updated_plan.status == "completed"
    end

    test "marks stage failed when validations fail", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{"error" => "boom"})

      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      stage = Enum.find(updated_plan.stages, &(&1.position == 1))
      assert stage.status == "failed"
    end

    test "completes the plan when a previously failed final-stage validation later passes", %{
      plan: plan
    } do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "ci_check"})

      PlanEngine.evaluate_validation(v1.id, %{status: "failed"})
      failed_plan = Platform.Repo.get!(Platform.Tasks.Plan, plan.id)
      refute failed_plan.status == "completed"

      PlanEngine.evaluate_validation(v1.id, %{status: "passed"})

      completed_plan = Platform.Repo.get!(Platform.Tasks.Plan, plan.id)
      assert completed_plan.status == "completed"

      recovered_stage = Platform.Repo.get!(Platform.Tasks.Stage, s1.id)
      assert recovered_stage.status == "passed"
    end

    test "no-op when validations are still pending", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})

      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      stage = Enum.find(updated_plan.stages, &(&1.position == 1))
      assert stage.status == "running"
    end

    test "all stages passed completes the plan", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Run and pass s1 — s2 auto-starts
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # s2 is already running (auto-started), advance again to complete
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
    end

    test "plan not completed if a stage failed", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      # Pass s1 — s2 auto-starts
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # s2 is already running (auto-started), add a failing validation
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{})
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      # Plan should NOT be completed because s2 failed
      refute updated_plan.status == "completed"
    end

    # ── Task 019f9b34: `advance/1`'s nil-current-stage branch ──────────────
    #
    # `current_stage/1` returns nil for [passed, failed] exactly as it does for
    # [passed, passed]. The nil branch used to call `complete_plan/1`
    # unconditionally, so a SECOND `advance/1` on a plan with a failed stage
    # silently completed it. That is incident 019f9ae5 in three lines.

    test "a second advance/1 does not complete a plan that still has a failed stage", %{
      plan: plan
    } do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Deploy"})

      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      Tasks.evaluate_validation(v1.id, "failed", %{})
      {:ok, _} = PlanEngine.advance(plan.id)

      # Second call: no stage is running or pending, so `current_stage/1`
      # returns nil. The plan must still NOT complete.
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      refute updated_plan.status == "completed",
             "a plan with a failed stage must not complete via advance/1's nil branch (019f9b34)"

      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status != "completed"
      assert Platform.Repo.get!(Platform.Tasks.Stage, s2.id).status == "failed"
    end

    test "three-stage production shape: [passed, passed, failed] never completes, then does once resolved",
         %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Verify"})
      {:ok, s3} = Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "Task-level review"})

      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # s3 is running now; fail its validation.
      {:ok, v3} = Tasks.create_validation(%{stage_id: s3.id, kind: "manual_approval"})
      Tasks.evaluate_validation(v3.id, "failed", %{})
      {:ok, _} = PlanEngine.advance(plan.id)

      assert Platform.Repo.get!(Platform.Tasks.Stage, s2.id).status == "passed"
      assert Platform.Repo.get!(Platform.Tasks.Stage, s3.id).status == "failed"

      # This is the call the executor's `stage_complete` made on 2026-07-25.
      assert {:ok, drifted_plan} = PlanEngine.advance(plan.id)

      refute drifted_plan.status == "completed",
             "[passed, passed, failed] must not complete the plan (019f9ae5 timeline)"

      # The guard defers completion, it does not deadlock it: resolving s3
      # completes the plan.
      {:ok, _} = PlanEngine.evaluate_validation(v3.id, %{status: "passed"})

      assert Platform.Repo.get!(Platform.Tasks.Stage, s3.id).status == "passed"
      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status == "completed"
    end

    test "a plan with zero stages still completes via advance/1", %{plan: plan} do
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)
      assert updated_plan.stages == []
      assert updated_plan.status == "completed"
    end
  end

  # ── Deploy stage injection ─────────────────────────────────────────────

  # Every fixture here parks its task at `in_review`, not `in_progress`: task
  # 019ff788 stage 2 narrowed `PlanEngine.@deployable_statuses` to `~w(in_review)`
  # because the review gate now lives INSIDE the plan, so a plan that completes
  # while its task still reads `in_progress` means the review never happened.
  # See "a plan completing at in_progress injects nothing" below for the
  # anti-vacuity pair.
  describe "deploy stage injection" do
    test "injects deploy stage when strategy is not none", %{project: project} do
      strategy = %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deployable task",
          status: "in_review",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — s1 has no validations, passes immediately
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      # Plan should NOT be completed yet
      refute updated_plan.status == "completed"

      # Deploy stage should be injected and running
      stages = updated_plan.stages
      assert length(stages) == 2

      deploy_stage = Enum.find(stages, &(&1.name == "Deploy: PR merge"))
      assert deploy_stage != nil
      assert deploy_stage.position == 2
      assert deploy_stage.status == "running"

      # Deploy stage should have a single pr_merged validation
      validations = Tasks.list_validations(deploy_stage.id)
      assert length(validations) == 1
      kinds = Enum.map(validations, & &1.kind) |> Enum.sort()
      assert kinds == ["pr_merged"]

      # Task should be in deploying status
      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "deploying"
    end

    # The gate set is what changes: a task landing in TWO repositories gets
    # TWO `pr_merged` rows, each naming its own repository. This is also the
    # only test that proves `maybe_put_evaluation_payload/2` reaches the
    # database for a BUILDER-authored validation — it has only ever been
    # exercised for planner-authored `e2e_behavior` payloads.
    test "a two-repo task persists one pr_merged per repo, each carrying its identity",
         %{project: project} do
      strategy = %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
          %{
            "repo_url" => "Startup-Suite/claude-code-suite-channel",
            "ci" => "none"
          }
        ]
      }

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Two-repo deployable task",
          status: "in_review",
          deploy_strategy: strategy,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))
      assert deploy_stage != nil
      assert deploy_stage.status == "running"

      validations = Tasks.list_validations(deploy_stage.id)

      assert length(validations) == 2,
             "a two-repo task must gate on BOTH merges, not on whichever PR lands first"

      assert Enum.map(validations, & &1.kind) == ["pr_merged", "pr_merged"]

      assert Enum.all?(validations, &(&1.status == "pending"))

      assert Enum.all?(validations, &is_map(&1.evaluation_payload)),
             "the builder's evaluation_payload must survive the round-trip through " <>
               "create_validation/1 — nothing else proves it reaches the DB"

      repos = validations |> Enum.map(& &1.evaluation_payload["repo"]) |> Enum.sort()

      assert repos == ["Startup-Suite/claude-code-suite-channel", "Startup-Suite/core"]

      channel_gate =
        Enum.find(
          validations,
          &(&1.evaluation_payload["repo"] == "Startup-Suite/claude-code-suite-channel")
        )

      assert channel_gate.evaluation_payload["ci"] == "none"
      assert channel_gate.evaluation_payload["auto_merge"] == false

      # And the stage must NOT advance on one of the two merging: passing a
      # single gate leaves the stage running, which is the whole point of
      # one row per repository.
      core_gate =
        Enum.find(validations, &(&1.evaluation_payload["repo"] == "Startup-Suite/core"))

      {:ok, _} =
        PlanEngine.evaluate_validation(core_gate.id, %{
          status: "passed",
          evaluated_by: "test"
        })

      assert Platform.Repo.get!(Platform.Tasks.Stage, deploy_stage.id).status == "running",
             "the deploy stage must stay running until EVERY repo's PR has merged"
    end

    # A single-repo task that declares nothing still gets a SCOPED gate,
    # resolved from `project.repo_url`. This is the assertion that fails if
    # `PlanEngine` is still calling `resolve_deploy_strategy/1` — the
    # two-repo test above would too, but this one isolates the swap from
    # the builder change.
    test "a task whose repo comes from the project gets a gate naming that repo" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Repo Project",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Single-repo deployable task",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}},
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))
      assert [validation] = Tasks.list_validations(deploy_stage.id)
      assert validation.kind == "pr_merged"

      assert validation.evaluation_payload["repo"] == "Startup-Suite/core",
             "PlanEngine must resolve the repo set (resolve_deploy_strategy_with_repos/1), " <>
               "not the bare strategy"
    end

    # The counterpart: a project with no usable repo_url resolves to an
    # EMPTY repo set, which leaves `"repos"` absent — and absent means
    # today's single unscoped gate, NOT a stage with zero validations
    # (which `stage_verdict/1` would read as `:all_passed`).
    test "a task with no resolvable repo still gets exactly one unscoped gate",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Repo-less deployable task",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}},
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))

      assert [validation] = Tasks.list_validations(deploy_stage.id),
             "an empty repo set must not build a validation-free deploy stage"

      assert validation.kind == "pr_merged"
      assert validation.evaluation_payload == nil
    end

    test "injects the deploy stage when advance/1 finds every stage already terminal",
         %{project: project} do
      # Task 019f9b34: the all-terminal case now routes through
      # `maybe_inject_deploy_or_complete/2` instead of `complete_plan/1`, so a
      # deployable task gets its deploy stage even when `advance/1` is called on
      # a plan whose stages are already passed (the idempotent `stage_complete`
      # path). Before the fix this branch completed the plan outright.
      strategy = %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "All-terminal deployable task",
          status: "in_review",
          deploy_strategy: strategy,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, running} = PlanEngine.start_stage(s1.id)
      {:ok, _passed} = Tasks.transition_stage(running, "passed")

      # No running and no pending stage → `current_stage/1` returns nil.
      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      refute updated_plan.status == "completed",
             "a plan owing a deploy stage must not complete via advance/1's nil branch"

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))
      assert deploy_stage != nil, "deploy stage must be injected from the all-terminal branch"
      assert deploy_stage.status == "running"

      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "reverts a drifted `completed` plan to `approved` when injecting a deploy stage",
         %{project: project} do
      # Task 019f9b34 change B: `inject_deploy_stage/4` owns the invariant that a
      # plan hosting a running deploy stage is not `completed`. Force the drifted
      # state directly (bypassing the engine) to prove the repair.
      strategy = %{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Drifted plan deployable task",
          status: "in_review",
          deploy_strategy: strategy,
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, running} = PlanEngine.start_stage(s1.id)
      {:ok, _passed} = Tasks.transition_stage(running, "passed")

      # Reproduce the production drift: plan `completed` while work remains.
      plan
      |> Ecto.Changeset.change(%{status: "completed"})
      |> Platform.Repo.update!()

      assert {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "approved",
             "injecting a deploy stage must reopen a drifted `completed` plan (019f9b34)"

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))
      assert deploy_stage != nil
      assert deploy_stage.status == "running"

      assert Platform.Repo.get!(Platform.Tasks.Plan, plan.id).status == "approved"
    end

    test "completes plan normally when strategy is none", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No-deploy task",
          status: "in_review",
          deploy_strategy: %{"type" => "none"}
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
      assert length(updated_plan.stages) == 1
    end

    test "completes plan when deploy stage passes", %{project: project} do
      strategy = %{"type" => "manual"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy then done",
          status: "in_review",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — injects deploy stage
      {:ok, plan_after_inject} = PlanEngine.advance(plan.id)
      refute plan_after_inject.status == "completed"

      deploy_stage = Enum.find(plan_after_inject.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage.status == "running"

      # Pass the deploy stage's manual_approval validation
      [validation] = Tasks.list_validations(deploy_stage.id)
      assert validation.kind == "manual_approval"

      PlanEngine.evaluate_validation(validation.id, %{
        status: "passed",
        evaluated_by: "test"
      })

      # Now the plan should be completed
      final_plan = Tasks.get_plan(plan.id)
      assert final_plan.status == "completed"
    end

    test "uses project default strategy when task has no override", %{project: project} do
      {:ok, project} =
        Tasks.update_project(project, %{
          deploy_config: %{
            "default_strategy" => %{"type" => "docker_deploy", "config" => %{}},
            # Stage-2 deploy-target guard (task 019f42db) — inherit satisfies
            # the guard so this test can still exercise the strategy path.
            "default_deploy_target" => "production"
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Inherit strategy",
          status: "in_review"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Docker deploy"))
      assert deploy_stage != nil
      assert deploy_stage.status == "running"
    end

    test "falls back to manual strategy when no strategy set anywhere", %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Fallback manual",
          status: "in_review",
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage != nil
    end

    test "auto-injects deploy stage even when planner submitted a plan with NO deploy stage",
         %{project: project} do
      # Regression guard for the role-separation change: the planner's
      # responsibility is implementation + validation only. The deploy stage
      # is the deployer's domain and is auto-injected by PlanEngine when all
      # planner-authored stages are complete and the task is in a deployable
      # status. This test verifies that a plan submitted with ONLY
      # implementation stages still ends up running the deploy strategy.
      strategy = %{"type" => "pr_merge", "config" => %{"auto_merge" => true}}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Planner omitted deploy stage",
          status: "in_review",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      # Two implementation-only stages — NO "Deploy: …" stage authored by the planner.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build feature"})
      {:ok, _test} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test feature"})

      # No "Deploy: ..." stage was authored by the planner.
      stage_names_before = plan.id |> Tasks.list_stages() |> Enum.map(& &1.name)
      refute Enum.any?(stage_names_before, &String.starts_with?(&1, "Deploy:"))

      # Run the implementation stages to completion.
      {:ok, _} = PlanEngine.start_stage(build.id)
      {:ok, _} = PlanEngine.advance(plan.id)
      # Test stage was auto-started by maybe_advance_next; advance again to drain it.
      {:ok, plan_after_impl} = PlanEngine.advance(plan.id)

      # The system must have auto-injected the deploy stage from the resolved
      # pr_merge strategy, transitioned the task to "deploying", and started
      # that stage — even though the planner never authored one.
      deploy_stage =
        Enum.find(plan_after_impl.stages, &String.starts_with?(&1.name, "Deploy:"))

      assert deploy_stage != nil,
             "expected PlanEngine to auto-inject a deploy stage when the planner omitted one"

      assert deploy_stage.name == "Deploy: PR merge"
      assert deploy_stage.status == "running"

      validations = Tasks.list_validations(deploy_stage.id)
      assert Enum.map(validations, & &1.kind) == ["pr_merged"]

      updated_task = Tasks.get_task_record(task.id)
      assert updated_task.status == "deploying"
    end

    test "does not double-inject deploy stage on second advance", %{project: project} do
      strategy = %{"type" => "manual"}

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No double inject",
          status: "in_review",
          deploy_strategy: strategy,
          # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
          # transitions without a resolved target.
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # First advance — injects deploy stage
      {:ok, plan_v1} = PlanEngine.advance(plan.id)
      assert length(plan_v1.stages) == 2

      # Second advance — deploy stage is running, has pending validation
      # Should NOT inject another deploy stage
      {:ok, plan_v2} = PlanEngine.advance(plan.id)
      assert length(plan_v2.stages) == 2
    end

    # ── ADR 0041 (T5 stage 3): stack-member deploy-injection guard ───────

    test "stack member does NOT get a per-task deploy stage injected", %{project: project} do
      alias Platform.Tasks.Stacks

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "no-deploy-#{System.unique_integer([:positive])}",
          name: "No Deploy Stack",
          rollup_branch: "stack/no-deploy"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member task",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      # Advance — s1 passes; the plan would normally inject a Deploy
      # stage, but the stack-member guard MUST skip injection and
      # complete the plan instead. T6's stack rollup PR carries the
      # deploy for all members.
      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      assert updated_plan.status == "completed"
      assert length(updated_plan.stages) == 1

      # Task status MUST NOT have been moved to "deploying"
      reloaded = Tasks.get_task_record(task.id)
      refute reloaded.status == "deploying"
    end
  end

  # ── task 019ff788 stage 2: @deployable_statuses is ~w(in_review) ───────

  describe "@deployable_statuses narrowing" do
    @moduletag :deployable_statuses

    # WHY THE FIXTURE IS BUILT DIRECTLY. After stage 1 the normal flow can no
    # longer produce "plan completes while the task reads in_progress" — the
    # router writes `in_review` when the review gate starts. A flow-driven
    # fixture would therefore complete at `in_review` and pass against BOTH
    # implementations, proving nothing. The state is forced here instead:
    # create the task, park it at `in_progress`, complete the plan.
    test "a plan completing at in_progress injects nothing and does not deploy",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Unreviewed task",
          status: "in_progress",
          deploy_strategy: %{"type" => "manual"},
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      assert Tasks.get_task_record(task.id).status == "in_progress",
             "the fixture must reach the engine at in_progress or the test is vacuous"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, updated_plan} = PlanEngine.advance(plan.id)

          assert updated_plan.status == "completed"

          refute Enum.any?(updated_plan.stages, &DeployStageBuilder.deploy_stage_name?(&1.name)),
                 "an unreviewed task must not receive a deploy stage: got " <>
                   inspect(Enum.map(updated_plan.stages, & &1.name))
        end)

      assert Tasks.get_task_record(task.id).status == "in_progress",
             "an unreviewed task must not be moved to deploying"

      # Silent skipping is the failure mode this whole change risks — a task
      # that stops deploying and looks like a clean completion. The warning is
      # the operator's only signal, so it is asserted, not assumed.
      assert log =~ "NOT injecting deploy stage for task #{task.id}"
      assert log =~ "status in_progress is not in @deployable_statuses"
    end

    test "the same plan completing at in_review injects the deploy stage and deploys",
         %{project: project} do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Reviewed task",
          status: "in_review",
          deploy_strategy: %{"type" => "manual"},
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)

      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: Manual"))
      assert deploy_stage != nil, "a reviewed task must still get its deploy stage"
      assert deploy_stage.status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    # The `:stack_ships_atomically` arm of the `cond` in
    # `maybe_inject_deploy_or_complete/2` sits BEFORE the status check, so a
    # stack member is unaffected by the narrowing. Parked at `in_progress` —
    # the status that now disqualifies a solo task — so a regression that
    # reordered the `cond` would change the observable reason for the same
    # outcome. The discriminator is the ABSENCE of the not-deployable warning:
    # the member's plan completes because it ships atomically, not because its
    # status was refused.
    test "a stack member short-circuits before the status check", %{project: project} do
      alias Platform.Tasks.Stacks

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "short-circuit-#{System.unique_integer([:positive])}",
          name: "Short Circuit Stack",
          rollup_branch: "stack/short-circuit-#{System.unique_integer([:positive])}"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Stack member at in_progress",
          status: "in_progress",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
        })

      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      assert Tasks.dispatch_deploy_for_task(task) == {:error, :stack_ships_atomically}

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, updated_plan} = PlanEngine.advance(plan.id)

          assert updated_plan.status == "completed"
          assert length(updated_plan.stages) == 1
        end)

      # Scoped to THIS task's id, not the bare phrase. This module is
      # `async: true` and `capture_log/1` captures the GLOBAL log for the
      # duration of the window, so sibling async tests that legitimately
      # refuse a deploy emit "... is not in @deployable_statuses" straight
      # into this capture. The unscoped refutation was therefore
      # interleaving-sensitive by construction: it passed or failed on which
      # siblings happened to run alongside it, not on the behaviour under
      # test. Surfaced by task 01a03c76 stage 1, whose added chat tests
      # shifted the async mix enough to make it red at seed 0.
      #
      # The scoping does NOT weaken the guard: under the regression it
      # exists to catch, the warning names THIS task, so the refutation
      # still fires. It only stops OTHER tasks' warnings from counting.
      refute log =~ "for task #{task.id} - status",
             "the stack arm must be reached BEFORE the status check — a member " <>
               "that completes for the status reason means the cond was reordered"

      refute Tasks.get_task_record(task.id).status == "deploying"
    end
  end

  # ── Full lifecycle ────────────────────────────────────────────────────

  describe "full plan lifecycle" do
    test "build → test → deploy with validations", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})
      {:ok, _s3} = Tasks.create_stage(%{plan_id: plan.id, position: 3, name: "Deploy"})

      # Stage 1: Build — no validations, just start and advance
      # s2 auto-starts after s1 passes
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, _} = PlanEngine.advance(plan.id)

      # Stage 2: Test — already running (auto-started), add validations
      {:ok, v1} = Tasks.create_validation(%{stage_id: s2.id, kind: "test_pass"})
      {:ok, v2} = Tasks.create_validation(%{stage_id: s2.id, kind: "lint_pass"})

      # Pass both validations — auto-advances stage, s3 auto-starts
      PlanEngine.evaluate_validation(v1.id, %{status: "passed", evidence: %{"tests" => 42}})
      PlanEngine.evaluate_validation(v2.id, %{status: "passed"})

      s2_updated = Platform.Repo.get!(Platform.Tasks.Stage, s2.id)
      assert s2_updated.status == "passed"

      # Stage 3: Deploy — already running (auto-started), no validations
      {:ok, final_plan} = PlanEngine.advance(plan.id)

      assert final_plan.status == "completed"
      assert Enum.all?(final_plan.stages, &(&1.status == "passed"))
    end

    test "retry a failed stage", %{plan: plan} do
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)
      {:ok, v1} = Tasks.create_validation(%{stage_id: s1.id, kind: "test_pass"})

      # Fail validation → stage auto-fails
      PlanEngine.evaluate_validation(v1.id, %{status: "failed"})
      s1_failed = Platform.Repo.get!(Platform.Tasks.Stage, s1.id)
      assert s1_failed.status == "failed"

      # Retry: transition failed → running
      {:ok, s1_retried} = PlanEngine.start_stage(s1.id)
      assert s1_retried.status == "running"
    end
  end

  describe "build_deploy_plan/1" do
    test "returns stage definitions for pr_merge strategy" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Plan Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/deploy-plan",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "config" => %{"auto_merge" => false}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy plan test task"
        })

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.name == "Deploy: PR merge"
      assert stage_def.position == 1

      # Still exactly ONE gate — the project resolves to exactly one
      # repository — but the gate now names it. `pr_merged` means "the PR
      # for THIS repo merged", not "a PR merged somewhere".
      assert [validation] = stage_def.validations
      assert validation.kind == "pr_merged"
      assert validation.evaluation_payload["repo"] == "test/deploy-plan"
      assert validation.evaluation_payload["repo_url"] == "https://github.com/test/deploy-plan"
      assert validation.evaluation_payload["ci"] == "required"
      assert validation.evaluation_payload["auto_merge"] == false
    end

    test "positions deploy stage after existing plan stages" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Pos Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/deploy-pos",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "docker_deploy",
              "config" => %{}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy position test"
        })

      {:ok, plan} =
        Tasks.create_plan(%{
          task_id: task.id,
          status: "approved"
        })

      {:ok, _s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _s2} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.position == 3
      assert stage_def.name == "Deploy: Docker deploy"
      assert %{kind: "ci_passed"} in stage_def.validations
      assert %{kind: "test_pass"} in stage_def.validations
    end

    test "returns :skip for strategy type none" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Deploy Skip Test #{System.unique_integer([:positive])}",
          deploy_config: %{
            "default_strategy" => %{"type" => "none"}
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No deploy test"
        })

      assert {:ok, :skip} = PlanEngine.build_deploy_plan(task.id)
    end

    test "returns error for nonexistent task" do
      assert {:error, :task_not_found} =
               PlanEngine.build_deploy_plan("00000000-0000-0000-0000-000000000000")
    end

    test "auto_merge true still emits a single pr_merged validation" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Auto Merge Test #{System.unique_integer([:positive])}",
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "config" => %{"auto_merge" => true, "merge_method" => "rebase"}
            }
          }
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Auto merge test"
        })

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert stage_def.validations == [%{kind: "pr_merged"}]
    end
  end

  # ── route_e2e_behavior_validations/1 ──────────────────────────────────

  describe "route_e2e_behavior_validations/1" do
    test "lifts an e2e_behavior validation from an implementation stage into a synthesized task-level review stage" do
      e2e_payload = %{
        "setup" => "create a fixture task",
        "actions" => "open the panel",
        "expected" => "panel renders"
      }

      stages = [
        %{
          "name" => "Build feature",
          "description" => "implement the new endpoint",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "lint_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
          ]
        }
      ]

      [build_stage, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      # Implementation stage no longer carries the e2e validation
      assert build_stage["validations"] == [
               %{"kind" => "test_pass"},
               %{"kind" => "lint_pass"}
             ]

      # Synthesized review stage carries it at the next position
      assert review_stage["name"] == "Task-level review"
      assert review_stage["position"] == 2

      assert review_stage["validations"] == [
               %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
             ]
    end

    test "appends e2e_behavior validations to an existing review-named stage instead of synthesizing one" do
      e2e_payload = %{
        "setup" => "x",
        "actions" => "y",
        "expected" => "z"
      }

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
          ]
        },
        %{
          "name" => "Review",
          "position" => 2,
          "validations" => [%{"kind" => "manual_approval"}]
        }
      ]

      [build_stage, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      assert build_stage["validations"] == [%{"kind" => "test_pass"}]

      assert review_stage["validations"] == [
               %{"kind" => "manual_approval"},
               %{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}
             ]
    end

    test "leaves stages untouched when no e2e_behavior validation is present" do
      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      assert PlanEngine.route_e2e_behavior_validations(stages) == stages
    end

    test "ignores Deploy: stages when looking for an existing review stage to attach to" do
      e2e_payload = %{
        "setup" => "x",
        "actions" => "y",
        "expected" => "z"
      }

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [%{"kind" => "e2e_behavior", "evaluation_payload" => e2e_payload}]
        },
        %{
          "name" => "Deploy: PR merge — review",
          "position" => 2,
          "validations" => [%{"kind" => "pr_merged"}]
        }
      ]

      [_build, deploy, review_stage] = PlanEngine.route_e2e_behavior_validations(stages)

      assert deploy["validations"] == [%{"kind" => "pr_merged"}]
      assert review_stage["name"] == "Task-level review"
    end

    test "preserves multiple e2e_behavior validations on the synthetic review stage" do
      # v2: the planner authors an adversarial test plan with 2-5 e2e_behavior
      # validations covering happy path + edges. They MUST all be lifted onto a
      # single synthetic Task-level review stage, in author order.
      payload_a = %{"setup" => "s-a", "actions" => "a-a", "expected" => "e-a"}
      payload_b = %{"setup" => "s-b", "actions" => "a-b", "expected" => "e-b"}
      payload_c = %{"setup" => "s-c", "actions" => "a-c", "expected" => "e-c"}

      stages = [
        %{
          "name" => "Build",
          "position" => 1,
          "validations" => [
            %{"kind" => "test_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_a},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_b}
          ]
        },
        %{
          "name" => "Wire UI",
          "position" => 2,
          "validations" => [
            %{"kind" => "lint_pass"},
            %{"kind" => "e2e_behavior", "evaluation_payload" => payload_c}
          ]
        }
      ]

      [build_stage, ui_stage, review_stage] =
        PlanEngine.route_e2e_behavior_validations(stages)

      # Implementation stages keep only their non-e2e validations.
      assert build_stage["validations"] == [%{"kind" => "test_pass"}]
      assert ui_stage["validations"] == [%{"kind" => "lint_pass"}]

      # Synthesized review stage holds all three e2e validations, in author order.
      assert review_stage["name"] == "Task-level review"
      assert review_stage["position"] == 3

      assert review_stage["validations"] == [
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_a},
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_b},
               %{"kind" => "e2e_behavior", "evaluation_payload" => payload_c}
             ]
    end
  end

  describe "e2e_host_name_match/1" do
    test "names the trigger when it hides inside a snake_case identifier" do
      # The shipped incident: an implementation stage whose name merely
      # MENTIONS an identifier containing "review" was silently adopted as
      # the e2e host. A fixture like "Review the code" cannot tell a
      # substring check from a word-boundary check; this one can.
      assert PlanEngine.e2e_host_name_match(
               "Add per-kind resolution predicates for chat_mention, task_plan_review and meeting_starting"
             ) == "review"
    end

    test "returns nil for a stage name carrying no trigger" do
      assert PlanEngine.e2e_host_name_match("Wire the compose input") == nil
    end

    test "the deploy: prefix exemption survives a trigger in the name" do
      assert PlanEngine.e2e_host_name_match("Deploy: PR merge — review") == nil
    end

    test "matching is case-insensitive" do
      assert PlanEngine.e2e_host_name_match("Add cross-VALIDATION guard") == "validation"
    end

    test "\"evaluation\" is NOT a trigger" do
      # Documented deliberately: the ticket for this work named three
      # triggers, but the engine has only two. "evaluation" contains
      # neither "review" nor "validation".
      assert PlanEngine.e2e_host_name_match("Score the evaluation harness") == nil
    end

    test "accepts a planner-authored stage map, reading its name" do
      assert PlanEngine.e2e_host_name_match(%{"name" => "Final validation"}) == "validation"
      assert PlanEngine.e2e_host_name_match(%{"name" => "Wire the compose input"}) == nil
    end
  end

  describe "detect_e2e_host_collision/1" do
    @dirty_name "Add per-kind resolution predicates for chat_mention, task_plan_review and meeting_starting"

    defp e2e_case(id), do: %{"kind" => "e2e_behavior", "criteria" => "case #{id}"}

    test "CLEAN: no stage name carries a trigger, e2e cases present" do
      stages = [
        %{
          "name" => "Add the resolver",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        },
        %{
          "name" => "Wire the router",
          "position" => 2,
          "validations" => [e2e_case("a"), e2e_case("b")]
        },
        %{"name" => "Surface the panel", "position" => 3, "validations" => []}
      ]

      assert PlanEngine.detect_e2e_host_collision(stages) == :ok
    end

    test "DIRTY: a trigger hiding inside a snake_case identifier is refused" do
      stages = [
        %{"name" => @dirty_name, "position" => 1, "validations" => [%{"kind" => "test_pass"}]},
        %{"name" => "Wire the router", "position" => 2, "validations" => [e2e_case("a")]}
      ]

      assert {:error, error} = PlanEngine.detect_e2e_host_collision(stages)
      assert error.matched_substring == "review"
      assert error.stage_position == 1
      # Verbatim: the author has to recognise the stage they wrote.
      assert error.stage_name == @dirty_name
      assert error.e2e_case_count == 1
    end

    test "NO-E2E CONTROL: same dirty name, zero e2e cases → :ok" do
      stages = [
        %{"name" => @dirty_name, "position" => 1, "validations" => [%{"kind" => "test_pass"}]},
        %{"name" => "Wire the router", "position" => 2, "validations" => []}
      ]

      assert PlanEngine.detect_e2e_host_collision(stages) == :ok
    end

    test "OPT-IN CONTROL: an explicit e2e_host stage is accepted and hosts the cases" do
      stages = [
        %{
          "name" => @dirty_name,
          "position" => 1,
          "e2e_host" => true,
          "validations" => [%{"kind" => "test_pass"}]
        },
        %{"name" => "Wire the router", "position" => 2, "validations" => [e2e_case("a")]},
        %{"name" => "Surface the panel", "position" => 3, "validations" => [e2e_case("b")]}
      ]

      assert PlanEngine.detect_e2e_host_collision(stages) == :ok

      routed = PlanEngine.route_e2e_behavior_validations(stages)
      host = Enum.find(routed, &(&1["e2e_host"] == true))

      assert Enum.count(host["validations"], &(&1["kind"] == "e2e_behavior")) == 2

      assert Enum.all?(routed -- [host], fn stage ->
               Enum.all?(stage["validations"], &(&1["kind"] != "e2e_behavior"))
             end)
    end

    test "the explicit e2e_host wins over a DIFFERENT name-matching stage" do
      # Precedence is only observable when the opt-in stage and the
      # name-matching stage are different stages: with both on stage 1 the
      # two rules pick the same index and a name-only router passes.
      stages = [
        %{"name" => @dirty_name, "position" => 1, "validations" => [%{"kind" => "test_pass"}]},
        %{
          "name" => "Wire the router",
          "position" => 2,
          "e2e_host" => true,
          "validations" => [e2e_case("a")]
        }
      ]

      assert PlanEngine.detect_e2e_host_collision(stages) == :ok

      assert [named, host] = PlanEngine.route_e2e_behavior_validations(stages)
      assert Enum.all?(named["validations"], &(&1["kind"] != "e2e_behavior"))
      assert Enum.count(host["validations"], &(&1["kind"] == "e2e_behavior")) == 1
    end
  end

  describe "detect_unnamed_manual_gate/1" do
    defp named_gate(surface),
      do: %{
        "kind" => "manual_approval",
        "evaluation_payload" => %{"ui_surface" => surface}
      }

    test "NAMED: a manual_approval carrying a non-blank ui_surface → :ok" do
      stages = [
        %{
          "name" => "Add the resolver",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        },
        %{
          "name" => "Surface the panel",
          "position" => 2,
          "validations" => [named_gate("the tasks list mobile card"), %{"kind" => "test_pass"}]
        }
      ]

      assert PlanEngine.detect_unnamed_manual_gate(stages) == :ok
    end

    test "UNNAMED: a manual_approval with no ui_surface is refused, naming that stage" do
      stages = [
        %{
          "name" => "Add the resolver",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        },
        %{
          "name" => "Surface the panel",
          "position" => 2,
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "manual_approval"}]
        }
      ]

      assert {:error, info} = PlanEngine.detect_unnamed_manual_gate(stages)
      assert info.stage_name == "Surface the panel"
      assert info.stage_position == 2
    end

    test "DIRECTION CONTROL: a plan with no manual_approval at all → :ok" do
      # The common case, and the one that already worked. An implementation
      # that refuses everything passes the UNNAMED test and must fail here.
      stages = [
        %{
          "name" => "Add the resolver",
          "position" => 1,
          "validations" => [%{"kind" => "test_pass"}]
        },
        %{
          "name" => "Wire the router",
          "position" => 2,
          "validations" => [%{"kind" => "lint_pass"}, %{"kind" => "test_pass"}]
        },
        %{"name" => "Surface the panel", "position" => 3, "validations" => []}
      ]

      assert PlanEngine.detect_unnamed_manual_gate(stages) == :ok
    end

    test "BLANK: a whitespace-only ui_surface is unnamed" do
      stages = [
        %{"name" => "Surface the panel", "position" => 1, "validations" => [named_gate("   ")]}
      ]

      assert {:error, info} = PlanEngine.detect_unnamed_manual_gate(stages)
      assert info.stage_name == "Surface the panel"
      assert info.stage_position == 1
    end

    test "nil and non-binary ui_surface are unnamed" do
      for bad <- [nil, 42, %{"screen" => "panel"}] do
        stages = [
          %{
            "name" => "Surface the panel",
            "position" => 1,
            "validations" => [named_gate(bad)]
          }
        ]

        assert {:error, _} = PlanEngine.detect_unnamed_manual_gate(stages)
      end
    end

    test "ATOM KEYS: atom-keyed input behaves identically to string-keyed" do
      named = [
        %{
          name: "Surface the panel",
          position: 1,
          validations: [
            %{kind: "manual_approval", evaluation_payload: %{ui_surface: "the panel"}}
          ]
        }
      ]

      assert PlanEngine.detect_unnamed_manual_gate(named) == :ok

      unnamed = [
        %{
          name: "Surface the panel",
          position: 1,
          validations: [%{kind: "manual_approval", evaluation_payload: %{}}]
        }
      ]

      assert {:error, info} = PlanEngine.detect_unnamed_manual_gate(unnamed)
      assert info.stage_name == "Surface the panel"
      assert info.stage_position == 1
    end

    test "reports only the FIRST offending stage" do
      stages = [
        %{
          "name" => "First offender",
          "position" => 1,
          "validations" => [%{"kind" => "manual_approval"}]
        },
        %{
          "name" => "Second offender",
          "position" => 2,
          "validations" => [%{"kind" => "manual_approval"}]
        }
      ]

      assert {:error, info} = PlanEngine.detect_unnamed_manual_gate(stages)
      assert info.stage_name == "First offender"
    end

    test "a non-list argument returns :ok" do
      assert PlanEngine.detect_unnamed_manual_gate(nil) == :ok
      assert PlanEngine.detect_unnamed_manual_gate(%{"name" => "not a list"}) == :ok
    end
  end

  # ── ui_touching?/1 + check_manual_approval_heuristic/1 ──────────────

  describe "ui_touching?/1" do
    test "returns true when description contains UI-touching tokens" do
      assert PlanEngine.ui_touching?("update the .heex template for the panel")
      assert PlanEngine.ui_touching?("modify assets/js/hooks/compose_input.js")
      assert PlanEngine.ui_touching?("change tasks_live.ex render path")
      assert PlanEngine.ui_touching?("add a new section in app.css")
    end

    test "returns false for descriptions with no UI tokens" do
      refute PlanEngine.ui_touching?("update database migration")
      refute PlanEngine.ui_touching?("refactor business logic in plan_engine.ex")
      refute PlanEngine.ui_touching?(nil)
      refute PlanEngine.ui_touching?("")
    end
  end

  describe "check_manual_approval_heuristic/1" do
    import ExUnit.CaptureLog

    test "warns when a UI-touching stage lacks manual_approval" do
      stages = [
        %{
          "name" => "Render new panel",
          "description" => "edit assets/js/hooks/compose_input.js to add draft persistence",
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      assert log =~ "likely missed UI manual_approval"
      assert log =~ "Render new panel"
    end

    test "warns when a non-UI stage carries manual_approval (likely overscoped)" do
      stages = [
        %{
          "name" => "Database migration",
          "description" => "add a jsonb column to validations table",
          "validations" => [%{"kind" => "manual_approval"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      assert log =~ "likely overscoped manual_approval"
      assert log =~ "Database migration"
    end

    test "is silent when planner-supplied manual_approval matches a UI-touching stage" do
      stages = [
        %{
          "name" => "Render new panel",
          "description" => "edit chat_live.ex to render badges",
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "manual_approval"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      refute log =~ "likely missed UI manual_approval"
      refute log =~ "likely overscoped manual_approval"
    end

    test "is silent when planner correctly omits manual_approval from a non-UI stage" do
      stages = [
        %{
          "name" => "Background worker",
          "description" => "implement Oban worker for the daily digest job",
          "validations" => [%{"kind" => "test_pass"}, %{"kind" => "lint_pass"}]
        }
      ]

      log = capture_log(fn -> PlanEngine.check_manual_approval_heuristic(stages) end)
      refute log =~ "likely missed UI manual_approval"
      refute log =~ "likely overscoped manual_approval"
    end

    test "returns input untouched (planner authority wins)" do
      stages = [
        %{
          "name" => "X",
          "description" => "edit chat_live.ex without approval",
          "validations" => [%{"kind" => "test_pass"}]
        }
      ]

      assert PlanEngine.check_manual_approval_heuristic(stages) == stages
    end
  end

  describe "check_zero_validation_stages/1" do
    import ExUnit.CaptureLog

    test "warns for a stage carrying an empty validations list" do
      stages = [
        %{
          "name" => "Wire the supervisor",
          "description" => "add the child spec",
          "validations" => []
        }
      ]

      log = capture_log(fn -> PlanEngine.check_zero_validation_stages(stages) end)
      assert log =~ "zero-validation stage"
      assert log =~ "Wire the supervisor"
    end

    test "warns once per zero-validation stage and names each one" do
      stages = [
        %{"name" => "Empty one", "description" => "a", "validations" => []},
        %{"name" => "Gated", "description" => "b", "validations" => [%{"kind" => "test_pass"}]},
        %{"name" => "Empty two", "description" => "c", "validations" => []}
      ]

      log = capture_log(fn -> PlanEngine.check_zero_validation_stages(stages) end)

      assert log =~ "Empty one"
      assert log =~ "Empty two"
      refute log =~ "Gated"

      warnings =
        log |> String.split("\n") |> Enum.count(&String.contains?(&1, "zero-validation stage"))

      assert warnings == 2
    end

    test "warns for a stage with no validations key at all" do
      stages = [%{"name" => "No key", "description" => "d"}]

      log = capture_log(fn -> PlanEngine.check_zero_validation_stages(stages) end)
      assert log =~ "zero-validation stage"
      assert log =~ "No key"
    end

    test "handles atom-keyed stage input" do
      stages = [%{name: "Atom stage", description: "e", validations: []}]

      log = capture_log(fn -> PlanEngine.check_zero_validation_stages(stages) end)
      assert log =~ "zero-validation stage"
      assert log =~ "Atom stage"
    end

    test "is silent when every stage carries at least one validation" do
      stages = [
        %{"name" => "A", "description" => "f", "validations" => [%{"kind" => "test_pass"}]},
        %{"name" => "B", "description" => "g", "validations" => [%{"kind" => "lint_pass"}]}
      ]

      log = capture_log(fn -> PlanEngine.check_zero_validation_stages(stages) end)
      refute log =~ "zero-validation stage"
    end

    test "returns input untouched (planner authority wins)" do
      # `expected` is an independently constructed literal, NOT anything derived
      # from the function under test — so this assertion can actually fail.
      expected = [
        %{"name" => "Empty", "description" => "h", "validations" => []},
        %{"name" => "Gated", "description" => "i", "validations" => [%{"kind" => "test_pass"}]}
      ]

      stages = [
        %{"name" => "Empty", "description" => "h", "validations" => []},
        %{"name" => "Gated", "description" => "i", "validations" => [%{"kind" => "test_pass"}]}
      ]

      result = capture_log(fn -> assert PlanEngine.check_zero_validation_stages(stages) end)
      assert result =~ "zero-validation stage"
      assert PlanEngine.check_zero_validation_stages(stages) == expected
    end

    test "passes non-list input through unchanged" do
      assert PlanEngine.check_zero_validation_stages(:not_a_list) == :not_a_list
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: agent-supplied stage_id / validation_id" do
    @slug_16 "higginshigginsxx"

    test "advance-by-stage paths report :not_found for a malformed stage id" do
      assert {:error, :not_found} = PlanEngine.start_stage(@slug_16)
      assert {:error, :not_found} = PlanEngine.start_stage("higgins")
    end

    test "the bang validation lookups raise NoResultsError, not CastError" do
      # `Repo.get!/2` documents `Ecto.NoResultsError` on a miss. Before the
      # guard, a malformed validation_id raised a DIFFERENT exception class —
      # so one lookup raised two ways depending on how the agent typo'd it.
      assert_raise Ecto.NoResultsError, fn -> PlanEngine.reopen_manual_approval(@slug_16) end

      assert_raise Ecto.NoResultsError, fn ->
        PlanEngine.evaluate_validation(@slug_16, %{status: "passed"})
      end
    end
  end

  # ── Regression 019fa63a: the DESCRIPTION of the injected deploy stage ────
  #
  # `PlanEngine` resolves through `Tasks.resolve_deploy_strategy_with_repos/1`,
  # which synthesizes a one-entry `"repos"` list from `project.repo_url` for
  # every project whose URL normalizes. `DeployStageBuilder.build_stage/3`
  # then takes its `repos when is_list(repos) and repos != []` branch for
  # ORDINARY tasks — the ones that declare nothing — and the single-repo
  # wording stopped rendering anywhere outside a repo-less project.
  #
  # Why this needs a PlanEngine-level test and could not have been caught
  # below it: `deploy_stage_builder_test.exs` pins the single-repo text as
  # byte-identical to pre-multi-repo output, and that pin STAYED GREEN — the
  # function it pins never changed, it merely stopped being called. A test
  # one layer down from the swap cannot observe the swap.
  #
  # Why counts are not enough: the injection tests above assert gate COUNT
  # and `evaluation_payload`, both of which were correct throughout. The
  # count was 1, the payload named the right repo, and the prose still told
  # the deployer that "one merged PR out of 1 is a partial deploy". The
  # description is the assertion that was missing, so it is the assertion
  # these tests make.
  describe "deploy stage injection — single-repo wording (regression 019fa63a)" do
    test "a task with NO repos key renders today's single-repo wording" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Undeclared Repo Project #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      # The shape EVERY pre-existing production task is in: a bare
      # `pr_merge` strategy with no `"repos"` key anywhere.
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ordinary single-repo task",
          status: "in_review",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{}},
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)
      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))

      # The gate side was never wrong — assert it so a fix that restores the
      # prose by collapsing back to an unscoped gate does not pass here.
      assert [validation] = Tasks.list_validations(deploy_stage.id)
      assert validation.kind == "pr_merged"
      assert validation.evaluation_payload["repo"] == "Startup-Suite/core"

      assert_single_repo_wording(deploy_stage.description)

      # NOT byte-identical to the builder's raw no-repos-key output any more
      # (task 01a0e5f6 stage 2). It used to be: the single-repo path
      # DISCARDED the resolved entry's `ci` and fell back to the same
      # config-only renderer the truly-repo-less catch-all uses, so the two
      # calls were coincidentally identical for every ci state, including
      # ones where that shared text was a false claim (Stark Industries/
      # orion's `ci: "unenforced"`). This task's PlanEngine resolution DOES
      # carry a repo identity (`Tasks.resolve_deploy_strategy_with_repos/1`
      # synthesizes one from `project.repo_url`, `ci: "required"` here), and
      # the injected description now makes the claim that identity is
      # entitled to.
      assert deploy_stage.description =~
               "CI is required and enforced by branch protection"
    end

    # `inject_deploy_stage/1` (exercised above via `advance/1`) and
    # `build_deploy_plan/1` resolve the strategy independently. Both were
    # swapped onto `_with_repos`, so both regressed; pin both.
    test "build_deploy_plan/1 renders the same single-repo wording" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Undeclared Plan Project #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core",
          deploy_config: %{
            "default_strategy" => %{"type" => "pr_merge", "config" => %{}}
          }
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Build-deploy-plan single repo"})

      assert {:ok, [stage_def]} = PlanEngine.build_deploy_plan(task.id)
      assert [validation] = stage_def.validations
      assert validation.evaluation_payload["repo"] == "Startup-Suite/core"

      assert_single_repo_wording(stage_def.description)
    end

    # The override case: the repo set is DECLARED, but declares exactly one
    # repository. One repo is one repo however it was arrived at, so it reads
    # the same as an undeclared single-repo task. An ordinary entry
    # (resolvable slug, `ci: "required"`) is used deliberately — that is the
    # shape the undeclared path always produces, so this test pins only the
    # uncontested part of the single-entry case.
    test "an explicit single-entry repos list renders the same single-repo wording" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Declared One Repo Project #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Declared single-repo task",
          status: "in_review",
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{},
            "repos" => [
              %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"}
            ]
          },
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)
      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))

      assert [validation] = Tasks.list_validations(deploy_stage.id)
      assert validation.evaluation_payload["repo"] == "Startup-Suite/core"

      assert_single_repo_wording(deploy_stage.description)
    end

    # The guard on the guard. Without this, a fix that routed EVERY repo set
    # through the single-repo renderer would collapse the multi-repo path
    # entirely and the suite would stay green — the failure mode that put the
    # single-repo wording out of reach in the first place, run in reverse.
    test "two repos still enumerate the repository set" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Two Repo Project #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Two-repo task",
          status: "in_review",
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{},
            "repos" => [
              %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
              %{"repo_url" => "Startup-Suite/claude-code-suite-channel", "ci" => "none"}
            ]
          },
          deploy_target: "production"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
      {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(s1.id)

      {:ok, updated_plan} = PlanEngine.advance(plan.id)
      deploy_stage = Enum.find(updated_plan.stages, &(&1.name == "Deploy: PR merge"))

      assert length(Tasks.list_validations(deploy_stage.id)) == 2

      description = deploy_stage.description

      assert description =~ "This deploy covers 2 repositories:",
             "a genuinely multi-repo deploy must still enumerate its repository set"

      assert description =~ "Startup-Suite/core"
      assert description =~ "Startup-Suite/claude-code-suite-channel"

      assert description =~ "one merged PR out of 2 is a partial deploy",
             "the partial-deploy warning is the point of the multi-repo wording and " <>
               "must survive the single-repo carve-out"

      # The per-repo sentences, which only the enumerating renderer emits.
      assert description =~ "has no required status checks",
             "the ci: \"none\" repo must still get its hand-merge sentence"

      refute description =~ "Stage completes when the PR is merged",
             "the singular single-repo phrasing must not leak into a two-repo deploy"
    end
  end

  # ── stages_query/0 — the ordering every `{:ok, plan}` this module returns
  # carries (ticket 01a089e6) ──────────────────────────────────────────────

  describe "advance/2 stage ordering" do
    # `stages_query/0` is a QUERY-LEVEL preload, and a query-level preload
    # REPLACES `Plan.has_many(:stages)`'s `preload_order` rather than merging
    # with it — so the association's ordering rules do not reach it and the
    # tiebreak has to be repeated. Twelve call sites in `PlanEngine` hand the
    # result straight back to a caller as `{:ok, plan}`.
    #
    # `asc: :position` alone is not a total order because `position` is not
    # unique: `stages` carries one index and it is `index(:stages, [:plan_id])`
    # — plan_id alone, plain — `Stage.changeset/2` validates `position` as
    # required and nothing more, and "Stages must have unique positions" lives
    # only in prose in `plan_create`'s tool description.
    #
    # THE FIXTURE INSERTS THE TIED ROWS ITSELF, WITH IDS IT CHOSE, HIGHEST
    # FIRST, because two conditions have to hold at once or this test passes
    # with or without the tiebreak:
    #
    #   1. Two stages must SHARE a `position` — otherwise the tiebreak is
    #      never consulted.
    #   2. Their PHYSICAL order must disagree with their `id` order —
    #      otherwise a bare `ORDER BY position` returns id order by accident.
    #      `Tasks.create_stage/1` cannot produce (2): it mints each id as it
    #      inserts, so id order and heap order always agree.
    test "a position tie is broken by id, so the returned plan is totally ordered", %{plan: plan} do
      {:ok, build} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
      {:ok, _} = PlanEngine.start_stage(build.id)

      # Keeps `advance/2` on its no-op branch: a running stage whose
      # validations are still pending returns the preloaded plan and changes
      # nothing, so this test reads the ordering without also asserting a
      # transition.
      {:ok, _} = Tasks.create_validation(%{stage_id: build.id, kind: "test_pass"})

      # Sorted rather than assumed-ordered — the claim is about id order.
      [low, high] =
        Enum.sort([Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()])

      insert_tied = fn id, name ->
        %Platform.Tasks.Stage{}
        |> Platform.Tasks.Stage.changeset(%{plan_id: plan.id, position: 2, name: name})
        |> Ecto.Changeset.put_change(:id, id)
        |> Platform.Repo.insert!()
      end

      # HIGHEST ID FIRST: heap order becomes the reverse of id order.
      insert_tied.(high, "Later")
      insert_tied.(low, "Earlier")

      # The tie is asserted, not assumed — and doubles as the standing proof
      # that the schema accepts two stages at one position.
      assert 2 ==
               Platform.Repo.aggregate(
                 from(s in Platform.Tasks.Stage,
                   where: s.plan_id == ^plan.id and s.position == 2
                 ),
                 :count
               )

      assert {:ok, advanced} = PlanEngine.advance(plan.id)

      # Read three times, asserting the ID ORDER each time rather than that
      # the reads agree with each other: one lucky scan satisfies "they agree".
      for _ <- 1..3 do
        assert {:ok, again} = PlanEngine.advance(plan.id)
        assert Enum.map(again.stages, & &1.id) == [build.id, low, high]
      end

      assert Enum.map(advanced.stages, & &1.id) == [build.id, low, high]
      assert Enum.map(advanced.stages, & &1.name) == ["Build", "Earlier", "Later"]
      assert Enum.map(advanced.stages, & &1.position) == [1, 2, 2]
    end
  end

  # ── current_stage/1's selection is a WRITE-side decision (ticket 01a089e6,
  # site 1) ───────────────────────────────────────────────────────────────

  describe "advance/2 stage selection under a position tie" do
    # #967 and #969 fixed six READ paths: which order a preload or a query
    # hands a caller. `current_stage/1` is different — it decides which
    # stage `advance/2` actually DISPATCHES and ADVANCES. With two `pending`
    # or `running` stages sharing a position, `Enum.find/2` over an
    # untiebroken `ordered_stages/1` list returns whichever row the scan
    # handed it first, and THAT row is the one the engine acts on.
    #
    # THE FIXTURE, same two conditions as every other site on this ticket:
    #
    #   1. Two "running" stages share a `position` — with distinct
    #      positions the tiebreak is never consulted.
    #   2. Their PHYSICAL (heap) order must disagree with their `id` order
    #      — `Tasks.create_stage/1` cannot build this, since it mints each
    #      id as it inserts and heap order and id order always agree there.
    #      The rows go in directly, with pre-chosen ids, HIGHEST ID FIRST,
    #      so heap order is the exact reverse of id order.
    #
    # HOW THE CHOICE IS MADE OBSERVABLE WITHOUT SPENDING THE TIE ON A
    # TRANSITION. Both stages are "running", so a real `running -> failed`
    # transition is legal for either one — but the test never lets the
    # correctly-picked stage (the lower id) transition at all. It calls
    # `advance/2` with `stage_id: high` — the id it expects NOT to be
    # current. `advance/2`'s own contract is "no-op unless the asserted
    # stage IS the current stage" (see its `@doc`), so:
    #
    #   * `current_stage/1` correctly resolves to `low` → `low != high` →
    #     the mismatch guard fires → no-op, and `high`'s (poisoned) validation
    #     is never even read.
    #   * `current_stage/1` wrongly resolves to `high` (the bug this ticket
    #     fixes) → `high == high` → the mismatch guard does NOT fire →
    #     `high`'s verdict is computed for real. `high` carries a `failed`
    #     validation, so that is a genuine, legal `running -> failed`
    #     transition — a visible mutation a correct engine never makes.
    #
    # So a correct engine leaves both stages exactly as inserted, every
    # single call; calling it three times in a row is "a repeated call
    # selects the same row" — nothing about the fixture changes between
    # calls, so an unstable choice would eventually flip `high` to
    # `"failed"` on some later iteration if it were ever going to.
    test "current_stage/1 never treats the higher-id row as current, across repeated calls",
         %{plan: plan} do
      [low, high] =
        Enum.sort([Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()])

      insert_running = fn id, name ->
        %Platform.Tasks.Stage{}
        |> Platform.Tasks.Stage.changeset(%{
          plan_id: plan.id,
          position: 1,
          name: name,
          status: "running"
        })
        |> Ecto.Changeset.put_change(:id, id)
        |> Platform.Repo.insert!()
      end

      # HIGHEST ID FIRST: heap order becomes the exact reverse of id order.
      insert_running.(high, "Later")
      insert_running.(low, "Earlier")

      # The poison: only read if `high` is (wrongly) treated as current.
      {:ok, _poison} =
        Tasks.create_validation(%{stage_id: high, kind: "test_pass", status: "failed"})

      # The tie is asserted, not assumed.
      assert 2 ==
               Platform.Repo.aggregate(
                 from(s in Platform.Tasks.Stage,
                   where: s.plan_id == ^plan.id and s.position == 1
                 ),
                 :count
               )

      for _ <- 1..3 do
        assert {:ok, result} = PlanEngine.advance(plan.id, stage_id: high)

        high_stage = Enum.find(result.stages, &(&1.id == high))
        low_stage = Enum.find(result.stages, &(&1.id == low))

        # `high` was never treated as current, so its poisoned validation
        # was never read and it never transitioned.
        assert high_stage.status == "running"
        # `low` was current every time and was never the asserted id, so
        # it was never touched either — this is the plan-scoped no-op
        # branch, not the verdict branch.
        assert low_stage.status == "running"
      end
    end
  end

  # ── Test helpers ────────────────────────────────────────────────────────

  # Two sentences that appear ONLY in the single-repo rendering, and four
  # that appear ONLY in the enumerating one. The positive markers are exact
  # to the terminating period: the enumerating renderer opens with the same
  # words but continues "…default branch of every repository this task lands
  # in", so a prefix match would not discriminate between them.
  defp assert_single_repo_wording(description) do
    assert description =~ "Push the task branch and open a PR against the default branch.",
           "expected today's single-repo wording, got:\n\n#{description}"

    assert description =~ "Stage completes when the PR is merged",
           "expected today's single-repo wording, got:\n\n#{description}"

    for leak <- [
          "This deploy covers",
          "repository this task lands in",
          "is a partial deploy",
          "One pr_merged validation is tracked per repository"
        ] do
      refute description =~ leak,
             "single-repo deploy stage enumerated its repository set (#{inspect(leak)}) — " <>
               "the plan forbids repo enumeration and any behavioural change for the " <>
               "99% case. Got:\n\n#{description}"
    end
  end
end
