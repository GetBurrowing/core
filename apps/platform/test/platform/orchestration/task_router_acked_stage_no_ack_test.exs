defmodule Platform.Orchestration.TaskRouterAckedStageNoAckTest do
  @moduledoc """
  THE BUG, DOCUMENTED BEFORE IT IS FIXED (task 01a007bf stage 2).

  On 2026-08-15 the `execution.no_ack_timeout` alarm fired six times against
  agents that HAD acked. `LeaseManager.record_ack/1` is the only thing that
  remembers an ack, and it remembers it *in the lease row* — so any code path
  that calls `clear_liveness/1` and then re-dispatches throws the memory away.
  The re-dispatch builds a fresh row with `ack_at: nil`, the ack window opens
  again against an agent that is already working, and five minutes later the
  alarm fires and posts a `needs_human: true` blocker.

  Stage 2 wrote this file as the BEFORE half, with cases 1 and 2 asserting
  THE ALARM FIRES. Both were OBSERVED FIRING against an acked stage — that is
  the recorded evidence of the defect, and it is why the guard exists. Stage 3
  has now landed the durable per-stage guard in `maybe_fire_no_ack/3` (it
  consulted `Platform.Orchestration.stage_acked?/2`, landed in stage 1; since
  task 01a0db63-c4f3 it reads the runtime-scoped `last_stage_ack_at/3`), so
  cases 1 and 2 are INVERTED here: the alarm must stay silent and the ETS
  lease must show `ack_at` re-stamped. Deleting the guard turns both red
  again; that vacuity check was run and reported for stage 3.

  Case 3 is the control that survived the inversion unchanged: a genuinely
  unacked stage must still alarm. Case 4 pins the two neighbouring paths that
  do NOT reproduce, so the diagnosis is "clear-then-dispatch", not
  "re-dispatch". Case 5 (stage 3) pins that the guard reads the DB, not ETS:
  it stays silent even when the lease row was wiped wholesale between dispatch
  and deadline.

  ## Case 6 (task 01a06d39): the guard is BOUNDED by the last human release

  Cases 1-5 pinned "an acked stage does not alarm". They did not, and could
  not, distinguish that from "a stage that was EVER acked never alarms again",
  which is what the guard actually said — and one live path drives the two
  apart. The runtime acks, files `report_blocker(needs_human: true)`, a PERSON
  releases the hold, and the router re-dispatches the same stage with a fresh
  five-minute window. If the runtime then ignores that re-dispatch, the
  PRE-BLOCKER ack suppressed the alarm forever and only the 90-minute safety
  net was left (observed 2026-09-04).

  Case 6 is a PAIR, and only the pair discriminates: 6a runs the clock out on
  a re-dispatch the runtime ignored and the alarm must FIRE; 6b runs the same
  clock out after the runtime ACKED the re-dispatch and the alarm must stay
  SILENT. 6a alone is satisfied by deleting the case-1-5 guard, which is a
  regression; 6b alone is satisfied by the unbounded guard, which is the bug.

  ## Every state here is DRIVEN, not constructed

  * the ack is `ToolSurface.execute("task_ack", ...)` — the real MCP entry
    point, so both the persisted `execution.acked` row and
    `LeaseManager.record_ack/1` happen exactly as in production;
  * the review gate is `ReviewRequests.create_review_request/1` followed by
    `ReviewRequests.reject_item/3`, which broadcast the real
    `{:review_request_pending, ...}` / `{:review_request_resolved, outcome:
    :failed}` messages the router handles;
  * `execution.finished` is a real `Orchestration.record_runtime_event/1`
    write, broadcast through `RuntimeSupervision`.

  ## What driving it changed about REPRO D

  The stage spec's REPRO D said the FAILED review resolution re-dispatches
  the acked stage. Driven end to end it does not: a failed validation fails a
  running stage immediately, so the rejection crosses a stage boundary and the
  alarm that follows names the next, genuinely-unacked stage. The reachable
  form of the same defect is the gate's own `clear_liveness/1` — the review
  request opening is what destroys the ack memory, and ANY later re-dispatch
  of the still-running stage re-opens the window. Both are pinned below; the
  second is labelled a reachability probe and must stay firing after stage 3.

  The only thing poked directly is the CLOCK: `expire_no_ack_deadline!/1`
  moves `no_ack_at` into the past, exactly as
  `task_router_stale_no_ack_timer_test.exs` does, because the alternative is
  a five-minute `Process.sleep`. No `ack_at` is ever hand-set, no lease row is
  ever hand-deleted, no stage status is ever hand-constructed.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration

  alias Platform.Orchestration.{
    ExecutionLease,
    ExecutionSpace,
    LeaseManager,
    RuntimeSupervision,
    TaskRouter
  }

  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{name: "Acked No-Ack Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Acked stage no-ack",
        description: "Pin the acked-agent alarm",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"` — the alarm is armed.
    # The MIXED validation set matters: `current_stage_type/1` downgrades a
    # stage to `manual_approval` (alarm disabled) only when EVERY pending
    # validation is a manual_approval, and the production reproduction was a
    # mixed stage.
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, test_validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    {:ok, manual_validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    assignee = %{type: :federated, id: "runtime-acked-#{System.unique_integer([:positive])}"}

    on_exit(fn ->
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

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{
      task: task,
      plan: plan,
      stage: stage,
      assignee: assignee,
      test_validation: test_validation,
      manual_validation: manual_validation
    }
  end

  # ── harness ────────────────────────────────────────────────────────────

  defp boot_router!(task, assignee) do
    Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)
    :ok = sync_router(task.id)
    pid
  end

  # The REAL ack: the `task_ack` MCP tool. Writes the durable
  # `execution.acked` runtime_event AND calls `LeaseManager.record_ack/3`,
  # then broadcasts so the router's own `apply_runtime_event/2` clause runs.
  # Acks as the dispatched runtime (`assignee.id`), the only caller the lease
  # accepts since task 01a0c762.
  defp ack_via_tool!(task, stage, assignee) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-acked-#{System.unique_integer([:positive])}"
        },
        %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(assignee.id)}
      )

    :ok = sync_router(task.id)

    assert %{ack_at: %DateTime{}} = LeaseManager.get(task.id),
           "the real ack path must land on the live lease"

    assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id),
           "the real ack path must leave a durable per-stage row"

    :ok
  end

  # "Did ANY runtime write an ack row for this stage" — for the refutations
  # whose meaning is "no ack of any kind". Deliberately a direct row query:
  # the unscoped `stage_acked?/2` was deleted (task 01a0db63-c4f3), and the
  # scoped `/3` read would only prove the OWNER did not ack.
  defp any_ack_row?(task_id, stage_id) do
    Platform.Repo.exists?(
      from(e in Platform.Orchestration.RuntimeEvent,
        where:
          e.task_id == ^task_id and e.event_type == "execution.acked" and
            fragment("?->>'stage_id' = ?", e.payload, ^stage_id)
      )
    )
  end

  # Advance the clock, not the state. Identical to the helper in
  # `task_router_stale_no_ack_timer_test.exs`.
  defp expire_no_ack_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row to expire"
    assert lease.no_ack_at, "expected an armed no-ack deadline to expire"
    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | no_ack_at: past}})
    :ok
  end

  # Re-read the stage through the plan the router itself reads.
  defp reload_stage!(task_id, stage_id) do
    plan = Tasks.current_plan(task_id)
    stage = Enum.find(plan.stages || [], &(&1.id == stage_id))
    assert stage, "expected stage #{stage_id} on the current plan"
    stage
  end

  defp blocker_messages(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.filter(&String.contains?(&1.content, "Executor never acked"))
  end

  # Fires `:check_no_ack` and returns the alarm broadcast + the blocker
  # message it posted. Flunks if either half is missing — the deliverable of
  # this stage is the OBSERVED alarm, so a silent path must not read as a pass.
  defp observe_alarm!(pid, task_id) do
    send(pid, :check_no_ack)
    :ok = sync_router(task_id)

    event =
      receive do
        {:runtime_event, %{event_type: "execution.no_ack_timeout"} = e} -> e
      after
        0 -> flunk("expected an execution.no_ack_timeout broadcast; none arrived")
      end

    blockers = blocker_messages(task_id)
    assert length(blockers) == 1, "expected exactly one no-ack blocker, got #{length(blockers)}"
    blocker = hd(blockers)

    assert get_in(blocker.metadata, ["needs_human"]) == true,
           "the no-ack blocker must escalate to a human: #{inspect(blocker.metadata)}"

    assert %{no_ack_fired?: true} = LeaseManager.get(task_id)
    assert TaskRouter.current_status(task_id).status == :stalled

    IO.puts("""

    ==== OBSERVED ALARM (task #{task_id}) ====
    runtime_event: #{inspect(Map.take(event, [:event_type, :task_id, :stage_id, :payload]), pretty: true, limit: :infinity)}
    blocker content: #{blocker.content}
    blocker metadata: #{inspect(blocker.metadata, pretty: true, limit: :infinity)}
    ==== END OBSERVED ALARM ====
    """)

    {event, blocker}
  end

  defp refute_alarm!(pid, task_id) do
    send(pid, :check_no_ack)
    :ok = sync_router(task_id)

    refute_received {:runtime_event, %{event_type: "execution.no_ack_timeout"}}
    assert blocker_messages(task_id) == []
    assert TaskRouter.current_status(task_id).status != :stalled
    :ok
  end

  # Stage 3's positive assertion: the deadline elapsed, the guard consulted
  # the durable `execution.acked` row, and it BOTH stayed silent AND
  # re-stamped the ETS lease so the check is not repeated every deadline.
  defp refute_alarm_and_assert_restamped!(pid, task_id) do
    assert %{ack_at: nil, no_ack_fired?: false} = LeaseManager.get(task_id),
           "precondition: the ETS lease must have forgotten the ack before the check"

    :ok = refute_alarm!(pid, task_id)

    lease = LeaseManager.get(task_id)
    assert lease, "the guard must leave the lease in place"

    assert %DateTime{} = lease.ack_at,
           "the guard must re-stamp ack_at from the durable row, so the DB lookup is not repeated at every deadline"

    refute lease.no_ack_fired?, "the guard must not mark the alarm as fired"
    :ok
  end

  # ── CASE 1 — REPRO D: the review gate clears the ack, a re-dispatch
  #            re-opens the window against the SAME acked stage ──────────

  describe "REPRO D: the review gate clears the lease and the ack dies with it" do
    test "the alarm stays silent for an agent that acked THIS stage (WAS THE BUG)", %{
      task: task,
      stage: stage,
      assignee: assignee,
      manual_validation: manual_validation
    } do
      pid = boot_router!(task, assignee)
      assert %{ack_at: nil, no_ack_at: %DateTime{}} = LeaseManager.get(task.id)

      :ok = ack_via_tool!(task, stage, assignee)

      space = ExecutionSpace.find_by_task_id(task.id)

      # Real gate open: `create_review_request/1` broadcasts
      # `{:review_request_pending, ...}`, whose handler calls `clear_liveness/1`.
      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Screenshot review"}]
        })

      :ok = sync_router(task.id)

      assert LeaseManager.get(task.id) == nil,
             "the review gate clears the lease — and with it the ONLY memory of the ack"

      # ...while the durable per-stage row survives. That asymmetry is the
      # entire fix surface for stage 3.
      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)

      # Real disposition: the human approves, `maybe_resolve_request/1`
      # broadcasts `{:review_request_resolved, outcome: :passed}` and passes
      # the manual_approval validation. `test_pass` is still pending, so the
      # stage stays RUNNING and the same executor keeps working.
      item = hd(request.items)
      {:ok, _} = ReviewRequests.approve_item(item.id, "reviewer@test")
      :ok = sync_router(task.id)

      assert reload_stage!(task.id, stage.id).status == "running"

      # The re-dispatch. A running-stage re-broadcast is what the heartbeat /
      # stage-transition paths emit continuously in production; `do_dispatch/2`
      # arms fresh liveness timers off it.
      Tasks.broadcast_board({:stage_transitioned, reload_stage!(task.id, stage.id)})
      :ok = sync_router(task.id)

      lease = LeaseManager.get(task.id)
      assert lease, "the re-dispatch must have armed a fresh lease"
      assert lease.stage_id == stage.id, "same stage — no boundary was crossed"

      assert lease.ack_at == nil,
             "THE DEFECT: the fresh lease forgets the ack that the durable row still remembers"

      assert lease.no_ack_at, "and re-opens a five-minute countdown against a working agent"

      # Five minutes later. STAGE 2 OBSERVED THE ALARM FIRE HERE — it produced
      # the `execution.no_ack_timeout` broadcast and a `needs_human: true`
      # blocker against an agent that had acked this exact stage. Stage 3's
      # guard in `maybe_fire_no_ack/3` consults the durable ack row and suppresses
      # it. Removing the guard turns this assertion red again (verified).
      expire_no_ack_deadline!(task.id)
      :ok = refute_alarm_and_assert_restamped!(pid, task.id)

      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id),
             "the durable ack for this exact stage is what suppressed the alarm"
    end

    # REACHABILITY PROBE, and a WARNING for stage 3.
    #
    # The stage spec described REPRO D as "review resolves FAILED, the
    # `{:review_request_resolved, outcome: :failed}` handler re-dispatches,
    # alarm fires against the acked stage". Driven end to end that is NOT what
    # happens: `PlanEngine.evaluate_validation/2` fails a RUNNING stage the
    # instant a validation fails (plan_engine.ex ~:203), so the rejection
    # crosses a stage boundary, and the router's failure-bounce branch opens
    # the NEXT pending stage (`ensure_execution_stage_started/2`). The alarm
    # that follows names a stage nobody has acked, which is CORRECT behaviour.
    #
    # Pinned here so stage 3's guard is not written to suppress it. A guard
    # keyed on "this task acked recently" rather than "this STAGE was acked"
    # would silence this test, and that would be a regression.
    test "a REJECTED review crosses a stage boundary; the alarm names the unacked NEXT stage", %{
      task: task,
      plan: plan,
      stage: stage,
      assignee: assignee,
      manual_validation: manual_validation
    } do
      {:ok, next_stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Fix the review findings",
          description: "coding — stage 2"
        })

      {:ok, _} = Tasks.create_validation(%{stage_id: next_stage.id, kind: "test_pass"})

      pid = boot_router!(task, assignee)
      :ok = ack_via_tool!(task, stage, assignee)

      space = ExecutionSpace.find_by_task_id(task.id)

      {:ok, request} =
        ReviewRequests.create_review_request(%{
          validation_id: manual_validation.id,
          task_id: task.id,
          execution_space_id: space.id,
          items: [%{label: "Screenshot review"}]
        })

      :ok = sync_router(task.id)

      item = hd(request.items)
      {:ok, _} = ReviewRequests.reject_item(item.id, "reviewer@test", "Needs another pass")
      :ok = sync_router(task.id)

      assert reload_stage!(task.id, stage.id).status == "failed"
      assert reload_stage!(task.id, next_stage.id).status == "running"

      lease = LeaseManager.get(task.id)
      assert lease, "the failure bounce re-dispatches"

      assert lease.stage_id == next_stage.id,
             "the re-dispatch is for the NEXT stage, not the acked one"

      refute any_ack_row?(task.id, next_stage.id)

      expire_no_ack_deadline!(task.id)
      {event, _blocker} = observe_alarm!(pid, task.id)

      assert event.stage_id == next_stage.id
    end
  end

  # ── CASE 2 — REPRO B: execution.finished clear-then-dispatch ───────────

  describe "REPRO B: an execution.finished followed by a re-dispatch" do
    test "the alarm stays silent for an agent that acked (WAS THE BUG)", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_tool!(task, stage, assignee)

      # Real terminal-ish runtime event. `apply_runtime_event/2`'s
      # `"execution.finished"` clause calls `clear_liveness/1`.
      {:ok, _event} =
        Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.finished",
          "occurred_at" => DateTime.utc_now(),
          "payload" => %{"stage_id" => stage.id}
        })

      :ok = sync_router(task.id)
      assert LeaseManager.get(task.id) == nil, "execution.finished clears the lease"
      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)

      # The re-dispatch: the same running stage re-broadcast, exactly as the
      # heartbeat / stage-transition paths do in production.
      Tasks.broadcast_board({:stage_transitioned, reload_stage!(task.id, stage.id)})
      :ok = sync_router(task.id)

      lease = LeaseManager.get(task.id)
      assert lease, "the re-dispatch must have armed a fresh lease"

      assert lease.ack_at == nil,
             "the fresh lease still has no memory of the ack — the guard's input, not its output"

      # STAGE 2 OBSERVED THE ALARM FIRE HERE too. Inverted by stage 3's guard.
      expire_no_ack_deadline!(task.id)
      :ok = refute_alarm_and_assert_restamped!(pid, task.id)

      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)
    end
  end

  # ── CASE 5 — the guard reads Postgres, not ETS (stage 3) ──────────────

  describe "the guard's source of truth is the durable row" do
    test "stays silent even when the ETS lease row was wiped between dispatch and deadline", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_tool!(task, stage, assignee)

      # Wholesale ETS wipe — not a `clear_liveness/1` code path but the state
      # a LeaseManager restart (or any of its ~15 callers) leaves behind. The
      # durable row is the ONLY surviving evidence of the ack.
      :ok = LeaseManager.clear(task.id)
      assert LeaseManager.get(task.id) == nil
      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)

      # A fresh dispatch arms a lease that has never seen an ack.
      :ok =
        LeaseManager.record_dispatch(task.id, stage.id, "coding", DateTime.utc_now(), assignee.id)

      expire_no_ack_deadline!(task.id)
      :ok = refute_alarm_and_assert_restamped!(pid, task.id)
    end
  end

  # ── CASE 3 — the control that must survive stage 3 ────────────────────

  describe "the alarm stays real" do
    test "still fires for a genuinely unacked stage", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)

      # No ack of any kind — neither lease nor durable row.
      assert %{ack_at: nil} = LeaseManager.get(task.id)
      refute any_ack_row?(task.id, stage.id)

      expire_no_ack_deadline!(task.id)
      {event, blocker} = observe_alarm!(pid, task.id)

      assert event.stage_id == stage.id
      assert blocker.content =~ "Executor never acked"
      assert get_in(blocker.metadata, ["needs_human"]) == true
      assert get_in(blocker.metadata, ["reason"]) == "execution.no_ack_timeout"
    end
  end

  # ── CASE 4 — negative controls: the neighbouring paths are fine ───────

  describe "negative controls — it is the CLEAR, not the re-dispatch" do
    test "a plain re-dispatch of the same stage keeps ack_at and stays silent", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_tool!(task, stage, assignee)

      # `redispatch_lease/4` (lease_manager.ex ~:498, the 2026-07-27 fix)
      # preserves the ack across a same-stage re-dispatch.
      :ok =
        LeaseManager.record_dispatch(task.id, stage.id, "coding", DateTime.utc_now(), assignee.id)

      assert %{ack_at: %DateTime{}, no_ack_at: nil} = LeaseManager.get(task.id)
      :ok = refute_alarm!(pid, task.id)
    end

    test "a same-stage stage_transitioned re-broadcast does not clear the lease", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)
      :ok = ack_via_tool!(task, stage, assignee)

      Tasks.broadcast_board({:stage_transitioned, reload_stage!(task.id, stage.id)})
      :ok = sync_router(task.id)

      assert %{ack_at: %DateTime{}, no_ack_at: nil} = LeaseManager.get(task.id),
             "a running-stage re-broadcast is not a stage boundary; the ack survives"

      :ok = refute_alarm!(pid, task.id)
    end
  end

  # ── CASE 6 — the human release re-dispatch (task 01a06d39) ────────────
  #
  # THE DISCRIMINATING PAIR. Both tests below drive the SAME live sequence
  # (observed 2026-09-04): the runtime acks, files
  # `report_blocker(needs_human: true)`, a PERSON releases the hold on the
  # board, and `Tasks.maybe_release_needs_human_holds/3` -> `force_dispatch/1`
  # re-dispatches the same stage with a fresh five-minute window. They differ
  # in one thing — whether the runtime ACKS that re-dispatch — and they must
  # reach opposite verdicts at the deadline.
  #
  # WHY BOTH, OR NEITHER COUNTS. Test 6a alone ("the alarm fires") is
  # satisfied by simply deleting the #757 durable-ack guard, which is a
  # regression. Test 6b alone ("the alarm stays silent") is satisfied by the
  # unbounded `stage_acked?/2` this stage replaced, which is the bug. Only the
  # pair separates the bound from either failure mode.
  #
  # WHY THE TWO SHAPES ARE NOT LINE-FOR-LINE IDENTICAL AFTER THE RELEASE.
  # `LeaseManager.record_ack/1` clears `no_ack_at`, so a lease whose ETS row
  # still remembers the new ack has NO deadline to reach and
  # `handle_info(:check_no_ack, …)` short-circuits on `%{ack_at: %DateTime{}}`
  # long before the guard. A post-release ack can therefore only be tested at
  # a deadline through the DURABLE read — which is the exact quantity this
  # stage changed. 6b gets there the way production does: `execution.finished`
  # calls `clear_liveness/1` (REPRO B above), the row dies with the ack in it,
  # and the next same-stage re-dispatch arms a fresh ack-less window.
  # `refute_alarm_and_assert_restamped!/2` asserts `ack_at: nil` as a
  # PRECONDITION, so the ETS short-circuit is provably not what keeps 6b
  # silent.
  #
  # WHAT WENT WRONG THE FIRST TIME. Commit `e107a7a6` pinned this re-dispatch
  # with `assert %{ack_at: nil, no_ack_at: %DateTime{}} = LeaseManager.get(…)`
  # — true at t+0, false at t+5min, and the alarm it advertised never fired in
  # any test. An assertion can be real and still vacuous if it stops being
  # true one instant after it is checked. Both tests here run the clock out.

  describe "a human release re-dispatches the stage (task 01a06d39)" do
    setup do
      # `force_dispatch/1` sends `:dispatch`, which only SCHEDULES
      # `:dispatch_now` a debounce later — `sync_router/1` is a mailbox
      # barrier and cannot wait on a timer. Shorten it so the re-dispatch is
      # observable in bounded time; `assert_eventually/1` still does the
      # waiting.
      previous = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
      Application.put_env(:platform, :task_router_dispatch_debounce_ms, 1)

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :task_router_dispatch_debounce_ms, previous)
        else
          Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
        end
      end)

      :ok
    end

    test "6a THE BUG: the runtime IGNORES the re-dispatch and the alarm FIRES", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)

      # 1. The runtime acks, exactly as every dispatch prompt tells it to.
      :ok = ack_via_tool!(task, stage, assignee)
      pre_blocker_ack_at = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)
      assert %DateTime{} = pre_blocker_ack_at

      # 2. ...then parks itself on a person. The hold clears the liveness row,
      #    so the ONLY surviving memory of the ack is the durable one.
      hold = file_needs_human_blocker!(task, stage, assignee.id)
      assert hold.status == "blocked"
      :ok = sync_router(task.id)

      assert LeaseManager.get(task.id) == nil,
             "the needs_human hold clears the liveness row — the ETS ack is gone"

      # 3. A PERSON rules. Driven through the real board write, so the
      #    `expired` + `released_by_user_id` lease row that
      #    `last_human_release_at/2` reads genuinely exists. A hand-inserted
      #    row would prove nothing about the production path.
      released_at = release_hold!(task, hold)

      assert DateTime.compare(released_at, pre_blocker_ack_at) == :gt,
             "the release must postdate the ack, or there is no bound to test"

      assert released_at == RuntimeSupervision.last_human_release_at(task.id, stage.id)

      # 4. The release IS the wake (task 01a0665e stage 4): nothing else is
      #    scheduled, and the re-dispatch arms a fresh ack-less window.
      lease =
        assert_eventually(fn ->
          case LeaseManager.get(task.id) do
            %{ack_at: nil, no_ack_at: %DateTime{}} = lease -> lease
            other -> other
          end
        end)

      assert %{ack_at: nil, no_ack_at: %DateTime{}, no_ack_fired?: false} = lease
      assert lease.stage_id == stage.id, "same stage — no boundary was crossed"

      # 5. THE RUNTIME IGNORES IT. No `task_ack`, no event of any kind. The
      #    durable ack on this stage is still the PRE-BLOCKER one.
      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id) == pre_blocker_ack_at

      # 6. Five minutes later. Under the unbounded `stage_acked?/2` guard the
      #    pre-blocker ack suppressed this forever and only the 90-minute
      #    safety net was left. It must fire.
      expire_no_ack_deadline!(task.id)
      {event, blocker} = observe_alarm!(pid, task.id)

      # NAMED, not merely "the task became blocked": the 90-minute safety net
      # also produces a blocked task with a needs_human blocker, and the
      # release itself filed one earlier in this very test.
      assert event.event_type == "execution.no_ack_timeout"
      assert event.stage_id == stage.id
      assert event.task_id == task.id
      assert blocker.content =~ "Executor never acked"
      assert get_in(blocker.metadata, ["needs_human"]) == true
      assert get_in(blocker.metadata, ["reason"]) == "execution.no_ack_timeout"
      assert %{no_ack_fired?: true} = LeaseManager.get(task.id)

      # And the reason it fired is the BOUND, not the absence of an ack.
      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id),
             "a durable ack exists; it is older than the release, which is why it no longer suppresses"
    end

    test "6b CONTROL: the runtime ACKS the re-dispatch and the alarm stays SILENT", %{
      task: task,
      stage: stage,
      assignee: assignee
    } do
      pid = boot_router!(task, assignee)

      :ok = ack_via_tool!(task, stage, assignee)
      pre_blocker_ack_at = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)

      hold = file_needs_human_blocker!(task, stage, assignee.id)
      :ok = sync_router(task.id)
      assert LeaseManager.get(task.id) == nil

      released_at = release_hold!(task, hold)
      assert DateTime.compare(released_at, pre_blocker_ack_at) == :gt

      assert_eventually(fn ->
        case LeaseManager.get(task.id) do
          %{ack_at: nil, no_ack_at: %DateTime{}} = lease -> lease
          other -> other
        end
      end)

      # THE ONE DIFFERENCE FROM 6a. The runtime took the re-dispatch.
      :ok = ack_via_tool!(task, stage, assignee)
      post_release_ack_at = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id)

      assert DateTime.compare(post_release_ack_at, released_at) == :gt,
             "the new ack must postdate the release, or this is not the control it claims to be"

      # Now put the deadline back within reach the way production does.
      # `record_ack/1` cleared `no_ack_at`, and `execution.finished` ->
      # `clear_liveness/1` (REPRO B above) throws the ETS ack away entirely;
      # the same-stage re-dispatch then arms a fresh ack-less window. This is
      # the ONLY route by which a post-release ack ever meets a deadline, and
      # it is the durable read that has to answer for it.
      {:ok, _event} =
        Orchestration.record_runtime_event(%{
          "task_id" => task.id,
          "phase" => "execution",
          "runtime_id" => assignee.id,
          "event_type" => "execution.finished",
          "occurred_at" => DateTime.utc_now(),
          "payload" => %{"stage_id" => stage.id}
        })

      :ok = sync_router(task.id)
      assert LeaseManager.get(task.id) == nil, "execution.finished clears the lease"

      Tasks.broadcast_board({:stage_transitioned, reload_stage!(task.id, stage.id)})
      :ok = sync_router(task.id)

      lease =
        assert_eventually(fn ->
          case LeaseManager.get(task.id) do
            %{ack_at: nil, no_ack_at: %DateTime{}} = lease -> lease
            other -> other
          end
        end)

      assert lease.stage_id == stage.id

      # Same deadline as 6a. The durable ack is NEWER than the release, so it
      # still means "someone took this dispatch" and must still suppress —
      # otherwise this stage has simply reverted PR #757.
      expire_no_ack_deadline!(task.id)
      :ok = refute_alarm_and_assert_restamped!(pid, task.id)

      assert Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id) ==
               post_release_ack_at
    end
  end

  # ── helpers for the human-release pair (task 01a06d39) ────────────────

  # The real `report_blocker(needs_human: true)` write: the runtime event the
  # MCP tool emits, which `RuntimeSupervision` turns into the stage-scoped
  # `needs_human` hold lease. Filed at `now` — unlike
  # `task_router_needs_human_hold_test.exs` nothing here turns on the hold
  # outliving a TTL; all that matters is that a PERSON ends it afterwards.
  defp file_needs_human_blocker!(task, stage, runtime_id) do
    {:ok, _event} =
      Orchestration.record_runtime_event(%{
        "task_id" => task.id,
        "phase" => "execution",
        "runtime_id" => runtime_id,
        "event_type" => "execution.blocked",
        "occurred_at" => DateTime.utc_now(),
        "payload" => %{
          "stage_id" => stage.id,
          "description" => "The premise is invalidated; a person must rule on it.",
          "needs_human" => true,
          "reported_by" => "agent"
        }
      })

    hold = RuntimeSupervision.needs_human_hold(task.id, stage.id, runtime_id)
    assert hold, "expected report_blocker(needs_human: true) to leave a stage-scoped hold"
    hold
  end

  # The human release, driven through the board's own write
  # (`drop_task_to_column/3` → `Tasks.maybe_release_needs_human_holds/3` →
  # `RuntimeSupervision.release_needs_human_holds/2`), which is the path the
  # 2026-09-04 incident took. A hand-inserted `expired` lease row would prove
  # nothing about the production path, so the row `last_human_release_at/2`
  # reads is the one this write leaves behind. Returns the release instant.
  defp release_hold!(task, hold) do
    user = create_user!()

    # The watchdog parks the task with a plain status write and no hooks, as
    # `stamp_blocked_reason/2` → `ensure_blocked/1` leaves it. The drag out of
    # `blocked` is what the person then does.
    parked =
      task.id
      |> Tasks.get_task_record()
      |> Ecto.Changeset.change(status: "blocked")
      |> Repo.update!()

    assert {:ok, %{status: "in_progress"}} =
             Tasks.drop_task_to_column(parked, "in_progress", {:user, user.id})

    released = Repo.get!(ExecutionLease, hold.id)
    assert released.status == "expired", "the release must end the hold row"

    assert released.metadata["released_by_user_id"] == user.id,
           "the release must be attributable to a PERSON, or last_human_release_at/2 will not see it"

    released.updated_at
  end

  defp create_user! do
    Repo.insert!(%Platform.Accounts.User{
      email: "acked-no-ack-#{System.unique_integer([:positive])}@example.com",
      name: "Release ruler",
      oidc_sub: "oidc-acked-no-ack-#{System.unique_integer([:positive])}"
    })
  end
end
