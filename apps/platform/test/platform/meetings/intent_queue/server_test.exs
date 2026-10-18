defmodule Platform.Meetings.IntentQueue.ServerTest do
  @moduledoc """
  Tests for the per-meeting intent queue introduced by task 019f70b8
  stage 2 — `Platform.Meetings.IntentQueue.Server`, its
  `DynamicSupervisor`, and the `Platform.Meetings.IntentQueue` facade
  that fronts them.

  Stage 3 extended it with the ack-gated serial cursor, the ack
  contract, and the ack timeout, and deleted the legacy global queue
  outright (`intent_queue_test.exs` went with it). The cursor cases
  below are the unit-level counterpart to
  `intent_dispatcher_test.exs`'s integration-level ones: these drive
  the server directly, with no dispatcher and no PubSub round-trip, so
  a cursor bug can't hide behind dispatch timing.

  `async: true` is safe because every case uses a freshly-generated
  meeting_id and room_id, so no two cases can reach the same
  Registry-keyed server — which is precisely the isolation property
  the redesign is for.
  """

  # `Platform.DataCase`, not `ExUnit.Case`, since task 01a04a36 armed
  # `:intent_queue_mirror_fatal`. This file asserts ETS behaviour and
  # reads no table directly; what it needs is a sandbox connection the
  # QUEUE OWNER can reach, because every `enqueue`/`transition`/`ack`
  # below drags a `meeting_candidates` write along with it and a mirror
  # that cannot write now raises instead of logging.
  #
  # The accepted cost, recorded rather than discovered: 49 cases that
  # were database-free now check out a connection each. `async: true`
  # survives (`Sandbox.start_owner!(Repo, shared: false)` per case), so
  # the isolation property the module header claims is unchanged — the
  # meeting ids stay unique per case, and now so do the rows they write.
  use Platform.DataCase, async: true

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.Server
  alias Platform.Meetings.IntentQueue.Supervisor, as: QueueSupervisor
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  setup do
    meeting_id = unique_meeting_id()
    room_id = unique_room_id()

    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    %{meeting_id: meeting_id, room_id: room_id}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Meeting, room and chunk ids MUST be real UUIDs.
  #
  # `IntentQueue.Server` mirrors every queue write into
  # `meeting_candidates`, whose `meeting_id` / `room_id` /
  # `transcript_chunk_id` are `:binary_id` columns. A `"meeting-4291"`
  # never reaches Postgres at all — Ecto raises `Ecto.ChangeError` at
  # DUMP time — and the then-non-fatal `mirror/1` wrapper turned that
  # raise into a `Logger.warning`. Every case in this file stayed green
  # over 74 such swallowed raises (task 01a04a36).
  #
  # Both halves of that failure are now closed. The ids are valid, the
  # module is `DataCase` so the owner has a connection, and the mirror
  # is fatal in test — so an insert that does not land fails the case
  # rather than logging. There are no FKs on `meeting_candidates`
  # (`20260827094944_create_meeting_candidates.exs`: "Cross-schema
  # pointers, NOT foreign keys"), so these synthetic ids need no
  # `meetings` row behind them.
  #
  # The durable state MAPPING is still asserted next door in
  # `server_persistence_test.exs`. What this file adds is that the
  # mirror runs at all, on every path the ETS cases already walk —
  # `mirrors a row into meeting_candidates` below is the one case here
  # that looks at the table, and it exists so that "the mirror never
  # ran" is distinguishable from "the mirror ran and worked", which
  # fatality alone cannot tell apart.
  defp unique_meeting_id, do: Ecto.UUID.generate()
  defp unique_room_id, do: Ecto.UUID.generate()

  defp sample_attrs(overrides) do
    chunk_id = Ecto.UUID.generate()

    Map.merge(
      %{
        classified_intent: "create_task",
        target_role: "engineering",
        confidence: 0.87,
        transcript_chunk_id: chunk_id,
        chunk_excerpt: "we should file a task for the billing bug",
        dedupe_key: unique("dk")
      },
      overrides
    )
  end

  defp enqueue!(meeting_id, overrides \\ %{}) do
    {:ok, row} = IntentQueue.enqueue(meeting_id, sample_attrs(overrides))
    row
  end

  # Every ETS table owned by `pid`. Used to prove the queue's table is
  # reclaimed when its owner dies rather than leaked to a sweeper.
  defp tables_owned_by(pid) do
    Enum.filter(:ets.all(), fn tid -> :ets.info(tid, :owner) == pid end)
  end

  describe "enqueue/2" do
    # The one case in this file that reads `meeting_candidates`.
    #
    # Fatality (task 01a04a36) makes a mirror that FAILS loud, but it
    # cannot make a mirror that was never called loud — an unwired hook
    # raises nothing and every other case here would stay green. So one
    # case looks at the table. It is here rather than next door in
    # `server_persistence_test.exs` because what it pins is a property
    # of THIS module: that these 49 cases are now driving real inserts
    # rather than passing over swallowed ones, which is the whole reason
    # the module moved to `DataCase`.
    test "mirrors a row into meeting_candidates", %{meeting_id: meeting_id, room_id: room_id} do
      {:ok, row} = IntentQueue.enqueue(meeting_id, sample_attrs(%{room_id: room_id}))

      assert [candidate] = Candidates.list_for_meeting(meeting_id),
             "no meeting_candidates row for #{meeting_id}. The queue answered {:ok, row} " <>
               "either way — that is the shape of the defect this task closes."

      assert candidate.intent_id == row.id
      assert candidate.meeting_id == meeting_id
      assert candidate.room_id == room_id
      assert candidate.evidence_quote == "we should file a task for the billing bug"
      assert candidate.queue_status == "queued"
    end

    test "starts the meeting's queue on demand and returns a full row", %{
      meeting_id: meeting_id,
      room_id: room_id
    } do
      refute IntentQueue.running?(meeting_id)

      chunk_id = Ecto.UUID.generate()

      {:ok, row} =
        IntentQueue.enqueue(
          meeting_id,
          sample_attrs(%{room_id: room_id, transcript_chunk_id: chunk_id})
        )

      assert IntentQueue.running?(meeting_id)

      assert row.meeting_id == meeting_id
      assert row.room_id == room_id
      assert row.status == :queued
      assert row.classified_intent == "create_task"
      assert row.target_role == "engineering"
      assert row.confidence == 0.87
      assert row.transcript_chunk_id == chunk_id
      assert row.chunk_excerpt == "we should file a task for the billing bug"
      assert is_binary(row.id)
      assert %DateTime{} = row.enqueued_at

      # Every nilable field is present, so consumers never have to
      # Map.get/3 their way around a partially-shaped row.
      for field <- [
            :subagent_id,
            :dispatched_at,
            :acked_at,
            :completed_at,
            :cancelled_at,
            :timed_out_at,
            :dispatch_failure_reason,
            :target_agent_id,
            :target_agent_slug,
            :model_used,
            :elapsed_ms
          ] do
        assert Map.fetch!(row, field) == nil, "expected #{field} to default to nil"
      end
    end

    test "the row id is a distinct, addressable handle per intent", %{meeting_id: meeting_id} do
      a = enqueue!(meeting_id)
      b = enqueue!(meeting_id)

      refute a.id == b.id
      assert {:ok, ^a} = IntentQueue.get(meeting_id, a.id)
      assert {:ok, ^b} = IntentQueue.get(meeting_id, b.id)
    end

    test "a repeated dedupe_key collapses onto the existing row", %{meeting_id: meeting_id} do
      attrs = sample_attrs(%{dedupe_key: "stable-key"})

      {:ok, first} = IntentQueue.enqueue(meeting_id, attrs)

      {:duplicate, second} =
        IntentQueue.enqueue(meeting_id, Map.put(attrs, :classified_intent, "something_else"))

      assert second.id == first.id
      # The duplicate must not overwrite the row it collapsed onto.
      assert second.classified_intent == "create_task"
      assert length(IntentQueue.list(meeting_id)) == 1
    end

    test "rows without a dedupe_key never collapse", %{meeting_id: meeting_id} do
      {:ok, _} = IntentQueue.enqueue(meeting_id, %{classified_intent: "x"})
      {:ok, _} = IntentQueue.enqueue(meeting_id, %{classified_intent: "x"})

      assert length(IntentQueue.list(meeting_id)) == 2
    end

    test "unknown attrs are dropped rather than merged into the row", %{meeting_id: meeting_id} do
      {:ok, row} =
        IntentQueue.enqueue(meeting_id, %{classified_intent: "x", status: :completed, bogus: 1})

      assert row.status == :queued
      refute Map.has_key?(row, :bogus)
    end
  end

  describe "list/1" do
    test "returns rows oldest-first including terminal ones", %{meeting_id: meeting_id} do
      a = enqueue!(meeting_id)
      b = enqueue!(meeting_id)
      c = enqueue!(meeting_id)

      {:ok, _} = IntentQueue.transition(meeting_id, a.id, :completed)

      assert Enum.map(IntentQueue.list(meeting_id), & &1.id) == [a.id, b.id, c.id]
    end

    test "returns [] for a meeting with no queue owner" do
      assert IntentQueue.list(unique_meeting_id()) == []
    end
  end

  describe "per-meeting isolation" do
    test "two meetings keep independent rows and independent tables" do
      m1 = unique_meeting_id()
      m2 = unique_meeting_id()
      on_exit(fn -> Enum.each([m1, m2], &IntentQueue.stop/1) end)

      a = enqueue!(m1, %{classified_intent: "first_meeting"})
      b = enqueue!(m2, %{classified_intent: "second_meeting"})

      assert Enum.map(IntentQueue.list(m1), & &1.id) == [a.id]
      assert Enum.map(IntentQueue.list(m2), & &1.id) == [b.id]

      assert {:error, :not_found} = IntentQueue.get(m1, b.id)
      assert {:error, :not_found} = IntentQueue.get(m2, a.id)

      refute Server.whereis(m1) == Server.whereis(m2)
    end

    test "the same dedupe_key in two meetings does NOT collapse" do
      m1 = unique_meeting_id()
      m2 = unique_meeting_id()
      on_exit(fn -> Enum.each([m1, m2], &IntentQueue.stop/1) end)

      {:ok, _} = IntentQueue.enqueue(m1, sample_attrs(%{dedupe_key: "shared"}))
      {:ok, _} = IntentQueue.enqueue(m2, sample_attrs(%{dedupe_key: "shared"}))

      assert length(IntentQueue.list(m1)) == 1
      assert length(IntentQueue.list(m2)) == 1
    end

    test "stopping one meeting's queue leaves the other's intact" do
      m1 = unique_meeting_id()
      m2 = unique_meeting_id()
      on_exit(fn -> Enum.each([m1, m2], &IntentQueue.stop/1) end)

      _ = enqueue!(m1)
      _ = enqueue!(m2)

      :ok = IntentQueue.stop(m1)

      assert IntentQueue.list(m1) == []
      assert length(IntentQueue.list(m2)) == 1
    end
  end

  describe "transition/4 — the nine statuses" do
    test "each status lands, stamps its timestamp, and broadcasts its event", %{
      meeting_id: meeting_id
    } do
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      # {status, event, timestamp field or nil}
      cases = [
        {:queued, :intent_classified, nil},
        {:dispatched, :intent_dispatched, :dispatched_at},
        {:acked, :intent_acked, :acked_at},
        {:completed, :intent_completed, :completed_at},
        {:cancelled, :intent_cancelled, :cancelled_at},
        {:cancelled_late, :intent_cancelled, :cancelled_at},
        {:timed_out, :intent_timed_out, :timed_out_at},
        {:dispatch_failed, :intent_dispatch_failed, nil},
        {:no_ack_spawn_failed, :intent_no_ack_spawn_failed, nil}
      ]

      # Sanity: the case table covers the enum exactly, so adding a
      # tenth status without extending this test fails here.
      assert cases |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               Enum.sort(IntentQueue.statuses())

      for {status, event, stamp} <- cases do
        row = enqueue!(meeting_id)
        enqueued_id = row.id
        assert_receive {:intent_classified, %{id: ^enqueued_id, status: :queued}}, 500

        {:ok, updated} = IntentQueue.transition(meeting_id, row.id, status)

        assert updated.status == status
        assert_receive {^event, %{id: broadcast_id, status: ^status}}, 500
        assert broadcast_id == row.id

        if stamp do
          assert %DateTime{} = Map.fetch!(updated, stamp),
                 "expected #{status} to stamp #{stamp}"
        end
      end
    end

    test "merges writable attrs and ignores unknown ones", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)

      {:ok, updated} =
        IntentQueue.transition(meeting_id, row.id, :acked, %{
          subagent_id: "higgins.test-host",
          elapsed_ms: 1234,
          seq: 999_999
        })

      assert updated.subagent_id == "higgins.test-host"
      assert updated.elapsed_ms == 1234
      # `seq` is not writable — list/1's ordering must not be forgeable.
      assert updated.seq == row.seq
    end

    test "the two error tones stay distinguishable end to end", %{meeting_id: meeting_id} do
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      waited = enqueue!(meeting_id)
      broken = enqueue!(meeting_id)

      {:ok, waited} = IntentQueue.transition(meeting_id, waited.id, :timed_out)

      {:ok, broken} =
        IntentQueue.transition(meeting_id, broken.id, :dispatch_failed, %{
          dispatch_failure_reason: :no_runtime
        })

      # Different status, different event, different payload — an
      # "everything failed" collapse would break the amber-vs-red split
      # the UI is specified to render.
      assert waited.status == :timed_out
      assert broken.status == :dispatch_failed
      assert broken.dispatch_failure_reason == :no_runtime

      assert_receive {:intent_timed_out, %{status: :timed_out}}, 500
      assert_receive {:intent_dispatch_failed, %{status: :dispatch_failed}}, 500
    end

    test "an unknown status is rejected and leaves the row untouched", %{meeting_id: meeting_id} do
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      row = enqueue!(meeting_id)
      assert_receive {:intent_classified, _}, 500

      assert {:error, {:invalid_status, :dispatching}} =
               IntentQueue.transition(meeting_id, row.id, :dispatching)

      assert {:ok, %{status: :queued}} = IntentQueue.get(meeting_id, row.id)
      refute_receive {_event, %{id: _}}, 100
    end

    test "an unknown intent_id returns :not_found", %{meeting_id: meeting_id} do
      _ = enqueue!(meeting_id)

      assert {:error, :not_found} =
               IntentQueue.transition(meeting_id, "no-such-intent", :completed)
    end
  end

  describe "terminal retention" do
    test "terminal rows survive in the queue instead of being deleted", %{
      meeting_id: meeting_id
    } do
      rows =
        for status <- IntentQueue.terminal_statuses() do
          row = enqueue!(meeting_id)
          {:ok, updated} = IntentQueue.transition(meeting_id, row.id, status)
          updated
        end

      listed = IntentQueue.list(meeting_id)

      assert length(listed) == length(rows)

      assert listed |> Enum.map(& &1.status) |> Enum.sort() ==
               Enum.sort(IntentQueue.terminal_statuses())

      # And each is still individually addressable — this is what the
      # old mark_dispatched/2 delete made impossible for a live UI.
      for row <- rows do
        assert {:ok, %{status: status}} = IntentQueue.get(meeting_id, row.id)
        assert status == row.status
      end
    end
  end

  describe "delete/2" do
    test "removes the row, frees its dedupe key, and stays silent", %{meeting_id: meeting_id} do
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      row = enqueue!(meeting_id, %{dedupe_key: "recycled"})
      assert_receive {:intent_classified, _}, 500

      assert :ok = IntentQueue.delete(meeting_id, row.id)
      assert IntentQueue.list(meeting_id) == []
      refute_receive {_event, %{id: _}}, 100

      # The key is reusable now — a re-classified utterance after a
      # producer removed the row must be able to come back.
      {:ok, again} = IntentQueue.enqueue(meeting_id, sample_attrs(%{dedupe_key: "recycled"}))
      refute again.id == row.id
    end

    test "is idempotent", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      assert :ok = IntentQueue.delete(meeting_id, row.id)
      assert :ok = IntentQueue.delete(meeting_id, row.id)
    end
  end

  describe "lifecycle" do
    test "the ETS table is owned by the server and dies with it", %{meeting_id: meeting_id} do
      _ = enqueue!(meeting_id)
      pid = Server.whereis(meeting_id)

      assert [tid] = tables_owned_by(pid)
      assert :ets.info(tid, :size) == 1

      ref = Process.monitor(pid)
      :ok = IntentQueue.stop(meeting_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # Not "swept later" — gone, because nothing can reach it.
      assert :ets.info(tid) == :undefined
      refute IntentQueue.running?(meeting_id)
      assert IntentQueue.list(meeting_id) == []
    end

    test "a :meeting_finished broadcast for our room stops the queue", %{
      meeting_id: meeting_id,
      room_id: room_id
    } do
      _ = enqueue!(meeting_id, %{room_id: room_id})
      pid = Server.whereis(meeting_id)
      ref = Process.monitor(pid)

      :ok =
        MeetingsPubSub.broadcast_meeting_finished(room_id, %{
          transcript_id: "t-1",
          room_id: room_id,
          space_id: "s-1"
        })

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert IntentQueue.list(meeting_id) == []
    end

    test "a :meeting_finished broadcast for a DIFFERENT room is ignored", %{
      meeting_id: meeting_id,
      room_id: room_id
    } do
      _ = enqueue!(meeting_id, %{room_id: room_id})
      pid = Server.whereis(meeting_id)
      ref = Process.monitor(pid)

      other_room = unique_room_id()

      :ok =
        MeetingsPubSub.broadcast_meeting_finished(other_room, %{
          transcript_id: "t-2",
          room_id: other_room,
          space_id: "s-2"
        })

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert length(IntentQueue.list(meeting_id)) == 1
    end

    test "reads issued against a just-killed owner degrade instead of exiting", %{
      meeting_id: meeting_id
    } do
      row = enqueue!(meeting_id)
      pid = Server.whereis(meeting_id)

      # Kill without waiting for the Registry's monitor to fire, so the
      # lookup below can still hand back the dead pid. That window is
      # exactly what a MeetingLive mounting as its meeting ends hits.
      Process.exit(pid, :kill)

      assert IntentQueue.list(meeting_id) == []
      assert {:error, :not_found} = IntentQueue.get(meeting_id, row.id)
      assert {:error, :not_found} = IntentQueue.transition(meeting_id, row.id, :completed)
      assert :ok = IntentQueue.delete(meeting_id, row.id)
    end

    test "ensure_started/2 is idempotent under concurrent callers", %{meeting_id: meeting_id} do
      parent = self()

      for _ <- 1..10 do
        spawn(fn ->
          send(parent, {:started, QueueSupervisor.ensure_started(meeting_id)})
        end)
      end

      pids =
        for _ <- 1..10 do
          assert_receive {:started, {:ok, pid}}, 1_000
          pid
        end

      assert Enum.uniq(pids) == [Server.whereis(meeting_id)]
    end
  end

  describe "facade guards" do
    test "reads against a meeting with no queue degrade instead of raising" do
      absent = unique_meeting_id()

      assert IntentQueue.list(absent) == []
      assert {:error, :not_found} = IntentQueue.get(absent, "whatever")
      assert {:error, :not_found} = IntentQueue.transition(absent, "whatever", :completed)
      assert :ok = IntentQueue.delete(absent, "whatever")
      assert :ok = IntentQueue.stop(absent)
    end

    test "the status groupings partition the enum" do
      assert Enum.sort(IntentQueue.statuses()) ==
               Enum.sort(
                 [:queued] ++ IntentQueue.in_flight_statuses() ++ IntentQueue.terminal_statuses()
               )

      assert IntentQueue.in_flight_statuses() == [:dispatched, :acked]
    end

    test "the advancing set is exactly the terminal set" do
      # They answer different questions — "is more expected?" vs "may
      # the next row go out?" — and are kept as separate lists for that
      # reason. Today they coincide; if that ever stops being true this
      # assertion is where the divergence gets noticed.
      assert Enum.sort(IntentQueue.advancing_statuses()) ==
               Enum.sort(IntentQueue.terminal_statuses())
    end

    test "the ack statuses are the four the MCP tool accepts" do
      assert Enum.sort(IntentQueue.ack_statuses()) ==
               Enum.sort([:working, :completed, :rejected, :cancel_honored])
    end
  end

  # ── Serial cursor ──────────────────────────────────────────────────────────

  describe "claim_next/1" do
    test "hands over the OLDEST queued row, still queued", %{meeting_id: meeting_id} do
      first = enqueue!(meeting_id, %{classified_intent: "first"})
      _second = enqueue!(meeting_id, %{classified_intent: "second"})

      assert {:ok, claimed} = IntentQueue.claim_next(meeting_id)
      assert claimed.id == first.id

      # Deliberately NOT `:dispatched` yet. The caller decides whether
      # this became a dispatch or a `:dispatch_failed`, so committing
      # here would force a `:intent_dispatched` broadcast for
      # hand-offs that never happened.
      assert claimed.status == :queued
      assert IntentQueue.cursor(meeting_id) == first.id
    end

    test "answers :busy while a row is in flight", %{meeting_id: meeting_id} do
      first = enqueue!(meeting_id)
      _second = enqueue!(meeting_id)

      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, first.id, :dispatched)

      assert {:busy, busy_id} = IntentQueue.claim_next(meeting_id)
      assert busy_id == first.id
    end

    test "answers :empty when nothing is queued", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :completed)

      assert IntentQueue.claim_next(meeting_id) == :empty
    end

    test "a second dispatch while the cursor is held is refused", %{meeting_id: meeting_id} do
      first = enqueue!(meeting_id)
      second = enqueue!(meeting_id)

      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, first.id, :dispatched)

      # The invariant is enforced at the door into `:dispatched`, not
      # trusted to callers — otherwise any code path that skipped
      # `claim_next/1` could put two intents in front of one agent.
      assert {:error, {:cursor_busy, holder}} =
               IntentQueue.transition(meeting_id, second.id, :dispatched)

      assert holder == first.id
      assert IntentQueue.get(meeting_id, second.id) |> elem(1) |> Map.get(:status) == :queued
    end

    test "every advancing status releases the cursor", %{meeting_id: meeting_id} do
      for status <- IntentQueue.advancing_statuses() do
        row = enqueue!(meeting_id)
        {:ok, _} = IntentQueue.claim_next(meeting_id)
        {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
        assert IntentQueue.cursor(meeting_id) == row.id

        {:ok, _} = IntentQueue.transition(meeting_id, row.id, status)

        assert IntentQueue.cursor(meeting_id) == nil,
               "#{inspect(status)} did not release the cursor"
      end
    end

    test "deleting the cursor's row releases it", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      :ok = IntentQueue.delete(meeting_id, row.id)

      # A cursor pinned to a row that no longer exists would wedge the
      # meeting until its ack window expired.
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "a claim that is never committed releases the cursor" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 300)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      assert IntentQueue.cursor(meeting_id) == row.id

      # Models a dispatcher that died between claim and transition.
      # The row goes back to being claimable rather than inventing a
      # tenth status for "we tried to try".
      Process.sleep(500)

      assert IntentQueue.cursor(meeting_id) == nil
      assert IntentQueue.get(meeting_id, row.id) |> elem(1) |> Map.get(:status) == :queued
      assert {:ok, _} = IntentQueue.claim_next(meeting_id)
    end
  end

  # ── Ack ────────────────────────────────────────────────────────────────────

  describe "ack/5" do
    setup %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      %{row: dispatched}
    end

    test "working stamps the subagent and holds the cursor", %{
      meeting_id: meeting_id,
      row: row
    } do
      {:ok, acked} = IntentQueue.ack(meeting_id, row.id, "higgins.test-host", :working)

      assert acked.status == :acked
      assert acked.subagent_id == "higgins.test-host"
      assert %DateTime{} = acked.acked_at
      assert IntentQueue.cursor(meeting_id) == row.id
    end

    test "completed and rejected both land terminal and advance", %{
      meeting_id: meeting_id,
      row: setup_row
    } do
      # The setup already put one row in flight; reuse it for the
      # first status so the cursor is free for the second.
      rows = [{setup_row, :completed}, {nil, :rejected}]

      for {maybe_row, ack_status} <- rows do
        row =
          maybe_row ||
            (
              fresh = enqueue!(meeting_id)
              {:ok, _} = IntentQueue.claim_next(meeting_id)
              {:ok, dispatched} = IntentQueue.transition(meeting_id, fresh.id, :dispatched)
              dispatched
            )

        {:ok, done} = IntentQueue.ack(meeting_id, row.id, "sub", ack_status)

        # `:rejected` is not a tenth status — the target looked at the
        # intent and is done with it. The "wrong target" signal travels
        # on the correction hook, not on the row.
        assert done.status == :completed
        assert IntentQueue.cursor(meeting_id) == nil
      end
    end

    test "cancel_honored is :cancelled in flight and :cancelled_late after completion",
         %{meeting_id: meeting_id, row: row} do
      {:ok, cancelled} = IntentQueue.ack(meeting_id, row.id, "sub", :cancel_honored)
      assert cancelled.status == :cancelled
      assert %DateTime{} = cancelled.cancelled_at

      late = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, late.id, :dispatched)
      {:ok, _} = IntentQueue.ack(meeting_id, late.id, "sub", :completed)

      {:ok, late_row} = IntentQueue.ack(meeting_id, late.id, "sub", :cancel_honored)
      assert late_row.status == :cancelled_late
    end

    test "acking a queued row is refused", %{meeting_id: meeting_id} do
      queued = enqueue!(meeting_id, %{dedupe_key: unique("dk-queued")})

      assert {:error, {:invalid_ack_state, :queued}} =
               IntentQueue.ack(meeting_id, queued.id, "sub", :working)
    end

    test "an unknown ack status is refused without touching the row", %{
      meeting_id: meeting_id,
      row: row
    } do
      assert {:error, {:invalid_ack_status, :finished}} =
               IntentQueue.ack(meeting_id, row.id, "sub", :finished)

      assert IntentQueue.get(meeting_id, row.id) |> elem(1) == row
    end
  end

  # ── Ack timeout ────────────────────────────────────────────────────────────

  describe "ack timeout" do
    test "an unanswered dispatch times out amber" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 300)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      assert_receive {:intent_timed_out, timed_out}, 2_000
      assert timed_out.id == row.id
      assert timed_out.status == :timed_out
      assert %DateTime{} = timed_out.timed_out_at
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "rejected ack attempts make the same timeout red" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 300)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)

      assert_receive {:intent_no_ack_spawn_failed, failed}, 2_000
      assert failed.status == :no_ack_spawn_failed
      assert failed.dispatch_failure_reason == :subagent_spawn_rejected
    end

    test "record_rejected_ack/2 never mutates the row" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 60_000)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)
      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 2
      assert IntentQueue.get(meeting_id, row.id) |> elem(1) == dispatched
    end

    test "a completed row's rejected-ack bookkeeping is dropped with the cursor" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 60_000)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      :ok = IntentQueue.record_rejected_ack(meeting_id, row.id)

      {:ok, _} = IntentQueue.ack(meeting_id, row.id, "sub", :completed)

      # The counter is evidence about ONE in-flight dispatch. Keeping
      # it after the row resolves would be a slow leak for a
      # long-running meeting.
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 0
    end

    test "the ack window comes from application env when no opt is given" do
      meeting_id = unique_meeting_id()
      {:ok, _} = IntentQueue.ensure_started(meeting_id)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      assert Server.ack_timeout_ms(meeting_id) ==
               Application.get_env(:platform, Platform.Meetings.IntentQueue, [])
               |> Keyword.get(:queue_ack_timeout_ms, Server.default_ack_timeout_ms())
    end
  end

  # ── Intent-id reverse index ────────────────────────────────────────────────

  describe "locate/1" do
    test "resolves an intent id to its meeting", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)

      # The MCP tool only ever receives an intent id — a remote runtime
      # has no reason to know the meeting UUID.
      assert IntentQueue.locate(row.id) == {:ok, meeting_id}
    end

    test "is not_found for an unknown id" do
      assert IntentQueue.locate("no-such-intent") == {:error, :not_found}
    end

    test "dies with the meeting", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      :ok = IntentQueue.stop(meeting_id)

      # The index is registered by the queue owner, so it is reclaimed
      # exactly like the ETS table is — no stale pointers into a
      # meeting that ended.
      assert IntentQueue.locate(row.id) == {:error, :not_found}
    end

    test "a deleted row is unregistered", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      :ok = IntentQueue.delete(meeting_id, row.id)

      assert IntentQueue.locate(row.id) == {:error, :not_found}
    end
  end

  describe "live_meeting_ids/0" do
    test "lists meetings, not intent-index keys", %{meeting_id: meeting_id} do
      _row = enqueue!(meeting_id)

      ids = IntentQueue.live_meeting_ids()

      assert meeting_id in ids
      # The reverse index shares the Registry, so an unguarded select
      # would return `{:intent, id}` tuples here.
      assert Enum.all?(ids, &is_binary/1)
    end
  end
end
