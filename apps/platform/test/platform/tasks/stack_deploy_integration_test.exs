defmodule Platform.Tasks.StackDeployIntegrationTest do
  @moduledoc """
  Stack v2 stage 5 end-to-end coverage.

  Exercises the whole "seed 3-member stack → drive validations → dispatch
  deploy → simulate rollup PR merge → verify terminal state" pipeline
  through the real webhook controller. Complements the unit-level tests
  in `stacks_test.exs` and `stack_deployer_test.exs` by asserting the
  seams compose correctly across module boundaries.

  Also carries the stage-5 regression guard: a NON-stacked task still
  gets its per-task `pr_merge` deploy stage injected — the stack-scoped
  atomic-ship guard (`Tasks.dispatch_deploy_for_task/1`) does NOT
  over-fire and clobber the solo-task path.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Stacks, Stage}

  @github_webhook_path "/api/webhooks/github"

  # ── FakeRunner: in-memory git_runner behaviour ────────────────────────

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(_opts \\ []) do
      initial = %{
        ensure_calls: [],
        merge_calls: [],
        pr_calls: [],
        delete_calls: []
      }

      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def stop, do: Agent.stop(__MODULE__)

    def ensure_calls, do: Agent.get(__MODULE__, & &1.ensure_calls) |> Enum.reverse()
    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()
    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()
    def delete_calls, do: Agent.get(__MODULE__, & &1.delete_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(args) do
      Agent.update(__MODULE__, fn s -> %{s | ensure_calls: [args | s.ensure_calls]} end)
      {:ok, %{status: :created, base_sha: "base00000"}}
    end

    @impl true
    def merge_member_into_rollup(args) do
      Agent.update(__MODULE__, fn s -> %{s | merge_calls: [args | s.merge_calls]} end)
      {:ok, %{status: :merged, merge_sha: "m#{System.unique_integer([:positive])}"}}
    end

    @impl true
    def open_stack_pr(args) do
      Agent.update(__MODULE__, fn s -> %{s | pr_calls: [args | s.pr_calls]} end)

      {:ok,
       %{
         number: 4242,
         url: "https://github.com/test/repo/pull/4242"
       }}
    end

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "revert0000"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(args) do
      Agent.update(__MODULE__, fn s -> %{s | delete_calls: [args | s.delete_calls]} end)
      {:ok, :deleted}
    end

    # Bug #2 (task 019f708f): default to reachable so the integration
    # test's ff-only merges promote through without needing per-SHA
    # reachability seeding.
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    {:ok, _} = FakeRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: FakeRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        FakeRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ── Happy path: 3-member stack ships as ONE rollup PR ─────────────────

  describe "single-PR happy path" do
    test "3-member stack: validations pass → dispatch fires once → rollup merges → all done + cleanup",
         %{conn: conn} do
      handler_id = "int-happy-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:platform, :stacks, :deploy, :dispatched],
            [:platform, :stacks, :deploy, :pr_merged],
            [:platform, :tasks, :deploy_dispatch, :rejected_stack_member]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, members: members, rollup_branch: rollup_branch} =
        build_stack_scenario!("single-pr-happy", 3)

      # ── Drive each member's plan through validations ────────────────
      #
      # Each member's plan carries a single non-deploy validation
      # (test_pass). Pass them all — the LAST evaluate_validation
      # should trigger PlanEngine.maybe_inject_deploy_or_complete/2 →
      # Stacks.dispatch_stack_deploy/1 → transition to "deploying" +
      # dispatched telemetry.
      for %{validation: v} <- members do
        {:ok, _} =
          PlanEngine.evaluate_validation(v.id, %{
            status: "passed",
            evaluated_by: "test",
            evidence: %{"result" => "ok"}
          })
      end

      # ── Assert exactly ONE :dispatched telemetry event ──────────────
      assert_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _,
                       %{stack_id: stack_id}}

      assert stack_id == stack.id
      refute_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _, _}

      # ── Assert NO per-member `pr_merge` dispatch was rejected here ──
      # (dispatch_deploy_for_task/1 blocks stack members up-front, so
      # the rejection telemetry fires from an INJECTION attempt. In
      # this scenario the guard is at the plan-engine seam BEFORE the
      # would-be injection, so :rejected_stack_member fires N times
      # (once per member's plan completion). That's the invariant we
      # want — every member's per-task path was correctly refused.)
      for _ <- members do
        assert_received {:telemetry,
                         [:platform, :tasks, :deploy_dispatch, :rejected_stack_member], _, _}
      end

      # ── The dispatch should have queued exactly ONE open_stack_pr ──
      # under the FakeRunner (async: false, so synchronous by the time
      # evaluate_validation/2 returns).
      assert length(FakeRunner.pr_calls()) == 1

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "deploying"
      assert reloaded.metadata["rollup_pr"]["number"] == 4242

      # ── Simulate the GitHub `pull_request.closed` webhook ───────────
      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # ── Stack now at done + members at done + branch cleanup ────────
      done_stack = Stacks.get_stack(stack.id)
      assert done_stack.status == "done"
      assert is_binary(done_stack.metadata["rollup_pr"]["merged_at"])

      for %{task: task} <- members do
        assert Tasks.get_task_record(task.id).status == "done"
      end

      # ── Rollup-branch delete was invoked exactly once ───────────────
      assert length(FakeRunner.delete_calls()) == 1
      [delete_call] = FakeRunner.delete_calls()
      assert delete_call.rollup_branch == rollup_branch
      assert delete_call.stack_id == stack.id

      # ── :pr_merged telemetry fires exactly once with correct shape ──
      assert_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged],
                       %{count: 1, duration_ms_in_deploying: duration_ms}, pr_merged_meta}

      assert pr_merged_meta.stack_id == stack.id
      assert pr_merged_meta.member_count == 3
      assert is_binary(pr_merged_meta.merge_commit_sha)
      assert pr_merged_meta.rollup_branch == rollup_branch
      # Duration was computed off the rollup_pr.opened_at we stamped
      # in finalize_pr_opened; should be a non-negative integer ms.
      assert is_integer(duration_ms) and duration_ms >= 0

      refute_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}
    end
  end

  # ── Regression: non-stacked task still gets its per-task deploy stage ─

  describe "non-stacked task regression guard" do
    test "solo task's plan-complete injects the per-task `pr_merge` deploy stage" do
      handler_id = "int-regression-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:platform, :stacks, :deploy, :dispatched],
            [:platform, :stacks, :deploy, :pr_merged],
            [:platform, :tasks, :deploy_dispatch, :rejected_stack_member]
          ],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, project} =
        Tasks.create_project(%{
          name: "Regression Solo #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/regression-repo",
          deploy_config: %{"default_strategy" => %{"type" => "pr_merge"}}
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Solo regression"})

      {:ok, task} =
        Tasks.update_task(task, %{
          status: "in_review",
          branch_name: "task/#{task.id}"
        })

      # Approved plan with a single validation stage + a passing test_pass
      # validation. When we flip the validation to passed, plan-complete
      # runs and `maybe_inject_deploy_or_complete/2` should inject a
      # `Deploy: PR merge` stage since this task is NOT in a stack.
      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Build",
          description: "Build stage",
          status: "running"
        })

      {:ok, validation} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

      assert {:ok, _} =
               PlanEngine.evaluate_validation(validation.id, %{
                 status: "passed",
                 evaluated_by: "test",
                 evidence: %{"result" => "ok"}
               })

      # Deploy stage was injected — the plan now carries a stage whose
      # name starts with "Deploy: ".
      plan =
        Plan
        |> Repo.get!(plan.id)
        |> Repo.preload(stages: from(s in Stage, order_by: s.position))

      deploy_stage = Enum.find(plan.stages, &String.starts_with?(&1.name, "Deploy: "))
      assert deploy_stage != nil, "expected Deploy: stage to be injected on solo task"

      # NO stack telemetry should have fired on this per-task path.
      refute_received {:telemetry, [:platform, :stacks, :deploy, :dispatched], _, _}
      refute_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}

      # The rejected_stack_member telemetry MUST NOT fire because this
      # task has no `stack_id`.
      refute_received {:telemetry, [:platform, :tasks, :deploy_dispatch, :rejected_stack_member],
                       _, _}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Seed a project + stack + N members. Each member is at `in_review`
  # with an approved plan, a running stage, and a single pending
  # `test_pass` validation. `metadata["merged_into_rollup_at"]` is
  # pre-stamped so the maybe_open_stack_pr gate passes (in the real
  # flow, per-member merges stamp this — we short-circuit to keep the
  # test focused on the deploy-dispatch + webhook seams). Also stamps
  # a rollup_pr.opened_at value ahead of time by pre-running the
  # dispatch mock; NO — we let the actual dispatch path stamp
  # rollup_pr since that's what we're exercising.
  defp build_stack_scenario!(slug, member_count) when member_count > 0 do
    rollup_branch = "stack/#{slug}"

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stack v2 Integration #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/stack-integration-repo"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: rollup_branch,
        status: "in_progress"
      })

    members =
      for position <- 1..member_count do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Member #{position}"
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            status: "in_review",
            metadata: %{
              "merged_into_rollup_at" => %{
                # Bug #3 (task 019f708f) shape validator requires hex-only,
                # >= 7 chars. Pad the position into a valid hex-shaped SHA.
                "sha" => "abcdef" <> String.pad_leading(Integer.to_string(position), 2, "0"),
                "at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            }
          })

        {:ok, plan} =
          Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Build",
            description: "Build stage",
            status: "running"
          })

        {:ok, validation} =
          Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

        %{task: task, plan: plan, stage: stage, validation: validation}
      end

    %{project: project, stack: stack, rollup_branch: rollup_branch, members: members}
  end

  defp rollup_merged_payload(rollup_branch) do
    %{
      "action" => "closed",
      "pull_request" => %{
        "merged" => true,
        "title" => "chore: stack rollup",
        "number" => 4242,
        "html_url" => "https://github.com/test/stack-integration-repo/pull/4242",
        "merge_commit_sha" => "rollup#{System.unique_integer([:positive])}",
        "merged_at" => "2026-07-11T20:00:00Z",
        "body" => "",
        "user" => %{"login" => "merge-bot"},
        "merged_by" => %{"login" => "human-merger"},
        "head" => %{"ref" => rollup_branch},
        "base" => %{"ref" => "main"}
      }
    }
  end
end
