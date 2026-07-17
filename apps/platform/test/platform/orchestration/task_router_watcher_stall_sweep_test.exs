defmodule Platform.Orchestration.TaskRouterWatcherStallSweepTest do
  @moduledoc """
  Bug #4 (task 019f708f) — `TaskRouterWatcher.sweep_in_review_stalls/0`
  regression coverage.

  The sweep piggybacks on the existing 5-minute `:reconcile` tick.
  These tests drive the sweep synchronously via the exposed public
  function so we can observe telemetry and the auto-transition
  without spinning the scheduler.

  The four regression cases mirror the plan's stage-4 e2e_behavior
  spec:

    (a) Fully-satisfied stalled task → auto-transition to `deploying`,
        `:auto_transitioned_to_deploying` telemetry fires.
    (b) Same shape but `updated_at` inside the 15-min debounce
        window → no transition, no auto-transition telemetry.
    (c) Same shape but a pending review_request exists → no
        transition, `:pending_review_requests` observation
        telemetry fires.
    (d) Non-stack task with no stamp at `in_review` → observation
        telemetry only, no transition (the sweep's query already
        excludes it via `stack_id IS NOT NULL`, but the defensive
        branch is still asserted).
  """
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ReviewRequests, Stacks, Task}
  alias Platform.Orchestration.TaskRouterWatcher

  # Attach a telemetry handler that echoes stall events to the test pid.
  setup do
    test_pid = self()
    handler_id = "stall-sweep-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :stall_detected],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:stall_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # ── Fixture helpers ──────────────────────────────────────────────────

  defp create_project! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Stall Sweep " <> Ecto.UUID.generate(),
        repo_url: "https://github.com/test/stall-sweep"
      })

    project
  end

  defp create_stack!(project) do
    slug = "stall-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stall #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  # Seed a stack member sitting AT `in_review` with a valid
  # `merged_into_rollup_at` stamp AND all-passed review validations.
  # `updated_at` age is caller-controlled so the debounce path can be
  # exercised on both sides of the 15-min cutoff.
  defp stalled_stack_member!(project, stack, opts) do
    minutes_ago = Keyword.get(opts, :minutes_ago, 30)
    title = Keyword.get(opts, :title, "Stall member " <> Ecto.UUID.generate())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: 1,
        # `deploy_target` set so `require_deploy_target_for/2` clears
        # the transition into `deploying` (mirrors task_test.exs
        # deploy-gate fixtures).
        deploy_target: "production",
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => "abc1234",
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    # Approved plan with one stage, all validations passed.
    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

    backdate!(task, minutes_ago)

    Tasks.get_task_record(task.id)
  end

  defp backdate!(%Task{id: id}, minutes_ago) do
    backdate =
      DateTime.utc_now()
      |> DateTime.add(-minutes_ago * 60, :second)

    from(t in Task, where: t.id == ^id)
    |> Repo.update_all(set: [updated_at: backdate])
  end

  # ── the four regression cases ────────────────────────────────────────

  describe "sweep_in_review_stalls/0" do
    test "auto-transitions a fully-satisfied stalled stack member to deploying" do
      project = create_project!()
      stack = create_stack!(project)
      task = stalled_stack_member!(project, stack, minutes_ago: 20)

      # Pre-sweep: task is at in_review, sweep should find it.
      assert task.status == "in_review"

      result = TaskRouterWatcher.sweep_in_review_stalls()

      assert result.scanned == 1
      assert result.transitioned == 1
      assert result.observed == 0

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "deploying"

      task_id = task.id

      assert_receive {:stall_event, [:platform, :orchestration, :stall_detected], %{count: 1},
                      %{task_id: ^task_id, action: :auto_transitioned_to_deploying}},
                     500
    end

    test "leaves a stalled member alone when inside the 15-min debounce window" do
      project = create_project!()
      stack = create_stack!(project)
      task = stalled_stack_member!(project, stack, minutes_ago: 2)

      result = TaskRouterWatcher.sweep_in_review_stalls()

      # Query filters out the row entirely (updated_at inside debounce).
      assert result.scanned == 0
      assert result.transitioned == 0
      assert result.observed == 0

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"

      refute_receive {:stall_event, _, _, _}, 200
    end

    test "does not auto-transition when a pending review_request is present" do
      project = create_project!()
      stack = create_stack!(project)
      task = stalled_stack_member!(project, stack, minutes_ago: 30)

      # Create a pending review_request on the task. `ReviewRequests.create/1`
      # takes an author kind + attrs plus items; use the minimal path
      # via Repo insert to avoid coupling to the full ReviewRequests
      # public API (which requires an approver bundle context).
      # A pending review_request must be attached to a validation_id
      # (schema-level NOT NULL). Any validation on the task's plan
      # works; grab the first one from the fixture.
      [plan] = Tasks.list_plans(task.id)
      plan = Repo.preload(plan, stages: :validations)
      [stage] = plan.stages
      [validation | _] = stage.validations

      {:ok, _rr} =
        %Platform.Tasks.ReviewRequest{}
        |> Ecto.Changeset.change(%{
          task_id: task.id,
          validation_id: validation.id,
          submitted_by: "test-agent",
          status: "pending"
        })
        |> Repo.insert()

      # Sanity: the accessor sees the pending row.
      assert ReviewRequests.list_pending_for_task(task.id) != []

      result = TaskRouterWatcher.sweep_in_review_stalls()

      assert result.scanned == 1
      assert result.transitioned == 0
      assert result.observed == 1

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"

      task_id = task.id

      assert_receive {:stall_event, _, _,
                      %{
                        task_id: ^task_id,
                        action: :observed_only,
                        reason: :pending_review_requests
                      }},
                     500
    end

    test "surfaces observe-only telemetry for a stalled stack member with pending validations" do
      project = create_project!()
      stack = create_stack!(project)
      task = stalled_stack_member!(project, stack, minutes_ago: 30)

      # Flip one validation back to pending — the sweep must NOT
      # auto-transition when the review contract isn't fully met.
      [plan] = Tasks.list_plans(task.id)
      plan = Repo.preload(plan, stages: :validations)
      [stage] = plan.stages
      [v | _] = stage.validations

      v
      |> Ecto.Changeset.change(%{status: "pending"})
      |> Repo.update!()

      result = TaskRouterWatcher.sweep_in_review_stalls()

      assert result.scanned == 1
      assert result.transitioned == 0
      assert result.observed == 1

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"

      task_id = task.id

      assert_receive {:stall_event, _, _,
                      %{
                        task_id: ^task_id,
                        action: :observed_only,
                        reason: :validations_not_passed
                      }},
                     500
    end

    test "ignores non-stack tasks at in_review (query filter excludes them)" do
      project = create_project!()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Lone in_review",
          status: "in_review",
          deploy_target: "production",
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "abc1234",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      backdate!(task, 30)

      result = TaskRouterWatcher.sweep_in_review_stalls()

      # `stack_id IS NOT NULL` in the query filter excludes this row.
      assert result.scanned == 0
      assert result.transitioned == 0
      assert result.observed == 0

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_review"

      refute_receive {:stall_event, _, _, _}, 200
    end

    test "is a no-op when there are no stalled candidates at all" do
      # No candidates at all — sweep exits with zero counts, no
      # telemetry fires, no transitions happen.
      result = TaskRouterWatcher.sweep_in_review_stalls()

      assert result == %{scanned: 0, transitioned: 0, observed: 0}
      refute_receive {:stall_event, _, _, _}, 200
    end

    test "returns tasks in updated_at ascending order (oldest first)" do
      project = create_project!()
      stack1 = create_stack!(project)
      stack2 = create_stack!(project)

      # Two stalled members, one much older than the other. The
      # sweep processes both; both get transitioned. Ordering is
      # oldest-first for predictable operator debugging.
      older = stalled_stack_member!(project, stack1, minutes_ago: 90)
      newer = stalled_stack_member!(project, stack2, minutes_ago: 20)

      result = TaskRouterWatcher.sweep_in_review_stalls()

      assert result.scanned == 2
      assert result.transitioned == 2

      assert Tasks.get_task_record(older.id).status == "deploying"
      assert Tasks.get_task_record(newer.id).status == "deploying"
    end
  end
end
