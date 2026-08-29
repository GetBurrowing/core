defmodule Platform.Orchestration.TaskRouterNeedsHumanHoldTest do
  @moduledoc """
  `report_blocker(needs_human: true)` must hold the stage instead of decaying
  into a re-dispatch loop (task 01a04a8c).

  ## The quantity under test, measured rather than assumed

  The hold is not a router flag — it is the `expires_at` on the
  `execution_leases` row, because that column is what
  `TaskRouterWatcher.active_lease_present?/2` reads before it re-pokes a
  router on `{:runtime_reconnected, _}`. So every fixture here files its
  blocker with an `occurred_at` **twenty minutes in the past**: past the
  15-minute execution-phase liveness TTL, and nowhere near the
  `needs_human` horizon. A fixture that filed the blocker "now" would pass
  against the unfixed code, which is exactly the trap the ticket names —
  the decay is the bug, so the moment of blocking proves nothing.

  ## Anti-vacuity: three controls, not one

  Suppressing all re-dispatch would satisfy the headline assertion and be
  strictly worse than the bug, so every refutation here is paired:

    * `needs_human: false` on the SAME stage, at the SAME age, must still
      expire and still re-dispatch. This is the one-field control.
    * A stage whose executor really is gone — dispatched, acked, no
      progress, no blocker at all — must still trip the safety net. This is
      the control the ticket calls the failure mode that matters most,
      because it would stay invisible until something actually died.
    * The hold must be LOUD. A silent hold is a task sitting still while
      looking healthy (task 01a04333), which is a different defect, not a
      fix. Asserted as a notice, a durable board stamp, and a reminder that
      escalates its wording — and, against the opposite failure, as exactly
      ONE notice across repeated dispatch attempts (task 01a048fe).
  """

  use Platform.DataCase, async: false

  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  # Older than the 15-minute execution-phase liveness TTL, younger than the
  # `needs_human` horizon. One number, used by every fixture, so the two
  # branches differ in the flag and in nothing else.
  @blocker_age_minutes 20

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Needs-human hold #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Needs-human hold",
        description: "Pin the needs_human lease contract"
      })

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

    runtime_id = "runtime-needs-human-#{System.unique_integer([:positive])}"
    assignee = %{type: :federated, id: runtime_id}

    # The debounce is a real 50ms timer; a test that did not shorten it would
    # have to sleep on it to tell "withheld" from "not yet sent".
    previous_debounce = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
    Application.put_env(:platform, :task_router_dispatch_debounce_ms, 1)

    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    on_exit(fn ->
      if previous_debounce do
        Application.put_env(:platform, :task_router_dispatch_debounce_ms, previous_debounce)
      else
        Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
      end

      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      LeaseManager.clear(task.id)
    end)

    %{task: task, plan: plan, stage: stage, assignee: assignee, runtime_id: runtime_id}
  end

  describe "the lease horizon" do
    test "a needs_human blocker outlives the liveness TTL; a plain one does not", ctx do
      hold = file_blocker!(ctx, true)
      assert hold.status == "blocked"

      # MEASURED, not asserted from the constant: the row's own expiry must
      # still be in the future twenty minutes after the blocker was filed.
      assert DateTime.compare(hold.expires_at, DateTime.utc_now()) == :gt

      assert %ExecutionLease{} =
               RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      # The exact read `TaskRouterWatcher.active_lease_present?/2` makes on a
      # runtime reconnect. Non-nil here is what keeps the reconnect path from
      # re-poking the router at all.
      assert %ExecutionLease{} =
               RuntimeSupervision.current_lease_for_task_runtime(ctx.task.id, ctx.runtime_id)
    end

    test "CONTROL: needs_human:false at the same age has already expired", ctx do
      lease = file_blocker!(ctx, false)

      assert lease.status == "blocked"
      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :lt

      refute RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)
      refute RuntimeSupervision.current_lease_for_task_runtime(ctx.task.id, ctx.runtime_id)
    end

    test "a blocker naming no stage cannot hold a stage", ctx do
      # `needs_human` with `stage_id: nil` is the router's own self-filed
      # shape (`record_unresolved_stage_blocker/4`). It must not extend, and
      # it must not gate anyone's dispatch.
      {:ok, _event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => ctx.task.id,
          "phase" => "execution",
          "runtime_id" => ctx.runtime_id,
          "event_type" => "execution.blocked",
          "occurred_at" => minutes_ago(@blocker_age_minutes),
          "payload" => %{
            "stage_id" => nil,
            "description" => "stageless",
            "needs_human" => true
          }
        })

      refute RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)
      refute RuntimeSupervision.current_lease_for_task_runtime(ctx.task.id, ctx.runtime_id)
    end
  end

  describe "dispatch" do
    test "a held stage is NOT re-dispatched, however the dispatch is injected", ctx do
      pid = boot_and_drain!(ctx)

      _hold = file_blocker!(ctx, true)
      :ok = sync_router(ctx.task.id)

      # Three separate injectors, all of which bypass the watcher's
      # lease filter and land straight in the handler.
      send(pid, :dispatch)
      send(pid, :dispatch_boot)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human
    end

    test "CONTROL: the same stage with needs_human:false IS re-dispatched", ctx do
      pid = boot_and_drain!(ctx)

      _lease = file_blocker!(ctx, false)
      :ok = sync_router(ctx.task.id)

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
    end

    test "the hold releases and dispatch resumes once the blocker is gone", ctx do
      pid = boot_and_drain!(ctx)

      _hold = file_blocker!(ctx, true)
      :ok = sync_router(ctx.task.id)

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # What a stage transition does. The suppression must not outlive it.
      RuntimeSupervision.drop_leases_for_stage(ctx.task.id, ctx.stage.id)

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      refute Tasks.get_task_record(ctx.task.id).metadata["awaiting_human_action"]
    end
  end

  describe "the hold is loud" do
    test "one notice, a durable stamp, and no pile-up across repeated dispatches", ctx do
      pid = boot_and_drain!(ctx)

      _hold = file_blocker!(ctx, true)
      :ok = sync_router(ctx.task.id)

      assert awaiting_notices(ctx.task.id) == 1

      for _ <- 1..4, do: send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      # An unchanged verdict re-announced per injector is the 01a048fe
      # failure mode. One hold, one entry notice.
      assert awaiting_notices(ctx.task.id) == 1

      reloaded = Tasks.get_task_record(ctx.task.id)
      assert reloaded.metadata["awaiting_human_action"] == "blocker"
      assert is_binary(reloaded.metadata["awaiting_human_action_at"])
    end

    test "the reminder re-announces with escalated wording and still does not dispatch", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, 7 * 60)
      :ok = sync_router(ctx.task.id)

      send(pid, {:awaiting_human_reminder, hold.id})
      :ok = sync_router(ctx.task.id)

      assert awaiting_notices(ctx.task.id) == 2
      assert Enum.any?(execution_messages(ctx.task.id), &String.contains?(&1, "OVERDUE"))
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
    end

    test "an orphan reminder for a hold that has ended releases instead of narrating", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true)
      :ok = sync_router(ctx.task.id)
      assert awaiting_notices(ctx.task.id) == 1

      RuntimeSupervision.drop_leases_for_stage(ctx.task.id, ctx.stage.id)

      send(pid, {:awaiting_human_reminder, hold.id})
      :ok = sync_router(ctx.task.id)

      assert awaiting_notices(ctx.task.id) == 1
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
    end
  end

  describe "the safety net still catches a dead executor" do
    test "CONTROL: no blocker at all, acked, no progress — the alert still fires", ctx do
      _pid = boot_and_drain!(ctx)
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      # A genuinely dead executor: it acked the dispatch and then stopped
      # existing. Nothing filed a blocker, so nothing may hold it.
      refute RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      expire_safety_net_deadline!(ctx.task.id)
      send_to_router(ctx.task.id, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_receive {:runtime_event, %{event_type: "execution.safety_net_fired"}}, 1_000
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp file_blocker!(ctx, needs_human, age_minutes \\ @blocker_age_minutes) do
    {:ok, _event} =
      Platform.Orchestration.record_runtime_event(%{
        "task_id" => ctx.task.id,
        "phase" => "execution",
        "runtime_id" => ctx.runtime_id,
        "event_type" => "execution.blocked",
        "occurred_at" => minutes_ago(age_minutes),
        "payload" => %{
          "stage_id" => ctx.stage.id,
          "description" => "The premise is invalidated; a person must rule on it.",
          "needs_human" => needs_human,
          "reported_by" => "agent"
        }
      })

    Repo.one(
      from(l in ExecutionLease,
        where: l.task_id == ^ctx.task.id,
        order_by: [desc: l.inserted_at],
        limit: 1
      )
    )
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp boot_and_drain!(ctx) do
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")
    {:ok, pid} = TaskRouter.start_link(task_id: ctx.task.id, assignee: ctx.assignee)
    :ok = sync_router(ctx.task.id)

    # The boot dispatch. Consumed here so every later assertion is about a
    # RE-dispatch, which is the thing this file is about.
    assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
    pid
  end

  defp send_to_router(task_id, msg) do
    [{pid, _}] = Registry.lookup(Platform.Orchestration.Registry, task_id)
    send(pid, msg)
  end

  defp expire_safety_net_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row armed by the boot dispatch"
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    refute lease.safety_net_fired?, "expected the one-shot to be unconsumed"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | safety_net_at: past}})
    :ok
  end

  defp execution_messages(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        []

      space ->
        space.id
        |> ExecutionSpace.list_messages_with_participants()
        |> Enum.map(& &1.content)
    end
  end

  defp awaiting_notices(task_id) do
    task_id
    |> execution_messages()
    |> Enum.count(&String.contains?(String.downcase(&1), "awaiting a human ruling"))
  end
end
