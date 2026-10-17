defmodule Platform.Orchestration.TaskRouterNeedsHumanHoldTest do
  @moduledoc """
  `report_blocker(needs_human: true)` must hold the stage instead of decaying
  into a re-dispatch loop (task 01a04a8c).

  ## The quantity under test, measured rather than assumed

  The hold is not a router flag — it is the `execution_leases` row itself:
  `status == "blocked"` on a stage-scoped `needs_human` lease, which the
  sweep never expires and every lease reader treats as live (task 01a0665e
  stage 2; under 01a04a8c it was the row's `expires_at`, a 12-hour horizon).
  So every fixture here files its blocker with an `occurred_at` **twenty
  minutes in the past** — past the 15-minute execution-phase liveness TTL —
  and the "no clock" describe files it **thirteen hours** in the past, past
  the horizon that used to end it. A fixture that filed the blocker "now"
  would pass against the unfixed code, which is exactly the trap the ticket
  names — the decay is the bug, so the moment of blocking proves nothing.

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

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeSupervision
  alias Platform.Orchestration.TaskRouter
  alias Platform.Orchestration.TaskRouterWatcher
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
      # (Since task 01a0665e stage 2 that column is informational for a
      # `needs_human` hold — the "no clock" describe below is the hold past
      # it — but the plain-blocker control two tests down needs this pair to
      # differ in the flag alone, so the write itself stays pinned.)
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

  # ── No clock (task 01a0665e stage 2) ────────────────────────────────────
  #
  # Every fixture below is the measured defect on 01a04fbc-1e71: a blocker
  # filed THIRTEEN hours ago, past the 12-hour horizon 01a04a8c gave the
  # lease, so the row's own `expires_at` is in the past. Under the horizon
  # the sweep flipped it to `expired`, the router re-dispatched, the executor
  # refused again, and `:check_no_ack` stamped "Executor never acked".
  describe "the hold has no clock" do
    @stale_hold_minutes 13 * 60

    test "a needs_human lease does not re-dispatch on expiry", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      assert hold.status == "blocked"
      assert DateTime.compare(hold.expires_at, DateTime.utc_now()) == :lt
      :ok = sync_router(ctx.task.id)

      # Every injector that lands in `do_dispatch/3` directly. The
      # `{:runtime_reconnected, _}` injector goes through the watcher's own
      # lease filter and needs a resolvable runtime, so it is pinned in
      # `TaskRouterWatcherTest` ("a reconnect does not re-dispatch ...").
      send(pid, :dispatch)
      send(pid, :dispatch_boot)
      :ok = TaskRouterWatcher.force_dispatch(ctx.task.id)
      :ok = sync_router(ctx.task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human

      # Each dispatch ran `needs_human_hold/3`, whose sweep is what used to
      # flip this row. The SAME row must still be the hold, and still
      # `blocked` — an `expired` row here is the horizon back in force.
      assert %ExecutionLease{id: hold_id} =
               RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      assert hold_id == hold.id
      assert Repo.get!(ExecutionLease, hold.id).status == "blocked"

      # And the reconnect-path read sees it too.
      assert %ExecutionLease{id: ^hold_id} =
               RuntimeSupervision.current_lease_for_task_runtime(ctx.task.id, ctx.runtime_id)
    end

    test "a user transition releases the hold and dispatch resumes", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      user = create_user!()
      task = Tasks.get_task_record(ctx.task.id)
      assert {:ok, %{status: "in_progress"}} = Tasks.transition_task(task, "in_progress", user)

      released = Repo.get!(ExecutionLease, hold.id)
      assert released.status == "expired"
      assert released.metadata["released_by_user_id"] == user.id
      assert is_binary(released.metadata["released_at"])
      refute RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      refute Tasks.get_task_record(ctx.task.id).metadata["awaiting_human_action"]
    end

    test "CONTROL: a :system transition leaves the hold standing", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # The same edge as the test above, moved by nobody. This is the shape
      # of `stamp_blocked_reason/2 -> ensure_blocked/1` and of an agent's
      # `task_update`: automation must not be able to end a human's hold.
      task = Tasks.get_task_record(ctx.task.id)
      assert {:ok, %{status: "in_progress"}} = Tasks.transition_task(task, "in_progress")

      standing = Repo.get!(ExecutionLease, hold.id)
      assert standing.status == "blocked"
      refute Map.has_key?(standing.metadata, "released_by_user_id")

      # No injector of our own yet: a release WAKES the router (stage 4), so
      # a `:system` move that released nothing must also have woken nothing.
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human
    end

    test "a board drag out of blocked releases the hold", ctx do
      # `drop_task_to_column/3` is the board's write and it does NOT go
      # through `transition_task/3` — it writes its own changeset — so the
      # release is mirrored there. The 09-03 re-dispatches were exactly this
      # drag, `blocked -> in_progress`, and it stays a legitimate release.
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      # Parked by the watchdog: the status write with no hooks, as
      # `stamp_blocked_reason/2` leaves it.
      task =
        ctx.task.id
        |> Tasks.get_task_record()
        |> Ecto.Changeset.change(status: "blocked")
        |> Repo.update!()

      user = create_user!()

      assert {:ok, %{status: "in_progress"}} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, user.id})

      released = Repo.get!(ExecutionLease, hold.id)
      assert released.status == "expired"
      assert released.metadata["released_by_user_id"] == user.id

      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
    end

    test "execution.unblocked from the runtime releases", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      {:ok, event} =
        Platform.Orchestration.record_runtime_event(%{
          "task_id" => ctx.task.id,
          "phase" => "execution",
          "runtime_id" => ctx.runtime_id,
          "event_type" => "execution.unblocked",
          "payload" => %{"stage_id" => ctx.stage.id, "description" => "ruling received"}
        })

      # The SAME row flipped, not a second one minted beside a hold the
      # lookup could no longer see (a 13-hour-old `blocked` row was invisible
      # to `current_active_lease/5` under the horizon, and a second
      # active-or-blocked row for the stage is a unique-index violation).
      assert event.lease_id == hold.id
      assert Repo.get!(ExecutionLease, hold.id).status == "active"

      assert Repo.aggregate(from(l in ExecutionLease, where: l.task_id == ^ctx.task.id), :count) ==
               1

      refute RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.runtime_id)

      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
    end

    test "the reminder keeps narrating a hold the clock would have ended", ctx do
      pid = boot_and_drain!(ctx)

      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      assert awaiting_notices(ctx.task.id) == 1

      # Under the horizon this tick found no hold and fired `:dispatch`.
      send(pid, {:awaiting_human_reminder, hold.id})
      :ok = sync_router(ctx.task.id)

      assert awaiting_notices(ctx.task.id) == 2
      messages = execution_messages(ctx.task.id)
      assert Enum.any?(messages, &String.contains?(&1, "OVERDUE"))
      assert Enum.any?(messages, &String.contains?(&1, "until a person moves the task"))
      refute Enum.any?(messages, &String.contains?(&1, "after which dispatch resumes"))
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert Repo.get!(ExecutionLease, hold.id).status == "blocked"
    end
  end

  # ── The release is the wake (task 01a0665e stage 4) ─────────────────────
  #
  # Measured on 01a06b2b-8185 (2026-09-04): the executor acked the deploy
  # stage, filed `report_blocker(needs_human: true)`, the person dragged the
  # task, the lease flipped to `expired` with `released_by_user_id` set — and
  # the runtime received nothing. Two defects: nothing scheduled a dispatch
  # (the release was only ever re-read inside `:dispatch_now`), and the one
  # dispatch that was hand-injected afterwards was withheld by the
  # live-acked-executor guard, because the PRE-blocker ack was still inside
  # the stage's safety net. Every fixture here acks first, the way the
  # dispatch text tells every runtime to, so both defects are in play.
  describe "a human release wakes the router and the pre-blocker ack does not withhold it" do
    test "hold + pre-blocker ack + user drag: exactly one dispatch, nothing suppressed", ctx do
      pid = boot_and_drain!(ctx)
      attach_suppression_telemetry!()

      ack!(ctx)
      hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert TaskRouter.current_status(ctx.task.id).status == :waiting_human

      # The ack is inside its safety net, so ONLY the release can explain a
      # dispatch getting past the guard below.
      assert DateTime.diff(
               DateTime.utc_now(),
               Orchestration.last_stage_ack_at(ctx.task.id, ctx.stage.id, ctx.assignee.id),
               :millisecond
             ) < coding_safety_net_ms()

      user = create_user!()
      task = Tasks.get_task_record(ctx.task.id)

      # The board's write, exactly as `board_component.ex` makes it. NO
      # injector of our own after this line: the release is the wake.
      assert {:ok, %{status: "in_progress"}} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, user.id})

      released = Repo.get!(ExecutionLease, hold.id)
      assert released.status == "expired"
      assert released.metadata["released_by_user_id"] == user.id

      :ok = sync_router(ctx.task.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"},
                     1_000,
                     "the human release must produce the dispatch on its own — " <>
                       "nothing else is scheduled to"

      # Exactly one: the drag broadcasts once and releases once.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      refute_received {:dispatch_suppressed, %{reason: :live_acked_executor}},
                      "the pre-blocker ack was read as a live executor and withheld the " <>
                        "dispatch the release was for"

      assert TaskRouter.current_status(ctx.task.id).status != :waiting_human
      refute Tasks.get_task_record(ctx.task.id).metadata["awaiting_human_action"]

      # The re-dispatch is a FRESH dispatch: the liveness row the hold
      # cleared was rebuilt with no ack and a live no-ack deadline, so a
      # runtime that ignores this prompt is caught by the watchdog rather
      # than sheltered by the ack it gave before it parked.
      assert %{ack_at: nil, no_ack_at: %DateTime{}} = LeaseManager.get(ctx.task.id)
    end

    test "CONTROL: once the runtime acks the re-dispatch, a reconnect does not prompt again",
         ctx do
      pid = boot_and_drain!(ctx)
      attach_suppression_telemetry!()

      ack!(ctx)
      _hold = file_blocker!(ctx, true, @stale_hold_minutes)
      :ok = sync_router(ctx.task.id)
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      user = create_user!()
      task = Tasks.get_task_record(ctx.task.id)

      assert {:ok, %{status: "in_progress"}} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, user.id})

      :ok = sync_router(ctx.task.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # The runtime took the re-dispatch. Its NEW ack is newer than the
      # release, so the guard protects the stage again — the release must not
      # have blanket-disabled it, or every reconnect would prompt twice.
      ack!(ctx)

      send(pid, :dispatch)
      :ok = TaskRouterWatcher.force_dispatch(ctx.task.id)
      :ok = sync_router(ctx.task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert_received {:dispatch_suppressed, %{reason: :live_acked_executor}}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # The REAL ack path (`task_ack` over the tool surface): the durable
  # `execution.acked` row is what the live-acked-executor guard reads.
  defp ack!(ctx) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => ctx.task.id,
          "stage_id" => ctx.stage.id,
          "subagent_id" => "subagent-needs-human-#{System.unique_integer([:positive])}"
        },
        # Task 01a0c762 stage 2: ack as the DISPATCHED runtime. The router's
        # durable-ack readers now count only the lease owner's rows; an empty
        # context wrote `runtime_id: "tool-surface"`, which no owner matches.
        %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(ctx.assignee.id)}
      )

    :ok = sync_router(ctx.task.id)

    assert %DateTime{} =
             Orchestration.last_stage_ack_at(ctx.task.id, ctx.stage.id, ctx.assignee.id),
           "the ack path must leave a durable per-stage row, or the guard has " <>
             "nothing to read and this test proves nothing"

    :ok
  end

  defp coding_safety_net_ms do
    LeaseManager.stage_kind_timeouts()
    |> Map.fetch!("coding")
    |> Map.fetch!(:safety_net_ms)
  end

  defp attach_suppression_telemetry! do
    test_pid = self()
    handler_id = "needs-human-hold-#{System.unique_integer([:positive])}"

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

  defp create_user! do
    Repo.insert!(%Platform.Accounts.User{
      email: "needs-human-#{System.unique_integer([:positive])}@example.com",
      name: "Needs-human ruler",
      oidc_sub: "oidc-needs-human-#{System.unique_integer([:positive])}"
    })
  end

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
