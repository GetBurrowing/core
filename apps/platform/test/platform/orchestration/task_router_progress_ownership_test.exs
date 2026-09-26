defmodule Platform.Orchestration.TaskRouterProgressOwnershipTest do
  @moduledoc """
  Task `01a0db63` stage 1: the router's progress arm extends the safety net
  ONLY for liveness events from the runtime the stage was dispatched to.

  `apply_runtime_event/2` handles every `{:runtime_event, _}` for the task,
  from any runtime. Its `assignment.accepted | execution.started |
  execution.heartbeat | execution.progress | execution.unblocked` arm called
  `LeaseManager.record_progress/1` with no identity, so a stranger's heartbeat
  bought a dead owner another 90-120 minutes of safety net.

  This file drives EVENTS, not the function: it is the behavioural red that
  `lease_manager_progress_ownership_test.exs` cannot give, because that file
  calls `record_progress/2` directly.

  ## Pairing

  Every refutation is paired with a positive control on the same fixture that
  differs only in WHICH runtime sent the event. A router that ignores every
  event would pass the stranger half; the owner half is what fails it.

  ## Out of scope, deliberately not asserted here

  `maybe_reset_stalled/1` still runs on every event from any runtime (sibling
  ticket 01a0db63-a8e2), and `last_runtime_event_at` is still stamped. Those
  are pinned the other way by `task_router_self_filed_event_hermeticism_test.exs`.

  Shared-mode sandbox: the router is a real GenServer reading the Repo.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @stranger "runtime-stranger-progress"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Progress Ownership Project #{n}",
        repo_url: "https://github.com/test/progress-ownership"
      })

    {agent_a, runtime_a} = create_linked_agent_runtime("owner-a")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Progress ownership #{n}",
        description: "Gate record_progress on the lease owner",
        deploy_target: "production"
      })

    task =
      task
      |> Ecto.Changeset.change(%{
        status: "in_progress",
        assignee_id: agent_a.id,
        assignee_type: "agent",
        phase_assignees: %{
          "planning" => phase_entry(agent_a),
          "execution" => phase_entry(agent_a)
        }
      })
      |> Repo.update!()

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"`: a non-nil
    # safety_net_ms, so the net is armed and a progress write is visible.
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_a}")

    on_exit(fn ->
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{task: task, stage: stage, runtime_a: runtime_a}
  end

  describe "a stranger's execution.heartbeat does not extend the safety net" do
    test "the lease is whole-map unchanged; the owner's heartbeat then moves it", ctx do
      boot_dispatched_to_a!(ctx)
      before = backdate_net!(ctx.task.id)

      broadcast_liveness!(ctx, "execution.heartbeat", @stranger)

      assert LeaseManager.get(ctx.task.id) == before,
             "a stranger's heartbeat must not touch the lease at all"

      # CONTROL: the same event from the owner is accepted.
      broadcast_liveness!(ctx, "execution.heartbeat", ctx.runtime_a)
      assert_extended!(ctx.task.id, before)
    end

    test "a nil runtime_id is a stranger too (fail closed)", ctx do
      boot_dispatched_to_a!(ctx)
      before = backdate_net!(ctx.task.id)

      broadcast_liveness!(ctx, "execution.heartbeat", nil)

      assert LeaseManager.get(ctx.task.id) == before
    end

    test "through the durable path RuntimeChannel uses, too", ctx do
      boot_dispatched_to_a!(ctx)
      before = backdate_net!(ctx.task.id)

      record_liveness_event!(ctx, "execution.heartbeat", @stranger)

      assert LeaseManager.get(ctx.task.id) == before,
             "a stranger's durable heartbeat row must not extend the net"

      record_liveness_event!(ctx, "execution.heartbeat", ctx.runtime_a)
      assert_extended!(ctx.task.id, before)
    end
  end

  describe "a stranger's execution.progress does not extend the safety net" do
    test "the lease is whole-map unchanged; the owner's progress then moves it", ctx do
      boot_dispatched_to_a!(ctx)
      before = backdate_net!(ctx.task.id)

      broadcast_liveness!(ctx, "execution.progress", @stranger)

      assert LeaseManager.get(ctx.task.id) == before,
             "a stranger's execution.progress must not touch the lease at all"

      broadcast_liveness!(ctx, "execution.progress", ctx.runtime_a)
      assert_extended!(ctx.task.id, before)
    end
  end

  describe "a refused progress event is not treated as liveness" do
    # Mirrors task 01a0c762 stage 2 for the ack arm: a refused event is not
    # evidence anyone is working the stage, so the arm returns `base_state`
    # and does not run its `:running` flip. `:dispatching` is used because
    # it is neither `:running` (flip invisible) nor `:stalled`
    # (`maybe_reset_stalled/1`, sibling scope, flips it first).
    test "a stranger's heartbeat leaves :dispatching alone; the owner's flips it", ctx do
      pid = boot_dispatched_to_a!(ctx)

      :sys.replace_state(pid, fn state -> %{state | status: :dispatching} end)

      broadcast_liveness!(ctx, "execution.heartbeat", @stranger)
      assert TaskRouter.current_status(ctx.task.id).status == :dispatching

      broadcast_liveness!(ctx, "execution.heartbeat", ctx.runtime_a)
      assert TaskRouter.current_status(ctx.task.id).status == :running
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp boot_dispatched_to_a!(ctx) do
    {:ok, pid} =
      TaskRouter.start_link(
        task_id: ctx.task.id,
        assignee: %{type: :federated, id: ctx.runtime_a}
      )

    :ok = sync_router(ctx.task.id)

    topic_a = "runtime:#{ctx.runtime_a}"

    assert_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^topic_a},
                   2_000,
                   "the fixture must dispatch to A before any progress can be judged"

    lease = LeaseManager.get(ctx.task.id)
    assert lease, "expected an armed lease after the first dispatch"
    assert lease.owner_runtime_id == ctx.runtime_a
    assert lease.stage_id == ctx.stage.id
    assert lease.last_progress_at == nil
    pid
  end

  # Moves the armed net into the past so ANY progress write is unmistakable.
  defp backdate_net!(task_id) do
    lease = LeaseManager.get(task_id)
    assert %DateTime{} = lease.safety_net_at, "expected an armed safety net"

    backdated = %{lease | safety_net_at: DateTime.add(DateTime.utc_now(), -1_000, :millisecond)}
    :ets.insert(:orchestration_lease_manager, {task_id, backdated})
    backdated
  end

  defp assert_extended!(task_id, before) do
    lease = LeaseManager.get(task_id)

    assert DateTime.compare(lease.safety_net_at, before.safety_net_at) == :gt,
           "the owner's liveness must move safety_net_at, or the refusal above proves nothing"

    assert DateTime.compare(lease.safety_net_at, DateTime.utc_now()) == :gt
    assert %DateTime{} = lease.last_progress_at
  end

  # The shape `RuntimeSupervision` broadcasts and the router consumes.
  defp broadcast_liveness!(ctx, event_type, runtime_id) do
    Tasks.broadcast_board(
      {:runtime_event,
       %{
         id: nil,
         task_id: ctx.task.id,
         stage_id: ctx.stage.id,
         event_type: event_type,
         payload: %{"stage_id" => ctx.stage.id},
         occurred_at: DateTime.utc_now(),
         runtime_id: runtime_id,
         phase: "execution",
         lease: nil
       }}
    )

    :ok = sync_router(ctx.task.id)
  end

  defp record_liveness_event!(ctx, event_type, runtime_id) do
    {:ok, _event} =
      Orchestration.record_runtime_event(%{
        "task_id" => ctx.task.id,
        "phase" => "execution",
        "runtime_id" => runtime_id,
        "event_type" => event_type,
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{"stage_id" => ctx.stage.id}
      })

    :ok = sync_router(ctx.task.id)
  end

  defp stop_router(task_id) do
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

  defp phase_entry(%Agent{} = agent) do
    %{"assignee_id" => agent.id, "assignee_type" => "agent"}
  end

  defp create_linked_agent_runtime(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "progress_ownership_#{n}@example.com",
        name: "Progress Ownership User",
        oidc_sub: "oidc-progress-ownership-#{n}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "progress-#{label}-agent-#{n}",
        name: "Progress #{label} Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{runtime_id: "progress-#{label}-runtime-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end
end
