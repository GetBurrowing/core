defmodule Platform.Tasks.PlanEngineStackMemberEntryTest do
  @moduledoc """
  Task 01a05393 stage 2 — `PlanEngine.maybe_advance_next/3` calls
  `MemberReviewEntry.maybe_enter_in_review/2` on every stage settlement, so a
  stack member reaches `in_review` (and the rollup merge fires) without a
  gate stage ever running.

  Lives in its own file rather than `plan_engine_test.exs` because that module
  is `async: true` and these tests install a fake `GitRunner` through
  `Application.put_env/3` to observe what the deployer was asked to do — the
  same reason `plan_engine_stack_member_merge_test.exs` is `async: false`.

  Every fixture sets `status` explicitly: `Tasks.create_task/1` defaults to
  `backlog`, which sits OUTSIDE the seam's `in_progress` precondition, so a
  fixture left on the default would satisfy the "does not advance" assertions
  for the wrong reason.
  """

  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{MemberReviewEntry, PlanCompletion, PlanEngine, Stacks}

  # Minimal `GitRunner` fake: records `merge_member_into_rollup/1` calls and
  # answers every callback with a benign default. Kept local so this file has
  # no link-time dependency on a sibling test module.
  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []),
      do: Agent.start_link(fn -> %{merge_calls: []} end, name: __MODULE__)

    def stop, do: Agent.stop(__MODULE__)

    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :created, base_sha: "deadbee"}}

    @impl true
    def merge_member_into_rollup(args) do
      Agent.update(__MODULE__, fn state -> %{state | merge_calls: [args | state.merge_calls]} end)
      {:ok, %{status: :merged, merge_sha: "f00dbabe"}}
    end

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 99, url: "https://github.com/test/repo/pull/99"}}

    @impl true
    def diff_stat(_args), do: {:ok, " 3 files changed"}

    @impl true
    def revert_member_merge(_args), do: {:ok, %{status: :reverted, revert_sha: "rev0000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}

    @impl true
    def list_added_migrations(_args), do: {:ok, []}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    Application.put_env(:platform, :stack_deployer, git_runner: FakeRunner, async: false)
    {:ok, _} = FakeRunner.start_link()

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        FakeRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    # The merge path needs a project `repo_url`; without one the deployer
    # answers `{:error, :no_repo_url}` before the runner is reached.
    {:ok, project} =
      Tasks.create_project(%{
        name: "Member Entry Project #{uniq()}",
        repo_url: "https://github.com/test/member-entry-#{uniq()}"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: "member-entry-#{uniq()}",
        name: "Member Entry Stack",
        rollup_branch: "stack/member-entry-#{uniq()}"
      })

    %{project: project, stack: stack}
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  # `stack` may be nil for the solo-task case.
  defp task_fixture(project, stack, status, title, extra \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            title: title,
            status: status,
            deploy_strategy: %{"type" => "pr_merge", "config" => %{}}
          },
          extra
        )
      )

    if stack do
      {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})
      task
    else
      task
    end
  end

  # Builds an approved plan whose stages carry the given validation kinds.
  # Returns `{plan, [%{stage, validations}]}` in position order. Nothing is
  # started here — the tests drive the engine themselves so every transition
  # is one the engine produced.
  defp plan_fixture(task, specs) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    stages =
      specs
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, kinds}, position} ->
        {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})

        validations =
          Enum.map(kinds, fn kind ->
            {:ok, v} = Tasks.create_validation(validation_attrs(stage, kind))
            v
          end)

        %{stage: stage, validations: validations}
      end)

    {plan, stages}
  end

  # `e2e_behavior` validations are rejected without an `evaluation_payload`.
  defp validation_attrs(stage, "e2e_behavior") do
    %{
      stage_id: stage.id,
      kind: "e2e_behavior",
      evaluation_payload: %{
        "setup" => "a stack member fixture",
        "actions" => "settle the non-gate stages",
        "expected" => "the member reaches in_review"
      }
    }
  end

  defp validation_attrs(stage, kind), do: %{stage_id: stage.id, kind: kind}

  # The executor path: `validation_pass` -> `PlanEngine.evaluate_validation/2`.
  # Passing the last pending validation on a running stage settles the stage
  # and runs `maybe_advance_next/3`.
  defp pass_all(validations) do
    Enum.each(validations, fn v ->
      {:ok, _} = PlanEngine.evaluate_validation(v.id, %{status: "passed", evidence: %{}})
    end)
  end

  defp status_of(task), do: Tasks.get_task_record(task.id).status

  defp stage_statuses(plan), do: plan.id |> Tasks.list_stages() |> Enum.map(& &1.status)

  defp deploy_stage?(stage), do: Platform.Tasks.DeployStageBuilder.deploy_stage_name?(stage.name)

  # ── Case 1: HOLE A ────────────────────────────────────────────────────

  describe "hole A — a command-only stack member plan" do
    test "enters in_review at its last stage and the rollup merge fires",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Command-only member")

      {plan, [build, lint]} =
        plan_fixture(task, [{"Build", ["test_pass"]}, {"Lint", ["lint_pass"]}])

      # No gate stage anywhere — this is what makes it hole A and not hole B.
      refute Enum.any?(Tasks.list_stages(plan.id), &MemberReviewEntry.gate_stage?/1),
             "hole A requires a plan with NO gate stage"

      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      # BEAT 1 — pre-state.
      assert status_of(task) == "in_progress"
      assert FakeRunner.merge_calls() == []

      # Settle the FIRST stage: Lint is still ahead, so the member must not
      # move yet (clause (c) is false while a non-gate stage is unsettled).
      pass_all(build.validations)
      assert stage_statuses(plan) == ["passed", "running"]
      assert status_of(task) == "in_progress"
      assert FakeRunner.merge_calls() == []

      # BEAT 2 — settle the LAST stage.
      pass_all(lint.validations)

      # BEAT 3 — post-state: the member reached in_review and the deployer
      # actually attempted the merge (observed at the git runner, not at a
      # mock of the hook), and stamped the task.
      assert status_of(task) == "in_review"

      assert [call] = FakeRunner.merge_calls(),
             "expected exactly one rollup merge attempt, got #{inspect(FakeRunner.merge_calls())}"

      assert call.member_task_id == task.id
      assert call.stack_id == stack.id
      assert call.rollup_branch == stack.rollup_branch

      reloaded = Tasks.get_task_record(task.id)
      assert %{"merged_into_rollup_at" => %{"sha" => "f00dbabe"}} = reloaded.metadata

      # The per-task plan completes (stack members get no deploy stage).
      completed = Tasks.get_plan(plan.id)
      assert completed.status == "completed"
      refute Enum.any?(Tasks.list_stages(plan.id), &deploy_stage?/1)
    end

    test "with a resolved deploy_target the stamp carries the member on to deploying",
         %{project: project, stack: stack} do
      # Same shape as above plus a deploy target, so the stamp-driven
      # `Stacks.advance_member_to_deploying/1` tail can complete. This is the
      # full terminal path the ticket says never fired.
      task =
        task_fixture(project, stack, "in_progress", "Command-only deployable member", %{
          deploy_target: "production"
        })

      {_plan, [build]} = plan_fixture(task, [{"Build", ["test_pass", "lint_pass"]}])
      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      assert status_of(task) == "in_progress"

      pass_all(build.validations)

      assert [_call] = FakeRunner.merge_calls()
      assert status_of(task) == "deploying"
    end
  end

  # ── Case 2: HOLE B ────────────────────────────────────────────────────

  describe "hole B — the member's FINAL stage is the gated one" do
    test "enters in_review once the non-gate stages settle, plan stays open, no deploy stage",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Gate-last member")

      {plan, [build, review]} =
        plan_fixture(task, [{"Build", ["test_pass"]}, {"Review", ["e2e_behavior"]}])

      assert plan.id
             |> Tasks.list_stages()
             |> Enum.find(&(&1.id == review.stage.id))
             |> MemberReviewEntry.gate_stage?()

      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      # BEAT 1
      assert status_of(task) == "in_progress"

      # BEAT 2 — settle the only non-gate stage.
      pass_all(build.validations)

      # BEAT 3
      assert status_of(task) == "in_review"

      # The gate is still open: the plan is NOT complete, the gate stage was
      # auto-started (not passed), and no deploy stage was injected.
      assert Tasks.get_plan(plan.id).status != "completed"
      assert stage_statuses(plan) == ["passed", "running"]
      refute Enum.any?(Tasks.list_stages(plan.id), &deploy_stage?/1)

      # The deployer was invoked but declined: the review stage's e2e
      # validation is still pending, so nothing reached the runner.
      assert FakeRunner.merge_calls() == []
      refute Map.has_key?(Tasks.get_task_record(task.id).metadata || %{}, "merged_into_rollup_at")
    end
  end

  # ── Case 3: STILL BLOCKED (where the rule loses) ──────────────────────

  describe "a member with a gate stage AND unsettled non-gate work" do
    test "stays in_progress until the non-gate work settles",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Not-yet-settled member")

      {plan, [build, lint, _review]} =
        plan_fixture(task, [
          {"Build", ["test_pass"]},
          {"Lint", ["lint_pass"]},
          {"Review", ["e2e_behavior"]}
        ])

      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      # BEAT 1
      assert status_of(task) == "in_progress"

      # BEAT 2 — settle Build only. Lint (non-gate) becomes running.
      pass_all(build.validations)
      assert stage_statuses(plan) == ["passed", "running", "pending"]

      # BEAT 3 — the rule LOSES here: a non-gate stage is unsettled.
      assert status_of(task) == "in_progress"
      assert FakeRunner.merge_calls() == []

      # Control: the same member DOES move once Lint settles (hole B shape),
      # so the pre-state above was held by the rule and not by a broken seam.
      pass_all(lint.validations)
      assert status_of(task) == "in_review"
    end
  end

  # ── Case 4: ADR-0046 regression ───────────────────────────────────────

  describe "ADR-0046 — a member already at deploying" do
    test "is left at deploying when its plan completes; PlanCompletion still answers :noop",
         %{project: project, stack: stack} do
      task =
        task_fixture(project, stack, "in_progress", "Deploying member", %{
          deploy_target: "production"
        })

      {plan, [build]} = plan_fixture(task, [{"Build", ["test_pass"]}])
      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      # Walk the member to `deploying` the way the lifecycle does. Both hops
      # fire the tasks.ex stack hook; whatever the deployer did on the way
      # is cleared so the assertion below is about THIS settlement only.
      {:ok, task} = Tasks.transition_task(Tasks.get_task_record(task.id), "in_review")
      {:ok, task} = Tasks.transition_task(task, "deploying")
      Agent.update(FakeRunner, fn state -> %{state | merge_calls: []} end)

      # BEAT 1
      assert status_of(task) == "deploying"

      # BEAT 2 — the plan completes.
      pass_all(build.validations)

      # BEAT 3 — status UNCHANGED. Without this the 2026-07-27 fix regresses.
      assert status_of(task) == "deploying"

      completed = Tasks.get_plan(plan.id)
      assert completed.status == "completed"
      assert PlanCompletion.advance_task(completed, :stack_member) == :noop
      assert status_of(task) == "deploying"
      assert FakeRunner.merge_calls() == []
    end
  end

  # ── Case 5: SOLO TASK ─────────────────────────────────────────────────

  describe "a solo task (stack_id: nil) with a command-only plan" do
    test "gains no in_review transition from this seam", %{project: project} do
      task = task_fixture(project, nil, "in_progress", "Solo command-only task")
      assert task.stack_id == nil

      {plan, [build, lint]} =
        plan_fixture(task, [{"Build", ["test_pass"]}, {"Lint", ["lint_pass"]}])

      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      # BEAT 1
      assert status_of(task) == "in_progress"

      # BEAT 2
      pass_all(build.validations)
      pass_all(lint.validations)

      # BEAT 3 — unchanged: a solo task at in_progress completes its plan
      # without a deploy stage (the @deployable_statuses narrowing) and this
      # seam must not be the thing that moves it to in_review.
      assert status_of(task) == "in_progress"
      assert Tasks.get_plan(plan.id).status == "completed"
      refute Enum.any?(Tasks.list_stages(plan.id), &deploy_stage?/1)
      assert FakeRunner.merge_calls() == []
    end
  end

  # ── Case 6: TELEMETRY (stage 3) ───────────────────────────────────────
  #
  # `[:platform, :tasks, :member_review_entry]` is the operator's only signal
  # that this seam fired. Each test attaches its handler BEFORE the action
  # that could emit, uses the per-test ref as the handler id, and detaches on
  # exit. The two negative cases use `refute_receive`: a handler attached
  # after the action would make them vacuous.

  @entry_event [:platform, :tasks, :member_review_entry]

  defp attach_entry_handler do
    ref = :telemetry_test.attach_event_handlers(self(), [@entry_event])
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  describe "telemetry — [:platform, :tasks, :member_review_entry]" do
    test "fires exactly once on the hole-A transition with the member pinned in metadata",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Telemetry hole-A member")

      {plan, [build, lint]} =
        plan_fixture(task, [{"Build", ["test_pass"]}, {"Lint", ["lint_pass"]}])

      {:ok, _} = PlanEngine.start_stage(build.stage.id)
      ref = attach_entry_handler()

      # Settling the first stage is a `:noop` settlement: nothing may emit.
      pass_all(build.validations)
      refute_receive {@entry_event, ^ref, _, _}, 100

      pass_all(lint.validations)
      assert status_of(task) == "in_review"

      assert_receive {@entry_event, ^ref, %{count: 1}, meta}
      assert meta.task_id == task.id
      assert meta.stack_id == stack.id
      assert meta.plan_id == plan.id
      assert meta.gate_stage_count == 0
      assert meta.resource_type == "task"
      assert meta.resource_id == task.id
      assert meta.action == "member_review_entry"
      assert meta.actor_type == "system"

      # Exactly once: the transition happened one time, so a second event
      # would mean the seam re-fired on a later settlement.
      refute_receive {@entry_event, ^ref, _, _}, 100
    end

    test "reports the excluded gate stages in gate_stage_count on the hole-B transition",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Telemetry hole-B member")

      {plan, [build, _review]} =
        plan_fixture(task, [{"Build", ["test_pass"]}, {"Review", ["e2e_behavior"]}])

      {:ok, _} = PlanEngine.start_stage(build.stage.id)
      ref = attach_entry_handler()

      pass_all(build.validations)
      assert status_of(task) == "in_review"

      # Pinned at 1, not merely non-zero: the Review stage is the one gate
      # stage clause (c) excluded, and that number is what an operator reads
      # to tell hole B from hole A.
      assert_receive {@entry_event, ^ref, %{count: 1}, meta}
      assert meta.task_id == task.id
      assert meta.plan_id == plan.id
      assert meta.gate_stage_count == 1
      refute_receive {@entry_event, ^ref, _, _}, 100
    end

    test "does NOT fire for an ADR-0046 member already at deploying",
         %{project: project, stack: stack} do
      task =
        task_fixture(project, stack, "in_progress", "Telemetry deploying member", %{
          deploy_target: "production"
        })

      {_plan, [build]} = plan_fixture(task, [{"Build", ["test_pass"]}])
      {:ok, _} = PlanEngine.start_stage(build.stage.id)

      {:ok, task} = Tasks.transition_task(Tasks.get_task_record(task.id), "in_review")
      {:ok, task} = Tasks.transition_task(task, "deploying")
      assert status_of(task) == "deploying"

      ref = attach_entry_handler()
      pass_all(build.validations)

      assert status_of(task) == "deploying"
      refute_receive {@entry_event, ^ref, _, _}, 100
    end

    test "does NOT fire for a member whose non-gate work is still unsettled",
         %{project: project, stack: stack} do
      task = task_fixture(project, stack, "in_progress", "Telemetry still-blocked member")

      {_plan, [build, lint, _review]} =
        plan_fixture(task, [
          {"Build", ["test_pass"]},
          {"Lint", ["lint_pass"]},
          {"Review", ["e2e_behavior"]}
        ])

      {:ok, _} = PlanEngine.start_stage(build.stage.id)
      ref = attach_entry_handler()

      pass_all(build.validations)
      assert status_of(task) == "in_progress"
      refute_receive {@entry_event, ^ref, _, _}, 100

      # Control: the same handler DOES see the event once Lint settles, so the
      # silence above was the `:noop` path and not a detached handler.
      pass_all(lint.validations)
      assert status_of(task) == "in_review"
      assert_receive {@entry_event, ^ref, %{count: 1}, %{task_id: task_id, gate_stage_count: 1}}
      assert task_id == task.id
    end
  end
end
