defmodule Platform.Orchestration.TaskRouterAckOwnershipTest do
  @moduledoc """
  Task `01a0c762` stage 2: the router's durable-ack readers count ONLY acks
  written by the runtime the stage was dispatched to.

  Stage 1 made `LeaseManager.record_ack/3` refuse a non-owner. That alone left
  two identity-blind Postgres readers able to do the same harm with a durable
  `execution.acked` row any authenticated runtime can write (the
  `RuntimeChannel` `execution_event` handler forces only `runtime_id` to the
  sender's own; `stage_id` is whatever the payload says):

    * `live_acked_executor?/2` withheld a dispatch on ANY runtime's fresh ack,
      so after a reassignment the OLD owner's ack parked the NEW owner.
    * `durable_ack_suppresses_alarm?` silenced the no-ack alarm on ANY
      runtime's ack, and `maybe_fire_no_ack/3` then re-stamped the lease.

  ## Pairing

  Every refutation is paired with a positive control on the same fixture that
  differs only in WHICH runtime wrote the ack. A reader that ignores every ack
  would pass the non-owner half of each pair; the owner half is what fails it.

  Acks are written as real `runtime_events` rows through
  `Orchestration.record_runtime_event/1` (the path `RuntimeChannel` uses), so
  the router's own `apply_runtime_event/2` clause runs on each of them.

  Shared-mode sandbox: the router is a real GenServer reading the Repo.
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @suppressed_event [:platform, :orchestration, :dispatch_suppressed]

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Ack Ownership Project #{n}",
        repo_url: "https://github.com/test/ack-ownership"
      })

    # Real agent -> runtime links: case (c) is a reassignment, which only
    # `PhaseRuntime.resolve/1` can perform, and it needs linked rows to do it.
    {agent_a, runtime_a} = create_linked_agent_runtime("owner-a")
    {agent_b, runtime_b} = create_linked_agent_runtime("other-b")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Ack ownership #{n}",
        description: "Pin runtime-scoped durable ack readers",
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

    # "Build the feature" infers `stage_kind: "coding"`: non-nil ack_ms and
    # safety_net_ms, so both alarms are armed and the withhold window exists.
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
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_b}")
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

    handler_id = "ack-ownership-#{n}"
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

    on_exit(fn ->
      :telemetry.detach(handler_id)
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{
      task: task,
      stage: stage,
      agent_a: agent_a,
      agent_b: agent_b,
      runtime_a: runtime_a,
      runtime_b: runtime_b
    }
  end

  # ── (a) LIVENESS: the safety net ──────────────────────────────────────────

  describe "(a) a non-owner's durable ack does not extend the safety net" do
    test "B's ack leaves the lease byte-identical and the net fires", ctx do
      pid = boot_dispatched_to_a!(ctx)

      expired = expire!(ctx.task.id, :safety_net_at)

      record_ack_event!(ctx.task, ctx.stage, ctx.runtime_b)

      assert LeaseManager.get(ctx.task.id) == expired,
             "a non-owner's execution.acked must not touch the lease at all"

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event,
                       %{event_type: "execution.safety_net_fired", stage_id: fired_stage_id}}

      assert fired_stage_id == ctx.stage.id
    end

    test "CONTROL: A's ack moves the deadline and the net does NOT fire", ctx do
      pid = boot_dispatched_to_a!(ctx)

      expired = expire!(ctx.task.id, :safety_net_at)

      record_ack_event!(ctx.task, ctx.stage, ctx.runtime_a)

      lease = LeaseManager.get(ctx.task.id)

      assert DateTime.compare(lease.safety_net_at, expired.safety_net_at) == :gt,
             "the owner's ack must move safety_net_at, or the refusal above proves nothing"

      assert DateTime.compare(lease.safety_net_at, DateTime.utc_now()) == :gt
      assert lease.ack_runtime_id == ctx.runtime_a

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      refute_received {:runtime_event, %{event_type: "execution.safety_net_fired"}}
    end
  end

  # ── (b) the no-ack alarm ──────────────────────────────────────────────────

  describe "(b) a non-owner's durable ack does not suppress the no-ack alarm" do
    test "B's row exists, is visible to the unscoped reader, and the alarm still fires",
         ctx do
      pid = boot_dispatched_to_a!(ctx)

      record_ack_event!(ctx.task, ctx.stage, ctx.runtime_b)

      # Anti-vacuity: the row IS there, and the pre-stage-2 reader would have
      # counted it. Only the runtime scope separates it from the owner's.
      assert %DateTime{} = Orchestration.last_stage_ack_at(ctx.task.id, ctx.stage.id)

      assert %DateTime{} =
               Orchestration.last_stage_ack_at(ctx.task.id, ctx.stage.id, ctx.runtime_b)

      assert Orchestration.last_stage_ack_at(ctx.task.id, ctx.stage.id, ctx.runtime_a) == nil

      assert %{ack_at: nil, no_ack_fired?: false} = LeaseManager.get(ctx.task.id)
      expire!(ctx.task.id, :no_ack_at)

      send(pid, :check_no_ack)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: true, ack_at: nil} = LeaseManager.get(ctx.task.id)
    end

    test "CONTROL: A's durable ack suppresses the alarm and re-stamps in A's name", ctx do
      pid = boot_dispatched_to_a!(ctx)

      record_ack_event!(ctx.task, ctx.stage, ctx.runtime_a)

      # Forget the ack in ETS, as a review-gate clear or a LeaseManager
      # restart does, so the check has only the durable row to go on. Without
      # this `:check_no_ack` short-circuits on `ack_at` and never reaches the
      # durable reader this pair is about.
      lease = LeaseManager.get(ctx.task.id)
      past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)

      :ets.insert(
        :orchestration_lease_manager,
        {ctx.task.id, %{lease | ack_at: nil, ack_runtime_id: nil, no_ack_at: past}}
      )

      send(pid, :check_no_ack)
      :ok = sync_router(ctx.task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}

      restamped = LeaseManager.get(ctx.task.id)
      assert %DateTime{} = restamped.ack_at
      refute restamped.no_ack_fired?
      assert restamped.ack_runtime_id == ctx.runtime_a
    end
  end

  # ── (c) reassignment ──────────────────────────────────────────────────────

  describe "(c) after a reassignment the old owner's ack withholds nothing" do
    test "CONTROL: with no reassignment, A's fresh ack withholds A's re-dispatch", ctx do
      pid = boot_dispatched_to_a!(ctx)
      ack_via_tool!(ctx.task, ctx.stage, ctx.runtime_a)

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the owner's live ack must withhold its own re-dispatch, or the " <>
                       "reassignment case below is testing a guard that never fires"

      assert_received {:dispatch_suppressed, %{reason: :live_acked_executor}}
    end

    test "A acks, the phase moves to B, and the dispatch reaches B with a fresh lease",
         ctx do
      pid = boot_dispatched_to_a!(ctx)
      ack_via_tool!(ctx.task, ctx.stage, ctx.runtime_a)

      task = Repo.get!(TaskSchema, ctx.task.id)

      {:ok, _reassigned} =
        Tasks.set_phase_assignees(task, %{"execution" => phase_entry(ctx.agent_b)})

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      topic_b = "runtime:#{ctx.runtime_b}"

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", topic: ^topic_b},
                     2_000,
                     "A's ack says nothing about B's pickup; the dispatch to B must not be withheld"

      refute_received {:dispatch_suppressed, %{reason: :live_acked_executor}}

      lease = LeaseManager.get(ctx.task.id)
      assert lease.owner_runtime_id == ctx.runtime_b
      assert lease.ack_at == nil
      assert TaskRouter.current_status(ctx.task.id).assignee.id == ctx.runtime_b
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Boots the router, observes the first dispatch landing on A, and pins that
  # the lease is owned by A with no ack yet. Everything after this varies only
  # the acking runtime.
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
                   "the fixture must dispatch to A before any ack can be judged"

    lease = LeaseManager.get(ctx.task.id)
    assert lease, "expected an armed lease after the first dispatch"
    assert lease.owner_runtime_id == ctx.runtime_a
    assert lease.stage_id == ctx.stage.id
    assert lease.ack_at == nil
    pid
  end

  # The durable row a runtime writes over `RuntimeChannel` `execution_event`:
  # `runtime_id` is the sender, `stage_id` is whatever the payload names.
  defp record_ack_event!(task, stage, runtime_id) do
    {:ok, _event} =
      Orchestration.record_runtime_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => runtime_id,
        "event_type" => "execution.acked",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{
          "stage_id" => stage.id,
          "runtime_id" => runtime_id,
          "subagent_id" => "subagent-#{runtime_id}"
        }
      })

    :ok = sync_router(task.id)
    :ok
  end

  defp ack_via_tool!(task, stage, runtime_id) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-ownership-#{System.unique_integer([:positive])}"
        },
        %{runtime_id: runtime_id}
      )

    :ok = sync_router(task.id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage.id, runtime_id),
           "the tool ack must leave a durable row in the acking runtime's name"

    assert %{ack_at: %DateTime{}, ack_runtime_id: ^runtime_id} = LeaseManager.get(task.id)
    :ok
  end

  defp expire!(task_id, field) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row to expire"
    assert %DateTime{} = Map.fetch!(lease, field), "expected an armed #{field}"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    expired = Map.put(lease, field, past)
    :ets.insert(:orchestration_lease_manager, {task_id, expired})
    expired
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
        email: "ack_ownership_#{n}@example.com",
        name: "Ack Ownership User",
        oidc_sub: "oidc-ack-ownership-#{n}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "ack-#{label}-agent-#{n}",
        name: "Ack #{label} Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{runtime_id: "ack-#{label}-runtime-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end
end
