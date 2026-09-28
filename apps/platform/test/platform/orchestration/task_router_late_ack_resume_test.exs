defmodule Platform.Orchestration.TaskRouterLateAckResumeTest do
  @moduledoc """
  Task 01a0e7ac stage 3: after the no-ack alarm blocks a task, a late ack
  from the dispatched runtime resumes it through the EXISTING path, and the
  alarm side closes the window in which an ack can slip past the block.

  ## Driven, end to end

  The router is started by a real `TaskRouterWatcher` (started here, as
  `task_router_watcher_test.exs` does, because the global singleton is off in
  test) from a task assigned to an agent linked to an activated runtime. So
  the watcher's `evaluate_task/1` is what stops the router when the task goes
  `blocked` and what starts a fresh one when the reconcile moves it out. The
  ack is `ToolSurface.execute("task_ack", ...)`; validations pass through
  `PlanEngine.evaluate_validation/2`. Only the no-ack CLOCK is poked.

  ## What a dispatch is, for counting

  A stage dispatch is an `"attention"` broadcast on the runtime topic whose
  prompt carries that stage's ack instruction (`stage_id="<id>"`). Engagement
  notices (the blocker post, the late-ack notice) name the stage id in other
  words and are not counted. Every refutation is paired with a positive on the
  same fixture: the first stage-1 dispatch is observed before the re-prompt is
  refuted, and the withheld boot dispatch is observed as a
  `:dispatch_suppressed` telemetry event with reason `:live_acked_executor`.

  ## RACE: how the ack is slipped into the window

  `maybe_fire_no_ack/3` reads the durable ack, then `fire_no_ack_alert/2` logs
  its warning, then stamps the block. A `:logger` handler, which runs in the
  router's own process, writes the owner's `execution.acked` row when that
  warning is emitted: after the durable read saw nothing, before the stamp.
  No production control flow is modified to make room for the injection.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration

  alias Platform.Orchestration.{
    LeaseManager,
    TaskRouterSupervisor,
    TaskRouterWatcher
  }

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, PlanEngine}

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  defmodule AckInjector do
    @moduledoc false
    # A `:logger` handler. It runs in the process that logged, so when the
    # router logs its no-ack warning this writes the ack row from inside the
    # router, between the durable-ack read and the block stamp. Fires once.
    def log(%{msg: msg}, %{config: %{marker: marker, once: once, inject: inject}}) do
      text = message_text(msg)

      if String.contains?(text, marker) and :atomics.compare_exchange(once, 1, 0, 1) == :ok do
        inject.()
      end

      :ok
    rescue
      _ -> :ok
    end

    def log(_event, _config), do: :ok

    defp message_text({:string, chardata}), do: IO.chardata_to_string(chardata)

    defp message_text({format, args}) when is_list(args),
      do: IO.chardata_to_string(:io_lib.format(format, args))

    defp message_text(_), do: ""
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})
    start_supervised!(TaskRouterWatcher)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "late_ack_resume_#{n}@example.com",
        name: "Late Ack Resume",
        oidc_sub: "oidc-late-ack-resume-#{n}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "late-ack-agent-#{n}", name: "Late Ack Agent", status: "active"})
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{runtime_id: "late-ack-rt-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)
    Process.put(:late_ack_agent_id, agent.id)

    runtime_id = activated.runtime_id
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

    test_pid = self()
    handler_id = "late-ack-resume-#{n}"

    :ok =
      :telemetry.attach(
        handler_id,
        @suppressed_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dispatch_suppressed, metadata})
        end,
        nil
      )

    {:ok, project} = Tasks.create_project(%{name: "Late Ack Resume #{n}"})

    on_exit(fn ->
      :telemetry.detach(handler_id)
      PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}")
    end)

    %{project: project, agent: agent, runtime_id: runtime_id}
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  # A task whose plan and running stage exist BEFORE it becomes runnable, so
  # the watcher's first router dispatches the stage rather than planning.
  defp build!(ctx, :coding) do
    task = create_task!(ctx)
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    stage1 =
      running_stage!(plan, 1, "Build the feature", "coding — stage 1")

    {:ok, v1} = Tasks.create_validation(%{stage_id: stage1.id, kind: "test_pass"})

    {:ok, stage2} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 2,
        name: "Wire it up",
        description: "coding — stage 2"
      })

    {:ok, _} = Tasks.create_validation(%{stage_id: stage2.id, kind: "test_pass"})

    task = make_runnable!(task, "in_progress")
    %{task: task, plan: plan, stage1: stage1, stage2: stage2, v1: v1}
  end

  defp build!(ctx, :deploy) do
    task = create_task!(ctx)
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    stage = running_stage!(plan, 1, "Deploy: PR merge", "Deploy via PR merge")
    {:ok, pr_merged} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

    task = make_runnable!(task, "deploying")
    %{task: task, plan: plan, stage1: stage, v1: pr_merged}
  end

  defp create_task!(ctx) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: ctx.project.id,
        title: "Late ack resume #{System.unique_integer([:positive])}",
        description: "Pin the late-ack resume path",
        status: "backlog",
        deploy_target: "production"
      })

    on_exit(fn ->
      TaskRouterSupervisor.stop_assignment(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    task
  end

  defp running_stage!(plan, position, name, description) do
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: position,
        name: name,
        description: description,
        status: "running",
        started_at: DateTime.utc_now()
      })

    stage
  end

  # Direct row write (no broadcast), then ONE `{:task_updated, _}` to the
  # watcher, so the router start is a single, awaited event.
  defp make_runnable!(task, status) do
    Repo.update_all(
      from(t in Platform.Tasks.Task, where: t.id == ^task.id),
      set: [assignee_type: "agent", assignee_id: ctx_agent_id!(), status: status]
    )

    row = Repo.get!(Platform.Tasks.Task, task.id)
    send(Process.whereis(TaskRouterWatcher), {:task_updated, row})
    settle!(task.id)
    assert TaskRouterWatcher.router_running?(task.id), "the watcher must start a router"
    row
  end

  defp ctx_agent_id!, do: Process.get(:late_ack_agent_id) || flunk("agent id not set")

  defp settle!(task_id) do
    TaskRouterWatcher.sync()

    safe_sync_router(task_id)

    TaskRouterWatcher.sync()
    :ok
  end

  # `sync_router/1` flunks when the router stops mid-barrier, which is exactly
  # what the watcher does to a task that just went `blocked`. A router that is
  # gone has no mailbox left to drain, so its absence is the barrier.
  defp safe_sync_router(task_id) do
    if TaskRouterWatcher.router_running?(task_id) do
      try do
        sync_router(task_id)
      rescue
        ExUnit.AssertionError -> :ok
      end
    end

    :ok
  end

  # ── observations ───────────────────────────────────────────────────────

  defp dispatch_for?(content, stage) when is_binary(content),
    do: String.contains?(content, ~s(stage_id="#{stage.id}"))

  defp dispatch_for?(_content, _stage), do: false

  # Every stage dispatch for `stage` received within `window_ms`.
  defp collect_dispatches(stage, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    do_collect(stage, deadline, [])
  end

  defp do_collect(stage, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      %Phoenix.Socket.Broadcast{event: "attention", payload: %{message: %{content: content}}} ->
        acc = if dispatch_for?(content, stage), do: [content | acc], else: acc
        do_collect(stage, deadline, acc)
    after
      remaining -> Enum.reverse(acc)
    end
  end

  defp drain_attention do
    receive do
      %Phoenix.Socket.Broadcast{event: "attention"} -> drain_attention()
    after
      0 -> :ok
    end
  end

  defp status(task), do: Tasks.get_task_record(task.id).status

  defp reconciled(task) do
    task.id
    |> PhaseTransitions.list_for_task()
    |> Enum.filter(&(&1.via == "late_ack_reconciled"))
  end

  # ── drivers ────────────────────────────────────────────────────────────

  defp fire_no_ack!(task) do
    [{pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task.id)
    lease = LeaseManager.get(task.id)
    assert lease, "expected a lease from the watcher-started router's dispatch"
    assert lease.no_ack_at, "expected an armed no-ack deadline"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task.id, %{lease | no_ack_at: past}})

    send(pid, :check_no_ack)
    settle!(task.id)
    lease
  end

  defp ack!(task, stage, runtime_id) do
    {:ok, _} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-late-resume-#{System.unique_integer([:positive])}"
        },
        %{runtime_id: runtime_id}
      )

    settle!(task.id)
  end

  # ── tests ──────────────────────────────────────────────────────────────

  describe "RESUME (the 019f9cb8 incident)" do
    test "a late owner ack resumes the task without re-prompting, and the next stage dispatches once",
         ctx do
      f = build!(ctx, :coding)

      assert [_] = collect_dispatches(f.stage1, 2_000),
             "anti-vacuity: the watcher-started router must dispatch stage 1 exactly once"

      lease = fire_no_ack!(f.task)
      assert lease.owner_runtime_id == ctx.runtime_id
      assert status(f.task) == "blocked"
      refute TaskRouterWatcher.router_running?(f.task.id), "the watcher stops a blocked task"
      assert LeaseManager.get(f.task.id) == nil
      drain_attention()

      ack!(f.task, f.stage1, ctx.runtime_id)

      assert status(f.task) == "in_progress"
      assert [_] = reconciled(f.task)
      assert TaskRouterWatcher.router_running?(f.task.id), "the watcher restarts the router"

      # The boot dispatch was WITHHELD for the live acked executor...
      assert_receive {:dispatch_suppressed, %{task_id: task_id, reason: :live_acked_executor}},
                     2_000

      assert task_id == f.task.id
      # ...and nothing re-prompted stage 1.
      assert collect_dispatches(f.stage1, 1_500) == []

      # Liveness is armed again on a live ETS lease for stage 1.
      assert %{stage_id: stage_id, safety_net_at: %DateTime{}} = LeaseManager.get(f.task.id)
      assert stage_id == f.stage1.id

      # Passing stage 1 opens stage 2, which is dispatched exactly once.
      {:ok, _} = PlanEngine.evaluate_validation(f.v1.id, %{status: "passed"})
      settle!(f.task.id)

      assert Repo.get!(Platform.Tasks.Stage, f.stage2.id).status == "running"
      assert [_] = collect_dispatches(f.stage2, 2_000)
    end
  end

  describe "DEPLOY" do
    test "a deploying task blocked by no-ack returns to deploying and reaches done on pr_merged",
         ctx do
      f = build!(ctx, :deploy)
      assert [_] = collect_dispatches(f.stage1, 2_000)

      fire_no_ack!(f.task)
      assert status(f.task) == "blocked"

      assert Tasks.get_task_record(f.task.id).metadata["blocked_cause"]["prior_status"] ==
               "deploying"

      ack!(f.task, f.stage1, ctx.runtime_id)
      assert status(f.task) == "deploying"
      assert [%{to_status: "deploying"}] = reconciled(f.task)

      {:ok, _} = PlanEngine.evaluate_validation(f.v1.id, %{status: "passed"})
      settle!(f.task.id)

      assert status(f.task) == "done"
    end
  end

  describe "RACE" do
    test "an ack that commits between the durable read and the block stamp still resumes",
         ctx do
      f = build!(ctx, :coding)
      assert [_] = collect_dispatches(f.stage1, 2_000)

      task_id = f.task.id
      stage_id = f.stage1.id
      runtime_id = ctx.runtime_id
      injected = :atomics.new(1, [])
      once = :atomics.new(1, [])

      inject = fn ->
        {:ok, _} =
          Orchestration.record_runtime_event(%{
            "task_id" => task_id,
            "phase" => "execution",
            "runtime_id" => runtime_id,
            "event_type" => "execution.acked",
            "payload" => %{
              "stage_id" => stage_id,
              "runtime_id" => runtime_id,
              "subagent_id" => "subagent-race"
            }
          })

        :atomics.put(injected, 1, 1)
      end

      handler = :"late_ack_race_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler, AckInjector, %{
          level: :all,
          config: %{
            marker: "task #{task_id} stage #{stage_id} — no ack after",
            once: once,
            inject: inject
          }
        })

      on_exit(fn -> :logger.remove_handler(handler) end)

      fire_no_ack!(f.task)
      :logger.remove_handler(handler)

      assert :atomics.get(injected, 1) == 1,
             "the injector never ran: the race was not exercised and this test proves nothing"

      assert status(f.task) == "in_progress"
      assert [_] = reconciled(f.task)
      refute Map.has_key?(Tasks.get_task_record(task_id).metadata, "blocked_cause")
    end
  end

  describe "CONTROL" do
    test "with no ack the alarm still bites: blocked, router stopped", ctx do
      f = build!(ctx, :coding)
      assert [_] = collect_dispatches(f.stage1, 2_000)

      fire_no_ack!(f.task)

      assert status(f.task) == "blocked"
      refute TaskRouterWatcher.router_running?(f.task.id)
      assert reconciled(f.task) == []
      assert collect_dispatches(f.stage1, 1_000) == []
    end
  end
end
