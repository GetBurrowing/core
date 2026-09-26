defmodule Platform.Orchestration.TaskRouterTerminalOwnershipTest do
  @moduledoc """
  Task `01a0dd2c` stage 2: the router's terminal-event arms clear the lease
  ONLY for events from the runtime the stage was dispatched to.

  `apply_runtime_event/2` handles every `{:runtime_event, _}` for the task,
  from any runtime. Its `execution.finished` arm and its
  `execution.failed | execution.abandoned | assignment.rejected` arm called
  `clear_liveness/1` — an unconditional `LeaseManager.clear/1` — so a
  stranger's terminal event deleted the owner's lease, and with the row gone
  `:check_no_ack` and `:check_safety_net` both return early: the owner's
  alarms go silent. The realistic trigger is openclaw's `finishOtherPhases`,
  which sends `execution.finished` for the OLD phase after the task has been
  re-dispatched to a different runtime.

  Both arms now go through `LeaseManager.clear_if_owner/2` (stage 1). On
  `:not_owner` the arm logs both runtime ids and returns `base_state`: no
  clear, no "Runtime failure detected" post, no status change.

  ## Pairing

  Every refutation is paired with a positive control on the same fixture that
  differs only in WHICH runtime sent the event. A router that ignores every
  terminal event would pass the stranger half; the owner half fails it.

  ## Known leftovers, deliberately NOT asserted here

  * `maybe_reset_stalled/1` and the `last_runtime_event_at` stamp still run on
    every event from any runtime (01a0db63-a8e2, closed unneeded). They are
    pinned the other way by `task_router_self_filed_event_hermeticism_test.exs`.
  * A failed-family event from a stranger when there is NO lease row
    (`{:error, :not_found}`) still posts the failure log and sets `:stalled`;
    there was nothing to protect, and nothing reads `:stalled`.
  * The OWNER's late `execution.finished` for an old phase still clears its
    own new-phase lease: the gate is by identity, not by stage.
  * RuntimeSupervision's own "Runtime X finished execution" post and the
    durable runtime_events row still appear for a stranger (01a0db63-c4f3).

  Shared-mode sandbox: the router is a real GenServer reading the Repo.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  @stranger "runtime-stranger-terminal"
  @failure_marker "Runtime failure detected"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Terminal Ownership Project #{n}",
        repo_url: "https://github.com/test/terminal-ownership"
      })

    {agent_a, runtime_a} = create_linked_agent_runtime("owner-a")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Terminal ownership #{n}",
        description: "Gate terminal-event lease clears on the lease owner",
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

    # "Build the feature" infers `stage_kind: "coding"`: both timers armed.
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
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

    on_exit(fn ->
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{task: task, plan: plan, stage: stage, runtime_a: runtime_a}
  end

  # ── execution.finished ────────────────────────────────────────────────────

  describe "a stranger's execution.finished does not clear the owner's lease" do
    test "lease whole-map unchanged and :dispatching kept; the owner's then clears and flips",
         ctx do
      pid = boot_dispatched_to_a!(ctx)
      :sys.replace_state(pid, fn state -> %{state | status: :dispatching} end)
      before = LeaseManager.get(ctx.task.id)

      log =
        capture_log(fn ->
          broadcast_event!(ctx, "execution.finished", @stranger)
        end)

      assert LeaseManager.get(ctx.task.id) == before,
             "a stranger's execution.finished must not touch the lease at all"

      assert TaskRouter.current_status(ctx.task.id).status == :dispatching

      assert log =~ "execution.finished from runtime #{inspect(@stranger)} refused"
      assert log =~ inspect(ctx.runtime_a)

      # CONTROL: the same event from the owner clears the lease and flips.
      broadcast_event!(ctx, "execution.finished", ctx.runtime_a)

      assert LeaseManager.get(ctx.task.id) == nil,
             "the owner's execution.finished must clear the lease, or the refusal proves nothing"

      assert TaskRouter.current_status(ctx.task.id).status == :running
    end

    test "a nil runtime_id is a stranger too (fail closed)", ctx do
      boot_dispatched_to_a!(ctx)
      before = LeaseManager.get(ctx.task.id)

      broadcast_event!(ctx, "execution.finished", nil)

      assert LeaseManager.get(ctx.task.id) == before

      broadcast_event!(ctx, "execution.finished", ctx.runtime_a)
      assert LeaseManager.get(ctx.task.id) == nil
    end

    test "through the durable path RuntimeChannel uses, too", ctx do
      boot_dispatched_to_a!(ctx)
      before = LeaseManager.get(ctx.task.id)

      record_event!(ctx, "execution.finished", @stranger)

      assert LeaseManager.get(ctx.task.id) == before,
             "a stranger's durable execution.finished row must not clear the lease"

      record_event!(ctx, "execution.finished", ctx.runtime_a)
      assert LeaseManager.get(ctx.task.id) == nil
    end
  end

  # ── the failed family ─────────────────────────────────────────────────────

  for type <- ["execution.failed", "execution.abandoned", "assignment.rejected"] do
    describe "a stranger's #{type} does not clear the owner's lease" do
      @event_type type

      test "lease, status and execution space unchanged; the owner's clears, stalls and posts",
           ctx do
        pid = boot_dispatched_to_a!(ctx)
        :sys.replace_state(pid, fn state -> %{state | status: :dispatching} end)
        space = ExecutionSpace.find_by_task_id(ctx.task.id)
        assert space, "the fixture needs an execution space to observe the failure log"
        before = LeaseManager.get(ctx.task.id)

        log = capture_log(fn -> broadcast_event!(ctx, @event_type, @stranger) end)

        assert LeaseManager.get(ctx.task.id) == before,
               "a stranger's #{@event_type} must not touch the lease at all"

        assert TaskRouter.current_status(ctx.task.id).status == :dispatching

        assert failure_lines(space.id) == [],
               "a stranger's #{@event_type} must not post a runtime-failure log"

        assert log =~ "#{@event_type} from runtime #{inspect(@stranger)} refused"
        assert log =~ inspect(ctx.runtime_a)

        # CONTROL: the owner's event clears, stalls and posts exactly one line.
        broadcast_event!(ctx, @event_type, ctx.runtime_a)

        assert LeaseManager.get(ctx.task.id) == nil
        assert TaskRouter.current_status(ctx.task.id).status == :stalled

        lines = failure_lines(space.id)
        assert length(lines) == 1, "expected one failure line, got #{inspect(lines)}"
        assert hd(lines) =~ "event=#{@event_type}"
      end
    end
  end

  # ── the effect the ticket names: the owner's alarm still fires ────────────

  describe "the owner's no-ack alarm survives a stranger's execution.finished" do
    test "a refused stranger finished leaves the alarm armed, and it fires", ctx do
      pid = boot_dispatched_to_a!(ctx)

      broadcast_event!(ctx, "execution.finished", @stranger)
      assert %{ack_at: nil, no_ack_fired?: false} = LeaseManager.get(ctx.task.id)

      expire!(ctx.task.id, :no_ack_at)
      send(pid, :check_no_ack)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
      assert %{no_ack_fired?: true} = LeaseManager.get(ctx.task.id)
    end

    test "CONTROL: after the owner's finished the row is gone and the alarm cannot fire",
         ctx do
      pid = boot_dispatched_to_a!(ctx)
      expire!(ctx.task.id, :no_ack_at)

      broadcast_event!(ctx, "execution.finished", ctx.runtime_a)
      assert LeaseManager.get(ctx.task.id) == nil

      send(pid, :check_no_ack)
      :ok = sync_router(ctx.task.id)

      refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
    end
  end

  # ── the router-internal path is not gated ─────────────────────────────────

  describe "a stage transition still clears the lease unconditionally" do
    test "after a refused stranger finished, the boundary crossing drops stage 1's lease",
         ctx do
      pid = boot_dispatched_to_a!(ctx)

      broadcast_event!(ctx, "execution.finished", @stranger)
      assert %{stage_id: stage_1_id} = LeaseManager.get(ctx.task.id)
      assert stage_1_id == ctx.stage.id

      {:ok, stage_2} =
        Tasks.create_stage(%{
          plan_id: ctx.plan.id,
          position: 2,
          name: "Build the second feature",
          description: "coding — stage 2",
          status: "running",
          started_at: DateTime.utc_now()
        })

      passed =
        ctx.stage
        |> Ecto.Changeset.change(%{status: "passed", completed_at: DateTime.utc_now()})
        |> Repo.update!()

      send(pid, {:stage_transitioned, passed})
      :ok = sync_router(ctx.task.id)

      assert TaskRouter.current_status(ctx.task.id).current_stage_id == stage_2.id

      case LeaseManager.get(ctx.task.id) do
        nil -> :ok
        lease -> assert lease.stage_id == stage_2.id, "stage 1's lease survived the transition"
      end
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
                   "the fixture must dispatch to A before any terminal event can be judged"

    lease = LeaseManager.get(ctx.task.id)
    assert lease, "expected an armed lease after the first dispatch"
    assert lease.owner_runtime_id == ctx.runtime_a
    assert lease.stage_id == ctx.stage.id
    pid
  end

  defp expire!(task_id, field) do
    lease = LeaseManager.get(task_id)
    assert %DateTime{} = Map.fetch!(lease, field), "expected an armed #{field}"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    expired = Map.put(lease, field, past)
    :ets.insert(:orchestration_lease_manager, {task_id, expired})
    expired
  end

  defp failure_lines(space_id) do
    space_id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.map(& &1.content)
    |> Enum.filter(&String.contains?(&1 || "", @failure_marker))
  end

  # The shape `RuntimeSupervision` broadcasts and the router consumes.
  defp broadcast_event!(ctx, event_type, runtime_id) do
    Tasks.broadcast_board(
      {:runtime_event,
       %{
         id: nil,
         task_id: ctx.task.id,
         stage_id: ctx.stage.id,
         event_type: event_type,
         payload: %{"stage_id" => ctx.stage.id, "error" => "x"},
         occurred_at: DateTime.utc_now(),
         runtime_id: runtime_id,
         phase: "execution",
         lease: nil
       }}
    )

    :ok = sync_router(ctx.task.id)
  end

  defp record_event!(ctx, event_type, runtime_id) do
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
        email: "terminal_ownership_#{n}@example.com",
        name: "Terminal Ownership User",
        oidc_sub: "oidc-terminal-ownership-#{n}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "terminal-#{label}-agent-#{n}",
        name: "Terminal #{label} Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{runtime_id: "terminal-#{label}-runtime-#{n}"})

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end
end
