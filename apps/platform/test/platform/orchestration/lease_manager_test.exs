defmodule Platform.Orchestration.LeaseManagerTest do
  @moduledoc """
  Tests for `Platform.Orchestration.LeaseManager` — ETS-backed
  ephemeral router liveness store (task 019f640d stage 2).

  Covers:
    * `record_dispatch/5` writes a lease with computed timestamps
    * `record_ack/3` clears no-ack fields, extends safety-net,
      resets `no_ack_fired?`
    * `record_progress/2` extends safety-net only, does NOT touch
      no-ack state
    * `mark_*_fired/1` idempotency (returns `{:ok, :already_fired}`
      on repeat)
    * `clear/1` deletes the row
    * Concurrent read-heavy load — 100 readers + one writer, no
      crashes and no stale reads

  Async-false because the module owns a single named ETS table
  started under `Platform.Application`'s supervision tree.
  """

  use ExUnit.Case, async: false

  alias Platform.Orchestration.LeaseManager

  # Task 01a0c762: every lease is dispatched to a runtime, and only that
  # runtime's ack is accepted. Ownership itself is covered by
  # `lease_manager_ack_ownership_test.exs`.
  @owner "runtime-lease-manager-test"

  setup do
    # LeaseManager is booted by the application supervisor. Purge any
    # rows leaked by prior tests so each case starts from a clean
    # slate — the module is meant to be per-task-scoped and we don't
    # want cross-test bleed.
    on_exit(fn ->
      # No wildcard delete API on the module (deliberately — router
      # code always knows the task_id it's clearing) — walk the
      # table directly in the on-exit cleanup only.
      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:orchestration_lease_manager)
      end
    end)

    :ok
  end

  defp new_task_id, do: "task-#{System.unique_integer([:positive])}"
  defp new_stage_id, do: "stage-#{System.unique_integer([:positive])}"

  describe "stage_kind_timeouts/0" do
    test "returns the p95-buffer matrix with numeric coding/deploying/review/ci_check ack + safety-net values" do
      timeouts = LeaseManager.stage_kind_timeouts()

      for kind <- ~w(coding deploying review ci_check) do
        assert %{ack_ms: 300_000, safety_net_ms: 5_400_000} = timeouts[kind],
               "expected 5m ack / 90m safety-net for #{kind}"
      end
    end

    test "planning has 5m ack + 120m safety-net" do
      assert %{ack_ms: 300_000, safety_net_ms: 7_200_000} =
               LeaseManager.stage_kind_timeouts()["planning"]
    end

    test "manual_approval disables both timers (both nil)" do
      assert %{ack_ms: nil, safety_net_ms: nil} =
               LeaseManager.stage_kind_timeouts()["manual_approval"]
    end
  end

  describe "record_dispatch/5 + get/1" do
    test "writes a lease row with computed no_ack_at and safety_net_at" do
      task_id = new_task_id()
      stage_id = new_stage_id()
      dispatched_at = ~U[2026-07-15 12:00:00.000000Z]

      assert :ok =
               LeaseManager.record_dispatch(task_id, stage_id, "coding", dispatched_at, @owner)

      assert %{
               stage_id: ^stage_id,
               stage_kind: "coding",
               dispatched_at: ^dispatched_at,
               ack_at: nil,
               last_progress_at: nil,
               no_ack_fired?: false,
               safety_net_fired?: false
             } = lease = LeaseManager.get(task_id)

      # no_ack_at = dispatched_at + 5m (300_000 ms)
      assert DateTime.diff(lease.no_ack_at, dispatched_at, :millisecond) == 300_000
      # safety_net_at = dispatched_at + 90m (5_400_000 ms)
      assert DateTime.diff(lease.safety_net_at, dispatched_at, :millisecond) == 5_400_000
    end

    test "manual_approval stage stores nil for both no_ack_at and safety_net_at" do
      task_id = new_task_id()
      dispatched_at = DateTime.utc_now()

      assert :ok =
               LeaseManager.record_dispatch(
                 task_id,
                 new_stage_id(),
                 "manual_approval",
                 dispatched_at,
                 @owner
               )

      assert %{no_ack_at: nil, safety_net_at: nil, stage_kind: "manual_approval"} =
               LeaseManager.get(task_id)
    end

    test "unknown stage_kind stores nil for both timeouts (safe default)" do
      task_id = new_task_id()

      assert :ok =
               LeaseManager.record_dispatch(
                 task_id,
                 new_stage_id(),
                 "brand_new_kind",
                 DateTime.utc_now(),
                 @owner
               )

      assert %{no_ack_at: nil, safety_net_at: nil, stage_kind: "brand_new_kind"} =
               LeaseManager.get(task_id)
    end

    test "get/1 returns nil for unknown task_id" do
      assert LeaseManager.get(new_task_id()) == nil
    end

    test "re-dispatching for the same task_id overwrites the prior lease" do
      task_id = new_task_id()
      first_stage = new_stage_id()
      second_stage = new_stage_id()

      LeaseManager.record_dispatch(task_id, first_stage, "coding", DateTime.utc_now(), @owner)

      LeaseManager.record_dispatch(
        task_id,
        second_stage,
        "review",
        DateTime.utc_now(),
        @owner
      )

      assert %{stage_id: ^second_stage, stage_kind: "review"} = LeaseManager.get(task_id)
    end
  end

  describe "record_ack/3" do
    test "sets ack_at, clears no_ack_at, resets no_ack_fired?, extends safety_net_at" do
      task_id = new_task_id()
      dispatched_at = DateTime.add(DateTime.utc_now(), -60, :second)

      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", dispatched_at, @owner)
      # Simulate the no-ack timer having fired before the ack landed
      # so we can prove the reset semantics.
      LeaseManager.mark_no_ack_fired(task_id)

      before_ack = LeaseManager.get(task_id)
      assert before_ack.no_ack_fired? == true

      assert :ok = LeaseManager.record_ack(task_id, @owner)

      after_ack = LeaseManager.get(task_id)
      assert after_ack.ack_at != nil
      assert after_ack.no_ack_at == nil
      assert after_ack.no_ack_fired? == false

      # safety_net_at was `dispatched_at + 90m`; after ack it should be
      # `now + 90m`, which is strictly later than the pre-ack value
      # because `now > dispatched_at`.
      assert DateTime.compare(after_ack.safety_net_at, before_ack.safety_net_at) == :gt
    end

    test "returns {:error, :not_found} when no lease exists" do
      assert LeaseManager.record_ack(new_task_id(), @owner) == {:error, :not_found}
    end

    test "on a manual_approval lease, ack_at is stamped but safety_net_at stays nil" do
      task_id = new_task_id()

      LeaseManager.record_dispatch(
        task_id,
        new_stage_id(),
        "manual_approval",
        DateTime.utc_now(),
        @owner
      )

      assert :ok = LeaseManager.record_ack(task_id, @owner)

      after_ack = LeaseManager.get(task_id)
      assert after_ack.ack_at != nil
      assert after_ack.safety_net_at == nil
    end
  end

  describe "record_progress/2" do
    test "extends safety_net_at, sets last_progress_at, leaves no_ack fields untouched" do
      task_id = new_task_id()
      dispatched_at = DateTime.add(DateTime.utc_now(), -30, :second)

      LeaseManager.record_dispatch(task_id, new_stage_id(), "review", dispatched_at, @owner)
      before = LeaseManager.get(task_id)

      assert :ok = LeaseManager.record_progress(task_id, @owner)

      after_progress = LeaseManager.get(task_id)
      assert after_progress.last_progress_at != nil
      # safety-net extended past its previous value.
      assert DateTime.compare(after_progress.safety_net_at, before.safety_net_at) == :gt
      # no-ack state is exactly preserved.
      assert after_progress.no_ack_at == before.no_ack_at
      assert after_progress.no_ack_fired? == before.no_ack_fired?
    end

    test "returns {:error, :not_found} when no lease exists" do
      assert LeaseManager.record_progress(new_task_id(), @owner) == {:error, :not_found}
    end
  end

  describe "mark_no_ack_fired/1" do
    test "first call returns {:ok, :fired}, subsequent calls {:ok, :already_fired}" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      assert LeaseManager.mark_no_ack_fired(task_id) == {:ok, :fired}
      assert LeaseManager.mark_no_ack_fired(task_id) == {:ok, :already_fired}
      assert LeaseManager.mark_no_ack_fired(task_id) == {:ok, :already_fired}

      assert LeaseManager.get(task_id).no_ack_fired? == true
    end

    test "returns {:error, :not_found} when no lease exists" do
      assert LeaseManager.mark_no_ack_fired(new_task_id()) == {:error, :not_found}
    end
  end

  describe "mark_safety_net_fired/1" do
    test "first call returns {:ok, :fired}, subsequent calls {:ok, :already_fired}" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      assert LeaseManager.mark_safety_net_fired(task_id) == {:ok, :fired}
      assert LeaseManager.mark_safety_net_fired(task_id) == {:ok, :already_fired}

      assert LeaseManager.get(task_id).safety_net_fired? == true
    end

    test "returns {:error, :not_found} when no lease exists" do
      assert LeaseManager.mark_safety_net_fired(new_task_id()) == {:error, :not_found}
    end

    test "marking safety_net does not touch no_ack state (and vice versa)" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      LeaseManager.mark_safety_net_fired(task_id)

      assert %{safety_net_fired?: true, no_ack_fired?: false} = LeaseManager.get(task_id)
    end
  end

  describe "clear/1" do
    test "removes the lease row so subsequent get/1 returns nil" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      assert LeaseManager.get(task_id) != nil
      assert :ok = LeaseManager.clear(task_id)
      assert LeaseManager.get(task_id) == nil
    end

    test "clearing a non-existent task_id is a silent :ok" do
      assert :ok = LeaseManager.clear(new_task_id())
    end
  end

  describe "silence/3" do
    test "record_dispatch/5 initializes silenced_until to nil so freshly-armed leases are not silenced" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      assert %{silenced_until: nil} = LeaseManager.get(task_id)
    end

    test "sets silenced_until on an armed lease, preserves every other field" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)
      before = LeaseManager.get(task_id)

      until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)

      assert :ok =
               LeaseManager.silence(task_id, until, "operator escape hatch — MCP cache miss")

      after_silence = LeaseManager.get(task_id)
      assert after_silence.silenced_until == until

      # Every other field is untouched — silence is orthogonal to lifecycle state.
      for key <-
            ~w(stage_id stage_kind dispatched_at ack_at last_progress_at safety_net_at no_ack_at no_ack_fired? safety_net_fired?)a do
        assert Map.fetch!(after_silence, key) == Map.fetch!(before, key),
               "silence/3 mutated #{key} — expected only silenced_until to change"
      end
    end

    test "returns {:error, :not_found} when no lease exists" do
      until = DateTime.add(DateTime.utc_now(), 60, :second)

      assert LeaseManager.silence(new_task_id(), until, "no lease yet — retryable") ==
               {:error, :not_found}
    end

    test "rejects past `until` with {:error, :invalid_until}" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      # Comfortably in the past.
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert LeaseManager.silence(task_id, past, "attempted retroactive silence") ==
               {:error, :invalid_until}

      # Lease still has silenced_until: nil — the failed call must not mutate state.
      assert %{silenced_until: nil} = LeaseManager.get(task_id)
    end

    test "rejects `until` equal to now with {:error, :invalid_until}" do
      # Edge of the strict-greater-than check — an `until` that equals `now`
      # would immediately lapse and provides no useful suppression window.
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      # Race note: this test can flake if `DateTime.utc_now/0` inside the
      # handler advances past this `now` before the compare runs, in which
      # case `until` is actually in the past → still :invalid_until. Either
      # way the assertion holds.
      now = DateTime.utc_now()

      assert LeaseManager.silence(task_id, now, "equal-to-now silence") ==
               {:error, :invalid_until}
    end

    test "rejects `until` past the 24h cap with {:error, :cap_exceeded}" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      # 25h > cap
      too_far = DateTime.add(DateTime.utc_now(), 25 * 60 * 60, :second)

      assert LeaseManager.silence(task_id, too_far, "operator forgot the cap") ==
               {:error, :cap_exceeded}

      assert %{silenced_until: nil} = LeaseManager.get(task_id)
    end

    test "accepts `until` exactly at the 24h boundary" do
      # Boundary is inclusive — `until == cap` returns :ok. Because a few
      # microseconds elapse between the caller's clock and the handler's
      # clock, target 24h - 5s to avoid a boundary flake.
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      just_inside = DateTime.add(DateTime.utc_now(), 24 * 60 * 60 - 5, :second)

      assert :ok = LeaseManager.silence(task_id, just_inside, "long-running planner reply")
      assert %{silenced_until: ^just_inside} = LeaseManager.get(task_id)
    end

    test "re-silencing overwrites the prior silenced_until timestamp" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      first = DateTime.add(DateTime.utc_now(), 60, :second)
      second = DateTime.add(DateTime.utc_now(), 900, :second)

      assert :ok = LeaseManager.silence(task_id, first, "initial silence")
      assert %{silenced_until: ^first} = LeaseManager.get(task_id)

      assert :ok = LeaseManager.silence(task_id, second, "extended silence")
      assert %{silenced_until: ^second} = LeaseManager.get(task_id)
    end

    test "record_ack/3 does NOT clear silenced_until — silence is orthogonal to ack" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
      assert :ok = LeaseManager.silence(task_id, until, "operator escape hatch")

      assert :ok = LeaseManager.record_ack(task_id, @owner)

      after_ack = LeaseManager.get(task_id)
      # Ack landed.
      assert after_ack.ack_at != nil
      assert after_ack.no_ack_at == nil
      assert after_ack.no_ack_fired? == false
      # Silence survives the ack — it's an operator override, not lifecycle
      # state.
      assert after_ack.silenced_until == until
    end

    test "record_progress/2 does NOT clear silenced_until" do
      # Documented invariant — progress evidence extends the safety-net but
      # is not the same signal class as an operator-scoped silence override.
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
      assert :ok = LeaseManager.silence(task_id, until, "operator escape hatch")

      assert :ok = LeaseManager.record_progress(task_id, @owner)

      assert %{silenced_until: ^until} = LeaseManager.get(task_id)
    end

    test "clear/1 deletes the row so silence dies by side effect" do
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
      assert :ok = LeaseManager.silence(task_id, until, "operator escape hatch")

      assert :ok = LeaseManager.clear(task_id)

      # Row gone entirely — silence gone with it.
      assert LeaseManager.get(task_id) == nil
    end

    test "re-dispatch on the same task_id resets silenced_until to nil (silence does not leak across stages)" do
      # A stage transition upgrades the lease in place via record_dispatch —
      # the fresh row MUST NOT carry the prior stage's silence.
      task_id = new_task_id()
      LeaseManager.record_dispatch(task_id, new_stage_id(), "coding", DateTime.utc_now(), @owner)

      until = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
      assert :ok = LeaseManager.silence(task_id, until, "silence on stage 1")

      LeaseManager.record_dispatch(task_id, new_stage_id(), "review", DateTime.utc_now(), @owner)

      assert %{silenced_until: nil, stage_kind: "review"} = LeaseManager.get(task_id)
    end
  end

  describe "concurrent access" do
    test "100 concurrent readers survive alongside one writer without crashes or stale reads" do
      task_id = new_task_id()

      LeaseManager.record_dispatch(
        task_id,
        new_stage_id(),
        "coding",
        DateTime.utc_now(),
        @owner
      )

      parent = self()

      # Spawn one writer that flips the safety-net timestamp forward
      # on every tick via `record_progress/2`.
      writer =
        spawn_link(fn ->
          Enum.each(1..500, fn _ ->
            LeaseManager.record_progress(task_id, @owner)
            # Yield to give readers a chance to interleave.
            :erlang.yield()
          end)

          send(parent, :writer_done)
        end)

      # Monitor the writer BEFORE anything that could make it exit. A late
      # monitor on an already-dead process delivers `:DOWN` immediately, which
      # would make the assertion below pass instantly and always.
      writer_ref = Process.monitor(writer)

      # Spawn 100 readers. Each pulls the lease 50 times and asserts
      # every read is a well-formed lease map (never a torn value).
      readers =
        for _ <- 1..100 do
          spawn_link(fn ->
            results =
              for _ <- 1..50 do
                case LeaseManager.get(task_id) do
                  %{stage_kind: "coding"} -> :ok
                  other -> {:bad, other}
                end
              end

            send(parent, {:reader_done, Enum.uniq(results)})
          end)
        end

      # Collect one message per reader — each MUST report only `:ok`
      # values, i.e. `[:ok]` after `Enum.uniq/1`.
      for _ <- readers do
        assert_receive {:reader_done, results}, 10_000
        assert results == [:ok], "reader observed a malformed lease: #{inspect(results)}"
      end

      # `:writer_done` is the progress signal: the writer finished its work and
      # SENT. It says nothing about termination, so `Process.alive?/1` here
      # races the scheduler. The monitor's `:DOWN` is precisely the observable
      # that means "the writer terminated", so assert on that instead.
      assert_receive :writer_done, 10_000
      assert_receive {:DOWN, ^writer_ref, :process, ^writer, _reason}, 10_000

      # After the burst, the lease is still coherent and its
      # safety-net was extended past the initial dispatch value.
      lease = LeaseManager.get(task_id)
      assert lease.last_progress_at != nil
      assert DateTime.compare(lease.safety_net_at, lease.dispatched_at) == :gt
    end
  end
end
