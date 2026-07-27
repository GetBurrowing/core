defmodule Platform.Orchestration.TaskRouterDispatchSuppressionTest do
  @moduledoc """
  Covers the `:dispatch` suppression clauses in
  `Platform.Orchestration.TaskRouter` (task 019fa2fc stage 4).

  Production on 2026-07-27 logged four `dispatched task_assigned` lines for the
  same two tasks inside a 100 ms window at 09:47:12, each a full prompt payload
  to a runtime that correctly found nothing to do. Stages 1-3 removed the cause;
  this stage adds the guard so a future regression on the transition path
  degrades into a stuck task instead of a token-burning loop.

  THE FAILURE MODE THIS FILE EXISTS TO CATCH IS THE INVERSE ONE. A guard that
  suppresses too much strangles live agents silently — no log, no telemetry the
  operator would think to look at, just a task that never gets its prompt. So
  the two negative controls carry more weight here than the positive case, and
  each of them is written to fail if the predicate is widened past
  `plan.status == "completed"`.

  Evidence is the actual runtime broadcast, not a log line: `dispatch_attention/5`
  publishes on `runtime:<id>`, so subscribing to that topic observes exactly the
  thing the incident counted. (`config :logger, level: :warning` in
  `config/test.exs` drops the `Logger.info` dispatch line before any capture
  handler sees it, so a log assertion would silently be vacuous.)

  Deliberately a NEW file: `task_router_test.exs` is owned by task 019fa121
  (the sleep-removal rewrite) and must not be touched here.

  No `Process.sleep` anywhere. The barrier is `TaskRouter.current_status/1` — a
  plain `GenServer.call`, so it cannot be answered until every message already
  in the router's mailbox has been handled.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  setup do
    # Routers are separate processes that hit the repo.
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Router Suppression Project",
        repo_url: "https://github.com/test/router-suppression"
      })

    %{project: project}
  end

  describe "completed-plan suppression" do
    test "suppresses dispatch for a deploying task whose plan is completed with no running stage",
         %{project: project} do
      %{task: task} = fixture = completed_plan_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      assert_received {:dispatch_suppressed, %{task_id: task_id, reason: reason}}
      assert task_id == task.id
      assert reason == :completed_plan_no_work

      # The point of the guard: no prompt payload reached the runtime.
      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "records the task status and clears liveness when it suppresses", %{project: project} do
      %{task: task, stage: stage} = fixture = completed_plan_task(project)
      %{pid: pid} = start_router!(fixture)

      :ok = LeaseManager.record_dispatch(task.id, stage.id, "test_pass", DateTime.utc_now())
      assert LeaseManager.get(task.id)

      send(pid, :dispatch)
      status = barrier(task)

      assert status.task_status == "deploying"
      assert LeaseManager.get(task.id) == nil
    end
  end

  describe "negative controls — the guard must not strangle live work" do
    test "a task whose current plan is approved with a RUNNING stage still dispatches", %{
      project: project
    } do
      # Widening the predicate to drop the running-stage check (or the
      # `completed` plan-status check) makes this task look identical to the
      # suppressed one: same task status, no open validations, nothing pending.
      # The only thing separating them is that this plan is still `approved`
      # and an agent is actively mid-stage.
      %{task: task} = fixture = running_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "a task whose current plan is approved with a PENDING zero-validation stage still dispatches",
         %{project: project} do
      # THE misfire the narrow predicate exists to avoid. This plan has no
      # running stage and no open validation — exactly the shape
      # `settled_stack_member_no_work?/2` tests for — yet the agent has never
      # been prompted for stage 1 and is the only thing that can start it.
      # Suppressing here would park the task forever with no operator signal.
      %{task: task} = fixture = pending_stage_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end

    test "a COMPLETED plan whose deploy stage is still running keeps dispatching", %{
      project: project
    } do
      # The 019f9b34 / 019f9ae5 drift shape: the plan row reads `completed`
      # while a `Deploy: PR merge` stage is still `running`. That combination
      # once flipped task 019f9ae5 to done eight minutes before its PR merged,
      # and it is the reason the predicate ALSO requires no running stage —
      # dropping that half is the second way to widen this guard into a
      # strangler. A running deploy stage means the deploy has genuinely not
      # happened yet and the deployer agent is precisely who needs the prompt.
      #
      # NOTE FOR THE REVIEWER — the plan's e2e_behavior validation
      # 019fa307-c920-7797-9cbe-e2b2832e7a38 sets up exactly this fixture and
      # then expects `dispatch_suppressed` to fire with
      # `reason: :completed_plan_no_work`. That expectation contradicts this
      # stage's own implementation spec ("`current_running_stage(plan) == nil`")
      # and it is the e2e expectation that is wrong: suppressing here would
      # strand every task whose PR is legitimately awaiting merge. The stage's
      # 019f9b34 guard lives in `PlanCompletion` and holds the task at
      # `deploying`; the router must keep prompting.
      %{task: task} = fixture = unsettled_deploy_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      refute_received {:dispatch_suppressed, _meta}
      assert_received %Phoenix.Socket.Broadcast{event: "attention"}
    end
  end

  describe "existing stack-member suppression" do
    test "still fires, and still reports reason :settled_stack_member", %{project: project} do
      # Guards the `emit_dispatch_suppressed_telemetry/1 -> /2` arity change:
      # the event name and metadata shape are load-bearing for existing
      # dashboards. The plan here is `approved`, NOT `completed`, so the new
      # clause declines and control genuinely reaches the stack-member clause.
      %{task: task} = fixture = settled_stack_member_task(project)
      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)

      watch_dispatches!(runtime_id)

      send(pid, :dispatch)
      barrier(task)

      assert_received {:dispatch_suppressed, %{task_id: task_id, reason: reason}}
      assert task_id == task.id
      assert reason == :settled_stack_member

      refute_received %Phoenix.Socket.Broadcast{event: "attention"}
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # A task at `deploying` whose current plan is `completed` and holds no running
  # stage — the production shape that spun.
  defp completed_plan_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Suppression completed plan",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
        # transitions without a resolved target.
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(stage, "running")
    {:ok, stage} = Tasks.transition_stage(running, "passed")
    {:ok, task} = Tasks.transition_task(task, "deploying")

    %{task: task, stage: stage}
  end

  # Same task shape, but the plan is still `approved` and its stage is running —
  # an agent is mid-flight.
  defp running_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Suppression running stage",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")
    {:ok, task} = Tasks.transition_task(task, "deploying")

    %{task: task, stage: stage}
  end

  # An `approved` plan whose only stage is `pending` and carries zero
  # validations: no running stage, no open validation, real work outstanding.
  defp pending_stage_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Suppression pending stage",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

    assert stage.status == "pending"
    assert Tasks.list_validations(stage.id) == []

    %{task: task, stage: stage}
  end

  # A task at `deploying` whose plan row drifted to `completed` while its deploy
  # stage is still `running` — the 019f9b34 / 019f9ae5 condition.
  defp unsettled_deploy_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Suppression unsettled deploy",
        status: "in_progress",
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "completed"})

    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})
    {:ok, stage} = Tasks.transition_stage(stage, "running")
    {:ok, task} = Tasks.transition_task(task, "deploying")

    %{task: task, stage: stage}
  end

  # A stack member with an `approved` plan, no running stage and no open
  # validation — the 2026-07-22 tail-stall shape the existing clause covers.
  defp settled_stack_member_task(project) do
    slug = "router-suppression-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Router suppression boundary",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Suppression stack member",
        status: "in_progress",
        stack_id: stack.id,
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, running} = Tasks.transition_stage(stage, "running")
    {:ok, stage} = Tasks.transition_stage(running, "passed")

    %{task: task, stage: stage}
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

      # LeaseManager is a global singleton — purge this task's row.
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

  # Observe both halves of the decision: the suppression telemetry, and the
  # actual runtime broadcast a non-suppressed dispatch emits. Attaching AFTER
  # `start_router!/1` keeps boot-time events out of the mailbox.
  defp watch_dispatches!(runtime_id) do
    handler_id = "dispatch-suppression-#{System.unique_integer([:positive])}"
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

  # A complete mailbox barrier: `current_status/1` is a `GenServer.call`, so it
  # is answered only after every message queued ahead of it is handled. NOT a
  # sleep — task 019fa121 is removing all 116 of those from the sibling file.
  defp barrier(task), do: TaskRouter.current_status(task.id)
end
