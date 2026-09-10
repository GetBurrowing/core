defmodule PlatformWeb.GithubWebhookDeliveredButOpenTest do
  @moduledoc """
  A merged PR that names an OPEN task with no plan gate to absorb it stamps
  the task `delivered_but_open` and parks the router — it never closes the
  task (task 01a0665e stage 1).

  ## The quantity under test

  `done` is reachable in `Tasks.valid_task_transitions/0` only from
  `in_progress` / `in_review` / `deploying`, and the ONLY automated route to
  it from a merge is `pass_pr_merged_validation/4` → `PlanEngine` →
  `PlanCompletion.transition_to_done/3` for a task already at `deploying`.
  This stage adds no second route. So each case here asserts BOTH the stamp
  and the status — a stamp on a task that quietly went `done` would be the
  bug ADR 0029 exists to prevent, and a status that stayed put with no stamp
  is the 01a0554f loop unchanged.

  ## The trap (case 3)

  `find_pending_pr_merged_validations/1` is plan-status-blind on purpose
  (019f9b34), so a running deploy stage on a SUPERSEDED plan version is still
  a candidate. Passing it drove completion for a plan that is no longer the
  plan (01a046a6-5761). The guard keys on plan identity —
  `stage.plan_id == Tasks.current_plan(task_id).id` — because the branch name
  `task/<id>` is shared across every version and cannot tell them apart.
  Case 4 is the positive control: the same shape on the CURRENT plan still
  passes and still reaches `done`, so the guard is not "never pass".
  """

  use PlatformWeb.ConnCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Task, Validation}

  @github_webhook_path "/api/webhooks/github"
  @telemetry_event [:platform, :tasks, :delivered_but_open]

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Delivered-but-open #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/dbo-repo"
      })

    # No task exists yet, so scope by emitting process: the controller stamps
    # (and emits) synchronously inside the conn's request, i.e. in this test
    # process. Unfiltered, a sibling module's stamp trips the refutes below
    # (CI runs 34507040013 and 34507488848; task 01a08b5f stage 2).
    Platform.TelemetryHelpers.attach_scoped(@telemetry_event, :caller, self(),
      tag: :delivered_but_open_telemetry
    )

    %{project: project}
  end

  describe "a merge that lands on nothing" do
    test "(1) planning task, no plan: stamped with the PR facts, still planning, not done",
         %{conn: conn, project: project} do
      task = open_task!(project, "planning")
      pr_url = "https://github.com/test/dbo-repo/pull/883"

      merge!(conn, task, pr_url, "66d8ecb7")

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.status == "planning"
      refute reloaded.status == "done"

      stamp = reloaded.metadata["delivered_but_open"]

      assert stamp["pr_url"] == pr_url,
             "the webhook's `[]` branch must stamp the task — it used to log and return :ok " <>
               "(01a0554f, five planning dispatches against merged PR #883)"

      assert stamp["merge_commit_sha"] == "66d8ecb7"
      assert stamp["head_branch"] == "task/#{task.id}"
      assert is_binary(reloaded.metadata["delivered_but_open_at"])

      # The stamp is what the board and the router read. Positive trace: the
      # resolver ranks it first, and the telemetry fired once for this task.
      assert Tasks.needs_human_action_reason(reloaded, 0) == :delivered_but_open
      task_id = task.id

      assert_received {:delivered_but_open_telemetry, @telemetry_event, %{count: 1},
                       %{task_id: ^task_id}}
    end

    test "(2) blocked task: stamped, still blocked", %{conn: conn, project: project} do
      task = open_task!(project, "blocked")

      merge!(conn, task, "https://github.com/test/dbo-repo/pull/884", "b10c4ed0")

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.status == "blocked"
      assert reloaded.metadata["delivered_but_open"]["merge_commit_sha"] == "b10c4ed0"
      assert is_binary(reloaded.metadata["delivered_but_open_at"])
    end

    test "(5) done task: no stamp", %{conn: conn, project: project} do
      task = open_task!(project, "in_progress")
      task = task |> Ecto.Changeset.change(%{status: "done"}) |> Repo.update!()

      merge!(conn, task, "https://github.com/test/dbo-repo/pull/885", "d0e0d0e0")

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.status == "done"
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open")
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open_at")
      refute_received {:delivered_but_open_telemetry, _, _, _}
    end

    # Task 01a08b5f stage 2. The forwarder is VM-global, so a sibling
    # module's stamp — a `task_id` this test never created — lands in this
    # mailbox and trips the refutes above. A bare `spawn` carries no
    # `$callers`, so it stands in for that sibling rather than for this test.
    test "a sibling's delivered_but_open for a foreign task_id does not reach this test's mailbox" do
      {pid, ref} =
        spawn_monitor(fn ->
          :telemetry.execute(@telemetry_event, %{count: 1}, %{
            task_id: Ecto.UUID.generate(),
            status: "planning",
            pr_url: "https://github.com/test/dbo-repo/pull/0"
          })
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute_received {:delivered_but_open_telemetry, _, _, _}
    end
  end

  describe "a pending gate on a non-current plan version (01a046a6-5761)" do
    test "(3) THE TRAP: v1 superseded with a running deploy gate, v2 current without one — " <>
           "the v1 gate stays pending, the task is stamped, not done",
         %{conn: conn, project: project} do
      task = deployable_task!(project)
      v1 = deploy_plan!(task, 1, "superseded")

      {:ok, v2} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 2})
      {:ok, _build} = Tasks.create_stage(%{plan_id: v2.id, position: 1, name: "Build"})

      {:ok, task} = Tasks.transition_task(task, "deploying")
      assert Tasks.current_plan(task.id).id == v2.id, "precondition: v2 is the current plan"

      # Precondition for the trap: the plan-blind query DOES return the v1
      # gate. If it stopped doing so this test would pass vacuously.
      assert [%Validation{id: gate_id}] =
               PlatformWeb.GithubWebhookController.find_pending_pr_merged_validations(task.id)

      assert gate_id == v1.gate.id

      pr_url = "https://github.com/test/dbo-repo/pull/886"
      merge!(conn, task, pr_url, "5761c0de")

      assert Repo.get!(Validation, v1.gate.id).status == "pending",
             "a gate on a superseded plan version was passed by a merge — " <>
               "branch equality cannot tell plan versions apart; plan identity must"

      reloaded = Repo.get!(Task, task.id)
      refute reloaded.status == "done"
      assert reloaded.status == "deploying"
      assert reloaded.metadata["delivered_but_open"]["pr_url"] == pr_url
      assert reloaded.metadata["delivered_but_open"]["merge_commit_sha"] == "5761c0de"

      # v2 is untouched: nothing on the current plan was passed or started.
      assert Enum.all?(Tasks.list_stages(v2.id), &(&1.status == "pending"))
    end

    test "(4) POSITIVE CONTROL: the same gate on the CURRENT plan passes and the task reaches done",
         %{conn: conn, project: project} do
      task = deployable_task!(project)
      v1 = deploy_plan!(task, 1, "approved")
      {:ok, task} = Tasks.transition_task(task, "deploying")
      assert Tasks.current_plan(task.id).id == v1.plan.id

      merge!(conn, task, "https://github.com/test/dbo-repo/pull/887", "900d900d")

      passed = Repo.get!(Validation, v1.gate.id)
      assert passed.status == "passed"
      assert passed.evaluated_by == "github_webhook"
      assert passed.evidence["merge_commit_sha"] == "900d900d"

      reloaded = Repo.get!(Task, task.id)

      assert reloaded.status == "done",
             "the existing deploying -> done route must survive the guard: " <>
               "current-plan gate passed, PlanCompletion advanced the task"

      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open")
      refute_received {:delivered_but_open_telemetry, _, _, _}
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp open_task!(project, status) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Shipped while #{status}",
        status: status
      })

    task
  end

  # `in_progress` with a resolvable deploy target, so `transition_task/2` to
  # `deploying` clears `require_deploy_target_for/2` — the same shape as
  # `PlanCompletionTest.deploying_fixture/3`.
  defp deployable_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Deploying with a plan history",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    task
  end

  # A plan at `version` / `status` whose sole stage is a RUNNING deploy stage
  # with a PENDING `pr_merged` gate — the exact shape
  # `find_pending_pr_merged_validations/1` selects.
  defp deploy_plan!(task, version, status) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: status, version: version})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})

    {:ok, running} = Tasks.transition_stage(stage, "running")
    {:ok, gate} = Tasks.create_validation(%{stage_id: running.id, kind: "pr_merged"})

    %{plan: plan, stage: running, gate: gate}
  end

  defp merge!(conn, task, pr_url, sha) do
    payload = %{
      "action" => "closed",
      "pull_request" => %{
        "merged" => true,
        "title" => "fix: ship it",
        "number" => System.unique_integer([:positive]),
        "html_url" => pr_url,
        "merge_commit_sha" => sha,
        "merged_at" => "2026-08-31T10:00:00Z",
        "body" => "",
        "user" => %{"login" => "agent-bot"},
        "merged_by" => %{"login" => "rowan"},
        "head" => %{"ref" => "task/#{task.id}"}
      }
    }

    conn = signed_github_post(conn, @github_webhook_path, payload)
    assert %{"status" => "created"} = json_response(conn, 201)
    conn
  end
end
