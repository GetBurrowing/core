defmodule Platform.Orchestration.TaskRouterDeliveredButOpenHoldTest do
  @moduledoc """
  A task stamped `delivered_but_open` is NOT re-dispatched, however the
  dispatch is injected (task 01a0665e stage 1).

  Same harness as `TaskRouterNeedsHumanHoldTest` ("a held stage is NOT
  re-dispatched, however the dispatch is injected"), with the watcher started
  per-case so the third injector — `{:runtime_reconnected, id}` — is the real
  watcher path (`redispatch_for_runtime/1`) and not a hand-delivered
  `:dispatch` wearing its name.

  ## Anti-vacuity

    * CONTROL: the same task without the stamp dispatches on every one of
      the three injectors. A suppression that swallowed all re-dispatch would
      satisfy the headline assertion and be strictly worse than the bug.
    * The hold is LOUD but not repetitive: exactly one router notice across
      three injections (the 01a048fe pile-up is the opposite failure).
    * The stamp survives the drag workaround's intermediate `in_progress`
      stop (01a0554f sat 7 s there on 2026-09-03 and dispatched) and clears
      on `done`.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks

  @pr_url "https://github.com/test/dbo-hold/pull/883"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    # Per-case watcher (config `:start_task_router_watcher` is false in test),
    # started after the shared-mode switch for the reason documented in
    # `TaskRouterWatcherTest`.
    start_supervised!(TaskRouterWatcher)

    previous_debounce = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
    Application.put_env(:platform, :task_router_dispatch_debounce_ms, 1)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Delivered-but-open hold #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/dbo-hold"
      })

    {agent, runtime_id} = create_linked_agent_runtime()

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Shipped while planning",
        description: "PR merged, task never closed"
      })

    # `planning` with an agent assignee: the 01a0554f shape, and what
    # `list_should_run_tasks/0` needs to return the row for the reconnect
    # injector. Written directly so no `{:task_updated}` broadcast reaches
    # the watcher before the router below is started by hand.
    task =
      task
      |> Ecto.Changeset.change(%{
        status: "planning",
        assignee_id: agent.id,
        assignee_type: "agent"
      })
      |> Repo.update!()

    # An approved plan so the drag workaround (`planning -> in_progress ->
    # done`) clears `require_approved_plan_for/3` in the clearing test.
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage one",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

    on_exit(fn ->
      if previous_debounce do
        Application.put_env(:platform, :task_router_dispatch_debounce_ms, previous_debounce)
      else
        Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
      end

      stop_router_if_running(task.id)
      LeaseManager.clear(task.id)
    end)

    %{task: task, runtime_id: runtime_id, agent: agent}
  end

  describe "dispatch" do
    test "a stamped task is NOT re-dispatched, however the dispatch is injected", ctx do
      pid = boot_and_drain!(ctx)
      attach_suppression_telemetry!()

      stamp!(ctx.task)
      :ok = sync_router(ctx.task.id)

      inject_all_three!(pid, ctx)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human

      # Positive traces of the hold, not just the absence of a prompt: the
      # guard named itself, and the liveness row the boot dispatch armed is
      # gone (a no-ack alarm against a parked task is 01a0554f's other half).
      task_id = ctx.task.id

      assert_received {:dispatch_suppressed, %{task_id: ^task_id, reason: :delivered_but_open}}

      refute LeaseManager.get(ctx.task.id)

      # One hold, one notice, three injectors.
      assert router_notices(ctx.task.id) == 1
    end

    test "CONTROL: the same task without the stamp IS dispatched by every injector", ctx do
      pid = boot_and_drain!(ctx)
      refute Tasks.delivered_but_open?(Tasks.get_task_record(ctx.task.id))

      # The mailbox is flushed before each injector so every `assert_receive`
      # is attributable to THAT injector and not to a leftover from the one
      # before — otherwise a reconnect that never reached the router would
      # pass on `force_dispatch/1`'s broadcast.
      flush_attention()
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      flush_attention()
      :ok = TaskRouterWatcher.force_dispatch(ctx.task.id)
      :ok = sync_router(ctx.task.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      flush_attention()
      reconnect!(ctx)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the reconnect injector did not reach the router — the hold test's " <>
                       "third injection would be vacuous"

      assert router_notices(ctx.task.id) == 0
    end
  end

  describe "clearing" do
    test "the stamp survives the in_progress stop of the drag workaround and clears on done",
         ctx do
      pid = boot_and_drain!(ctx)
      stamp!(ctx.task)
      :ok = sync_router(ctx.task.id)

      user = create_user()
      task = Tasks.get_task_record(ctx.task.id)

      {:ok, in_progress} = Tasks.transition_task(task, "in_progress", {:user, user.id})
      assert in_progress.status == "in_progress"

      assert in_progress.metadata["delivered_but_open"]["pr_url"] == @pr_url,
             "the intermediate in_progress stop must keep the stamp — it dispatched from " <>
               "exactly there on 2026-09-03"

      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human

      {:ok, done} = Tasks.transition_task(in_progress, "done", {:user, user.id})
      assert done.status == "done"

      reloaded = Tasks.get_task_record(ctx.task.id)
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open")
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open_at")
      assert Tasks.needs_human_action_reason(reloaded, 0) == nil
    end
  end

  # ── The board exit without a plan (task 01a0665e stage 4) ───────────────
  #
  # The stamp exists for the 01a0554f shape — `planning`, an agent assignee,
  # NO plan — and the router's notice tells the person to drag the task to
  # in_progress and then to done. That drag was refused on 01a06b25-3ac3
  # (2026-09-04): `require_approved_plan_for/3` fails `current_plan/1`, and
  # the sponsor bypass needs a non-agent assignment. The stamp is the proof
  # the plan is moot, for a HUMAN actor; the refusal stands for everyone
  # else and for every unstamped task.
  describe "the board exit without a plan" do
    test "a stamped, agent-assigned task with no plan drags to in_progress then done", ctx do
      task = planless_task!(ctx)
      pid = boot_router!(task, ctx)

      stamp!(task)
      :ok = sync_router(task.id)

      user = create_user()

      assert {:ok, in_progress} =
               Tasks.drop_task_to_column(
                 Tasks.get_task_record(task.id),
                 "in_progress",
                 {:user, user.id}
               )

      assert in_progress.status == "in_progress"
      assert in_progress.metadata["delivered_but_open"]["pr_url"] == @pr_url

      # The intermediate stop still holds: no prompt, and the router says so.
      :ok = sync_router(task.id)
      send(pid, :dispatch)
      :ok = sync_router(task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(task.id).status == :waiting_human

      assert {:ok, done} = Tasks.drop_task_to_column(in_progress, "done", {:user, user.id})
      assert done.status == "done"

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "done"
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open")
      refute Map.has_key?(reloaded.metadata || %{}, "delivered_but_open_at")
      assert Tasks.needs_human_action_reason(reloaded, 0) == nil
    end

    test "CONTROL: the same drag on an unstamped task is now open to a person, still refused to automation",
         ctx do
      task = planless_task!(ctx)
      refute Tasks.delivered_but_open?(task)
      user = create_user()

      # Task 01a18e02 flipped these two deliberately: humans are never
      # blocked by the plan gate, so a person moves an unstamped, planless,
      # agent-assigned task too. Each move runs on its own fresh task so the
      # automation refusal below still starts from `planning`.
      assert {:ok, %{status: "in_progress"}} =
               Tasks.drop_task_to_column(planless_task!(ctx), "in_progress", {:user, user.id})

      assert {:ok, %{status: "in_progress"}} =
               Tasks.transition_task(planless_task!(ctx), "in_progress", {:user, user.id})

      # Stamped, but moved by nobody: the gate exists so an agent cannot
      # close its own work, and a stamp does not change who is asking.
      stamped = stamp!(task)
      assert {:error, :no_approved_plan} = Tasks.drop_task_to_column(stamped, "in_progress")

      assert {:error, :no_approved_plan} =
               Tasks.transition_task(stamped, "in_progress", {:agent, ctx.agent.id})

      assert Tasks.get_task_record(task.id).status == "planning"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # The 01a0554f shape: `planning`, agent-assigned, and NO plan row at all —
  # the setup task carries an approved plan, which is exactly what this
  # describe must not have.
  defp planless_task!(ctx) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: ctx.task.project_id,
        title: "Shipped while planning, never planned",
        description: "PR merged, no plan, task never closed"
      })

    task =
      task
      |> Ecto.Changeset.change(%{
        status: "planning",
        assignee_id: ctx.agent.id,
        assignee_type: "agent"
      })
      |> Repo.update!()

    refute Tasks.current_plan(task.id)

    on_exit(fn ->
      stop_router_if_running(task.id)
      LeaseManager.clear(task.id)
    end)

    task
  end

  defp boot_router!(task, ctx) do
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")

    {:ok, pid} =
      TaskRouter.start_link(
        task_id: task.id,
        assignee: %{type: :federated, id: ctx.runtime_id}
      )

    :ok = sync_router(task.id)
    # The boot (planning) dispatch, consumed so the assertions below are
    # about what happens AFTER the stamp.
    assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
    pid
  end

  defp stamp!(task) do
    {:ok, stamped} =
      Tasks.stamp_delivered_but_open(task.id, %{
        "pr_url" => @pr_url,
        "pr_number" => 883,
        "merge_commit_sha" => "66d8ecb7",
        "merged_at" => "2026-08-31T10:00:00Z",
        "head_branch" => "task/#{task.id}",
        "delivering_repo" => "test/dbo-hold"
      })

    assert stamped.metadata["delivered_but_open"]["merge_commit_sha"] == "66d8ecb7"
    stamped
  end

  # Three separate injectors: a raw `:dispatch`, the watcher's
  # `force_dispatch/1`, and a runtime reconnect through the watcher's own
  # lease filter. All of them land in `do_dispatch/3`.
  defp inject_all_three!(pid, ctx) do
    send(pid, :dispatch)
    :ok = sync_router(ctx.task.id)

    :ok = TaskRouterWatcher.force_dispatch(ctx.task.id)
    :ok = sync_router(ctx.task.id)

    reconnect!(ctx)
  end

  defp flush_attention do
    receive do
      %Phoenix.Socket.Broadcast{event: "attention"} -> flush_attention()
    after
      0 -> :ok
    end
  end

  defp reconnect!(ctx) do
    watcher = Process.whereis(TaskRouterWatcher)
    assert watcher != nil, "TaskRouterWatcher should be running"

    send(watcher, {:runtime_reconnected, ctx.runtime_id})
    TaskRouterWatcher.sync()
    :ok = sync_router(ctx.task.id)
  end

  # Linked to the test, as in `TaskRouterNeedsHumanHoldTest`, rather than
  # started under `TaskRouterSupervisor`: a router that dies mid-query when
  # the previous test's sandbox owner exits would otherwise be restarted by
  # the DynamicSupervisor until it trips `max_restarts`, which then takes the
  # NEXT test's router down with a `:shutdown` (observed: the second test in
  # this file failed under both seeds tried, at its first barrier). The
  # watcher's injectors find the router through the Registry either way.
  defp boot_and_drain!(ctx) do
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")

    {:ok, pid} =
      TaskRouter.start_link(
        task_id: ctx.task.id,
        assignee: %{type: :federated, id: ctx.runtime_id}
      )

    :ok = sync_router(ctx.task.id)

    # The boot dispatch. Consumed here so every later assertion is about a
    # RE-dispatch.
    assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
    pid
  end

  defp attach_suppression_telemetry! do
    test_pid = self()
    handler_id = "dbo-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :orchestration, :dispatch_suppressed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:dispatch_suppressed, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Router notices only — the stamp itself posts a separate engagement
  # ("The router will not dispatch it again"); the router's hold notice says
  # "Dispatch is parked".
  defp router_notices(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        0

      space ->
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.count(&String.contains?(&1.content, "Dispatch is parked"))
    end
  end

  defp stop_router_if_running(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "dbo_hold_#{System.unique_integer([:positive])}@example.com",
      name: "Delivered-but-open Test User",
      oidc_sub: "oidc-dbo-hold-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "dbo-hold-agent-#{System.unique_integer([:positive])}",
        name: "Delivered-but-open Test Agent",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # An agent linked to its own activated runtime — the only shape
  # `PhaseRuntime.resolve/1` can follow all the way to a runtime id, which is
  # what makes the reconnect injector reach this task at all.
  defp create_linked_agent_runtime do
    user = create_user()
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "dbo-hold-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end
end
