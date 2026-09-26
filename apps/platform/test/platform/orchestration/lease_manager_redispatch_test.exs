defmodule Platform.Orchestration.LeaseManagerRedispatchTest do
  @moduledoc """
  `record_dispatch/5` must distinguish a stage TRANSITION from a
  RE-dispatch of the stage already being leased (task 019fa469 stage 6).

  Before this distinction existed, every dispatch rebuilt the ETS row
  with `ack_at: nil` and a fresh 5-minute `no_ack_at`, so a duplicate
  `task_assigned` for a stage that already had a live, acked agent
  erased the ack and re-armed the alarm against it. Every
  `execution.no_ack_timeout` observed on 2026-07-27 — roughly a dozen
  across six tasks — was that, and not one was a dropped runtime.

  Each case here is one half of a counterfactual pair built from the
  same fixture (`dispatch/3`), differing in a single field:

    * same stage vs. different stage
    * acked vs. never acked

  The never-acked halves are the load-bearing ones. A change that made
  `record_dispatch/5` preserve everything unconditionally would satisfy
  the "ack survives" assertions perfectly while disabling the detector,
  so every preservation assertion is paired with one proving the alarm
  still has a deadline to fire on.

  Async-false: `LeaseManager` is a named GenServer over one shared,
  named, ephemeral ETS table.
  """

  use ExUnit.Case, async: false

  alias Platform.Orchestration.LeaseManager

  @ack_ms LeaseManager.stage_kind_timeouts()["coding"].ack_ms
  @safety_net_ms LeaseManager.stage_kind_timeouts()["coding"].safety_net_ms

  # Task 01a0c762: every dispatch here goes to ONE owner, so these cases
  # keep exercising the same-owner re-dispatch path they always pinned.
  # The different-owner path lives in `lease_manager_ack_ownership_test.exs`.
  @owner "runtime-redispatch-test"

  setup do
    on_exit(fn ->
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:orchestration_lease_manager)
      end
    end)

    %{task_id: new_task_id(), stage_a: new_stage_id(), stage_b: new_stage_id()}
  end

  defp new_task_id, do: "task-#{System.unique_integer([:positive])}"
  defp new_stage_id, do: "stage-#{System.unique_integer([:positive])}"

  # The one fixture builder. `at` lets a case place a dispatch at a
  # known instant so deadlines can be asserted exactly rather than
  # approximately.
  defp dispatch(task_id, stage_id, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    kind = Keyword.get(opts, :kind, "coding")
    :ok = LeaseManager.record_dispatch(task_id, stage_id, kind, at, @owner)
    at
  end

  describe "re-dispatch of the SAME stage" do
    test "preserves an ack that already landed, and clears the countdown with it", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      dispatch(task_id, stage_a)
      :ok = LeaseManager.record_ack(task_id, @owner)

      %{ack_at: %DateTime{} = original_ack} = LeaseManager.get(task_id)

      # The duplicate `task_assigned` that used to wipe the ack.
      dispatch(task_id, stage_a)

      assert %{ack_at: ^original_ack, no_ack_at: nil, no_ack_fired?: false} =
               LeaseManager.get(task_id)
    end

    test "does NOT push the no-ack deadline out when no ack ever landed", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      t0 = DateTime.add(DateTime.utc_now(), -120, :second)
      dispatch(task_id, stage_a, at: t0)

      %{no_ack_at: original_deadline} = LeaseManager.get(task_id)
      assert original_deadline == DateTime.add(t0, @ack_ms, :millisecond)

      # Two more duplicates, each two minutes later. If the deadline moved
      # with them, a runtime that dropped before spawning would never time
      # out as long as duplicates kept arriving.
      dispatch(task_id, stage_a, at: DateTime.add(t0, 60, :second))
      dispatch(task_id, stage_a, at: DateTime.add(t0, 120, :second))

      assert %{ack_at: nil, no_ack_at: ^original_deadline} = LeaseManager.get(task_id)
    end

    test "the preserved deadline is still reachable — a dropped runtime still times out", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      # Dispatched longer ago than `ack_ms`, never acked. This is the case
      # the alarm exists for; the fix must leave it firing.
      t0 = DateTime.add(DateTime.utc_now(), -(@ack_ms + 60_000), :millisecond)
      dispatch(task_id, stage_a, at: t0)
      dispatch(task_id, stage_a, at: DateTime.utc_now())

      assert %{ack_at: nil, no_ack_at: %DateTime{} = deadline} = LeaseManager.get(task_id)

      assert DateTime.compare(deadline, DateTime.utc_now()) == :lt,
             "a duplicate dispatch must not carry an unacked lease's deadline into the future"
    end

    test "extends the safety net (a re-dispatch IS activity) — deliberately unlike no-ack", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      t0 = DateTime.add(DateTime.utc_now(), -120, :second)
      dispatch(task_id, stage_a, at: t0)
      %{safety_net_at: first_net} = LeaseManager.get(task_id)

      t1 = DateTime.utc_now()
      dispatch(task_id, stage_a, at: t1)

      assert %{safety_net_at: second_net} = LeaseManager.get(task_id)
      assert second_net == DateTime.add(t1, @safety_net_ms, :millisecond)
      assert DateTime.compare(second_net, first_net) == :gt
    end

    test "preserves last_progress_at, no_ack_fired? and safety_net_fired?", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      dispatch(task_id, stage_a)
      :ok = LeaseManager.record_progress(task_id, @owner)
      {:ok, :fired} = LeaseManager.mark_no_ack_fired(task_id)
      {:ok, :fired} = LeaseManager.mark_safety_net_fired(task_id)

      %{last_progress_at: %DateTime{} = progress_at} = LeaseManager.get(task_id)

      dispatch(task_id, stage_a)

      assert %{
               last_progress_at: ^progress_at,
               no_ack_fired?: true,
               safety_net_fired?: true
             } = LeaseManager.get(task_id)

      # And the guard still holds: no second alarm for the same stage.
      assert {:ok, :already_fired} = LeaseManager.mark_no_ack_fired(task_id)
    end

    test "refreshes stage_kind but keeps dispatched_at on the FIRST dispatch", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      t0 = DateTime.add(DateTime.utc_now(), -300, :second)
      dispatch(task_id, stage_a, at: t0, kind: "coding")

      dispatch(task_id, stage_a, at: DateTime.utc_now(), kind: "review")

      # `dispatched_at` is the only input to the alert payloads'
      # `elapsed_ms_since_dispatch`. Moving it would make a five-minute-old
      # unacked dispatch report "no ack after 0s" the moment a duplicate
      # landed, and would break the row's own invariant below.
      assert %{dispatched_at: ^t0, stage_kind: "review", no_ack_at: no_ack_at} =
               LeaseManager.get(task_id)

      assert no_ack_at == DateTime.add(t0, @ack_ms, :millisecond),
             "an unacked lease must keep no_ack_at == dispatched_at + ack_ms"
    end

    test "arms a countdown when the prior dispatch's stage_kind had none", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      # manual_approval disables both timers, so there is no original
      # deadline to preserve — the third `redispatch_no_ack/3` clause.
      dispatch(task_id, stage_a,
        at: DateTime.add(DateTime.utc_now(), -600, :second),
        kind: "manual_approval"
      )

      assert %{no_ack_at: nil} = LeaseManager.get(task_id)

      t1 = DateTime.utc_now()
      dispatch(task_id, stage_a, at: t1, kind: "coding")

      # The ack expectation starts here, so `dispatched_at` moves with it —
      # the invariant holds in this branch too, and the alarm would report
      # elapsed-since-the-expectation rather than since a dispatch nobody
      # was ever asked to ack.
      assert %{no_ack_at: %DateTime{} = deadline, dispatched_at: ^t1} =
               LeaseManager.get(task_id)

      assert deadline == DateTime.add(t1, @ack_ms, :millisecond)
    end

    test "a manual_approval re-dispatch leaves the clock alone (nothing to arm)", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      t0 = DateTime.add(DateTime.utc_now(), -600, :second)
      dispatch(task_id, stage_a, at: t0, kind: "manual_approval")
      dispatch(task_id, stage_a, at: DateTime.utc_now(), kind: "manual_approval")

      assert %{dispatched_at: ^t0, no_ack_at: nil} = LeaseManager.get(task_id)
    end
  end

  describe "dispatch of a DIFFERENT stage (the counterfactual half)" do
    test "drops the ack and arms a fresh countdown", %{
      task_id: task_id,
      stage_a: stage_a,
      stage_b: stage_b
    } do
      dispatch(task_id, stage_a)
      :ok = LeaseManager.record_ack(task_id, @owner)
      assert %{ack_at: %DateTime{}} = LeaseManager.get(task_id)

      t1 = DateTime.utc_now()
      dispatch(task_id, stage_b, at: t1)

      assert %{
               stage_id: ^stage_b,
               ack_at: nil,
               last_progress_at: nil,
               no_ack_at: %DateTime{} = deadline,
               no_ack_fired?: false,
               safety_net_fired?: false
             } = LeaseManager.get(task_id)

      assert deadline == DateTime.add(t1, @ack_ms, :millisecond)
    end

    test "does NOT inherit the previous stage's deadline", %{
      task_id: task_id,
      stage_a: stage_a,
      stage_b: stage_b
    } do
      t0 = DateTime.add(DateTime.utc_now(), -(@ack_ms + 60_000), :millisecond)
      dispatch(task_id, stage_a, at: t0)
      %{no_ack_at: stale_deadline} = LeaseManager.get(task_id)

      t1 = DateTime.utc_now()
      dispatch(task_id, stage_b, at: t1)

      assert %{no_ack_at: fresh_deadline} = LeaseManager.get(task_id)
      refute fresh_deadline == stale_deadline

      assert DateTime.compare(fresh_deadline, DateTime.utc_now()) == :gt,
             "a new stage gets its full ack window, not the elapsed remainder of the last one"
    end

    test "clears a silence set on the previous stage", %{
      task_id: task_id,
      stage_a: stage_a,
      stage_b: stage_b
    } do
      dispatch(task_id, stage_a)
      until = DateTime.add(DateTime.utc_now(), 60, :second)
      :ok = LeaseManager.silence(task_id, until, "operator override")

      dispatch(task_id, stage_b)

      assert %{silenced_until: nil} = LeaseManager.get(task_id),
             "silence must never leak across a stage transition"
    end
  end

  describe "silence across a re-dispatch" do
    test "survives a same-stage re-dispatch", %{task_id: task_id, stage_a: stage_a} do
      dispatch(task_id, stage_a)
      until = DateTime.add(DateTime.utc_now(), 60, :second)
      :ok = LeaseManager.silence(task_id, until, "operator override")

      dispatch(task_id, stage_a)

      assert %{silenced_until: ^until} = LeaseManager.get(task_id),
             "a duplicate dispatch must not cancel an operator's silence"
    end
  end

  describe "first dispatch (no existing row)" do
    test "writes the zero-ack row unchanged", %{task_id: task_id, stage_a: stage_a} do
      t0 = DateTime.utc_now()
      dispatch(task_id, stage_a, at: t0)

      assert %{
               stage_id: ^stage_a,
               stage_kind: "coding",
               dispatched_at: ^t0,
               ack_at: nil,
               last_progress_at: nil,
               no_ack_fired?: false,
               safety_net_fired?: false,
               silenced_until: nil,
               no_ack_at: no_ack_at,
               safety_net_at: safety_net_at
             } = LeaseManager.get(task_id)

      assert no_ack_at == DateTime.add(t0, @ack_ms, :millisecond)
      assert safety_net_at == DateTime.add(t0, @safety_net_ms, :millisecond)
    end

    test "a re-dispatch after clear/1 is a first dispatch, not a re-dispatch", %{
      task_id: task_id,
      stage_a: stage_a
    } do
      # LeaseManager is ephemeral: `clear/1` on a human gate, or a router
      # restart dropping the table's owner, leaves no row to carry ack
      # state forward from. The stage_id match cannot resurrect it.
      dispatch(task_id, stage_a)
      :ok = LeaseManager.record_ack(task_id, @owner)
      :ok = LeaseManager.clear(task_id)

      dispatch(task_id, stage_a)

      assert %{ack_at: nil, no_ack_at: %DateTime{}} = LeaseManager.get(task_id)
    end
  end
end
