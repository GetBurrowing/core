defmodule Platform.Meetings.IntentQueueTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentQueue` — ETS-backed staging area
  for classified transcript intents (task 019f2452 stage 1).

  Covers:
    * `enqueue/3` happy path + idempotence via composite key
    * `pop_batch/2` returns + removes items
    * `drop_for_room/1` scoped delete
    * `:meeting_finished` broadcast triggers cleanup
    * Periodic sweep removes stale entries + preserves fresh ones

  Async-false because the module owns a single named ETS table that's
  started under `Platform.Application`'s supervision tree.
  """

  use ExUnit.Case, async: false

  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  @rooms ~w(intentq-room-a intentq-room-b intentq-room-sweep intentq-room-fin)

  setup do
    on_exit(fn ->
      for room <- @rooms, do: IntentQueue.drop_for_room(room)
    end)

    :ok
  end

  # Attach a telemetry handler that forwards the event to `self()` under
  # `tag`. Detached automatically via `on_exit`. Mirrors the pattern used
  # in `intent_classifier_test.exs`.
  defp attach_telemetry!(event, tag) do
    handler_id = "intent-queue-test-#{tag}-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      event,
      fn _e, measurements, metadata, _ ->
        send(parent, {tag, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp sample_item(overrides \\ %{}) do
    Map.merge(
      %{
        intent: :create_task,
        target_role: :engineering,
        confidence: 0.87,
        chunk_id: "chunk-1",
        meeting_id: "meeting-abc"
      },
      overrides
    )
  end

  describe "enqueue/3" do
    test "first insert returns {:ok, :inserted} and shows up in list_for_room/1" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert [%{intent: :create_task, chunk_id: "chunk-1"}] =
               IntentQueue.list_for_room("intentq-room-a")
    end

    test "second insert with same {room_id, dedupe_key} returns :duplicate and does not add a row" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert {:ok, :duplicate} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "dedupe-1",
                 sample_item(%{chunk_id: "chunk-2"})
               )

      # Still exactly one row, and it's the original.
      items = IntentQueue.list_for_room("intentq-room-a")
      assert length(items) == 1
      assert [%{chunk_id: "chunk-1"}] = items
    end

    test "different dedupe_key in the same room creates a second row" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert {:ok, :inserted} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "dedupe-2",
                 sample_item(%{chunk_id: "chunk-2"})
               )

      chunk_ids =
        "intentq-room-a"
        |> IntentQueue.list_for_room()
        |> Enum.map(& &1.chunk_id)
        |> Enum.sort()

      assert chunk_ids == ["chunk-1", "chunk-2"]
    end

    test "same dedupe_key across different rooms creates two rows (composite key)" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-b", "dedupe-1", sample_item())

      assert length(IntentQueue.list_for_room("intentq-room-a")) == 1
      assert length(IntentQueue.list_for_room("intentq-room-b")) == 1
    end

    test "stamps :inserted_at_monotonic when caller omits it" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      [item] = IntentQueue.list_for_room("intentq-room-a")
      assert is_integer(item.inserted_at_monotonic)
    end

    test "preserves caller-provided :inserted_at_monotonic (test override for sweep)" do
      old_ts = System.monotonic_time(:millisecond) - :timer.hours(2)

      assert {:ok, :inserted} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "dedupe-old",
                 sample_item(%{inserted_at_monotonic: old_ts})
               )

      [item] = IntentQueue.list_for_room("intentq-room-a")
      assert item.inserted_at_monotonic == old_ts
    end
  end

  describe "pop_batch/2" do
    test "returns up to `limit` items and removes them from the table" do
      for i <- 1..5 do
        IntentQueue.enqueue(
          "intentq-room-a",
          "dedupe-#{i}",
          sample_item(%{chunk_id: "chunk-#{i}"})
        )
      end

      first_batch = IntentQueue.pop_batch("intentq-room-a", 3)
      assert length(first_batch) == 3
      assert length(IntentQueue.list_for_room("intentq-room-a")) == 2

      second_batch = IntentQueue.pop_batch("intentq-room-a", 10)
      assert length(second_batch) == 2
      assert IntentQueue.list_for_room("intentq-room-a") == []

      # Union of both batches covers every original chunk_id.
      all_chunk_ids =
        (first_batch ++ second_batch)
        |> Enum.map(& &1.chunk_id)
        |> Enum.sort()

      assert all_chunk_ids == ["chunk-1", "chunk-2", "chunk-3", "chunk-4", "chunk-5"]
    end

    test "returns [] when the room has no entries" do
      assert IntentQueue.pop_batch("intentq-room-a", 5) == []
    end

    test "does not touch other rooms' rows" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      IntentQueue.enqueue("intentq-room-b", "d1", sample_item())

      _ = IntentQueue.pop_batch("intentq-room-a", 10)

      assert IntentQueue.list_for_room("intentq-room-a") == []
      assert length(IntentQueue.list_for_room("intentq-room-b")) == 1
    end
  end

  describe "drop_for_room/1" do
    test "removes all entries for the room and leaves other rooms untouched" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      IntentQueue.enqueue("intentq-room-a", "d2", sample_item())
      IntentQueue.enqueue("intentq-room-b", "d1", sample_item())

      assert :ok = IntentQueue.drop_for_room("intentq-room-a")

      assert IntentQueue.list_for_room("intentq-room-a") == []
      assert length(IntentQueue.list_for_room("intentq-room-b")) == 1
    end

    test "is a no-op for a room with no entries" do
      assert :ok = IntentQueue.drop_for_room("intentq-room-a")
      assert IntentQueue.list_for_room("intentq-room-a") == []
    end
  end

  describe "telemetry" do
    test "enqueue fires [:platform, :meetings, :intent_queue, :enqueue] with result :inserted" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :enqueue], :queue_enqueue)

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert_receive {:queue_enqueue, %{count: 1},
                      %{
                        result: :inserted,
                        room_id: "intentq-room-a",
                        dedupe_key: "dedupe-1"
                      }},
                     500
    end

    test "enqueue fires the same event with result :duplicate on repeat" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :enqueue], :queue_enqueue)

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-1", sample_item())

      assert_receive {:queue_enqueue, _, %{result: :inserted}}, 500

      assert {:ok, :duplicate} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "dedupe-1",
                 sample_item(%{chunk_id: "chunk-2"})
               )

      assert_receive {:queue_enqueue, %{count: 1},
                      %{
                        result: :duplicate,
                        room_id: "intentq-room-a",
                        dedupe_key: "dedupe-1"
                      }},
                     500
    end

    test "drop_for_room/1 fires [:platform, :meetings, :intent_queue, :drop] with removed_count" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :drop], :queue_drop)

      # Populate three entries so `removed_count` is a distinctive value.
      for i <- 1..3 do
        IntentQueue.enqueue("intentq-room-a", "dedupe-#{i}", sample_item())
      end

      assert :ok = IntentQueue.drop_for_room("intentq-room-a")

      assert_receive {:queue_drop, %{count: 3}, %{room_id: "intentq-room-a", removed_count: 3}},
                     500
    end

    test "drop_for_room/1 on empty room still fires with removed_count 0" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :drop], :queue_drop)

      assert :ok = IntentQueue.drop_for_room("intentq-room-a")

      assert_receive {:queue_drop, %{count: 0}, %{room_id: "intentq-room-a", removed_count: 0}},
                     500
    end

    test "meeting:finished handler routes through the same drop telemetry (no deadlock)" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :drop], :queue_drop)

      IntentQueue.enqueue("intentq-room-fin", "d1", sample_item())
      IntentQueue.enqueue("intentq-room-fin", "d2", sample_item())

      :ok =
        MeetingsPubSub.broadcast_meeting_finished("intentq-room-fin", %{
          transcript_id: "t1",
          room_id: "intentq-room-fin",
          space_id: "s1"
        })

      assert_receive {:queue_drop, %{count: 2}, %{room_id: "intentq-room-fin", removed_count: 2}},
                     1_000

      # Queue owner survived — no deadlock from the previous synchronous
      # self-call trap.
      assert Process.alive?(Process.whereis(IntentQueue))
    end
  end

  describe "meeting:finished broadcast" do
    test "receiving {:meeting_finished, %{room_id: id}} drops entries for that room" do
      IntentQueue.enqueue("intentq-room-fin", "d1", sample_item())
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      assert length(IntentQueue.list_for_room("intentq-room-fin")) == 1

      # Publish on the canonical topic — the IntentQueue booted by the
      # application supervisor subscribes to it via init/1.
      :ok =
        MeetingsPubSub.broadcast_meeting_finished("intentq-room-fin", %{
          transcript_id: "t1",
          room_id: "intentq-room-fin",
          space_id: "s1"
        })

      # The cleanup happens in the queue's handle_info. Poll ETS
      # (via list_for_room) until the deletion lands — bounded so a
      # broken subscription still fails the assertion, not the whole
      # test run.
      Process.sleep(50)
      assert IntentQueue.list_for_room("intentq-room-fin") == []

      # Untouched room stays put.
      assert length(IntentQueue.list_for_room("intentq-room-a")) == 1
    end
  end

  describe "sweep" do
    test "removes rows older than the max-age cutoff and preserves fresh ones" do
      # Old row: stamped 90 minutes in the past (well past the 30-min cap).
      old_ts = System.monotonic_time(:millisecond) - :timer.minutes(90)

      IntentQueue.enqueue(
        "intentq-room-sweep",
        "dedupe-old",
        sample_item(%{
          chunk_id: "old-chunk",
          inserted_at_monotonic: old_ts
        })
      )

      # Fresh row: default (now).
      IntentQueue.enqueue(
        "intentq-room-sweep",
        "dedupe-fresh",
        sample_item(%{chunk_id: "fresh-chunk"})
      )

      assert length(IntentQueue.list_for_room("intentq-room-sweep")) == 2

      # Trigger the sweep directly so we don't wait 30 minutes for the
      # timer.
      send(Process.whereis(IntentQueue), :sweep)
      Process.sleep(50)

      remaining = IntentQueue.list_for_room("intentq-room-sweep")
      assert length(remaining) == 1
      assert [%{chunk_id: "fresh-chunk"}] = remaining
    end
  end

  # ── Dispatcher-facing API (task 019f2452 stage 1) ──────────────────────────

  describe "enqueue/3 default retry fields" do
    test "stamps :status => :pending and :attempts => 0 by default" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "d1", sample_item())

      [item] = IntentQueue.list_for_room("intentq-room-a")
      assert item.status == :pending
      assert item.attempts == 0
    end

    test "preserves caller-provided :status / :attempts overrides" do
      assert {:ok, :inserted} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "d1",
                 sample_item(%{status: :dispatching, attempts: 2})
               )

      [item] = IntentQueue.list_for_room("intentq-room-a")
      assert item.status == :dispatching
      assert item.attempts == 2
    end
  end

  describe "enqueue/3 intent_enqueued broadcast" do
    test "publishes {:intent_enqueued, %{room_id, dedupe_key}} on the canonical topic" do
      assert :ok = MeetingsPubSub.subscribe_intent_enqueued()

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-broadcast", sample_item())

      assert_receive {:intent_enqueued,
                      %{room_id: "intentq-room-a", dedupe_key: "dedupe-broadcast"}},
                     500

      MeetingsPubSub.unsubscribe_intent_enqueued()
    end

    test "duplicate enqueue does NOT re-broadcast" do
      assert :ok = MeetingsPubSub.subscribe_intent_enqueued()

      assert {:ok, :inserted} =
               IntentQueue.enqueue("intentq-room-a", "dedupe-once", sample_item())

      assert_receive {:intent_enqueued, %{dedupe_key: "dedupe-once"}}, 500

      # Second enqueue with same key is a dedupe hit — the dispatcher
      # already has (or already dispatched) the target row, so a
      # re-notify would just spam it.
      assert {:ok, :duplicate} =
               IntentQueue.enqueue(
                 "intentq-room-a",
                 "dedupe-once",
                 sample_item(%{chunk_id: "chunk-2"})
               )

      refute_receive {:intent_enqueued, _}, 100

      MeetingsPubSub.unsubscribe_intent_enqueued()
    end
  end

  describe "claim_pending/1" do
    test "returns pending rows and transitions them to :dispatching" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item(%{chunk_id: "c1"}))
      IntentQueue.enqueue("intentq-room-a", "d2", sample_item(%{chunk_id: "c2"}))

      claims = IntentQueue.claim_pending(10)
      assert length(claims) == 2

      chunk_ids =
        claims
        |> Enum.map(fn {_, _, item} -> item.chunk_id end)
        |> Enum.sort()

      assert chunk_ids == ["c1", "c2"]

      # Post-claim state: rows still exist, status is :dispatching,
      # and claimed_at is stamped.
      remaining = IntentQueue.list_for_room("intentq-room-a")
      assert length(remaining) == 2
      assert Enum.all?(remaining, &(&1.status == :dispatching))
      assert Enum.all?(remaining, &is_integer(&1.claimed_at_monotonic))
    end

    test "does NOT return already-claimed rows on subsequent calls" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      IntentQueue.enqueue("intentq-room-a", "d2", sample_item())

      first = IntentQueue.claim_pending(10)
      assert length(first) == 2

      second = IntentQueue.claim_pending(10)
      assert second == []
    end

    test "respects the limit argument" do
      for i <- 1..5 do
        IntentQueue.enqueue("intentq-room-a", "d#{i}", sample_item(%{chunk_id: "c#{i}"}))
      end

      first_batch = IntentQueue.claim_pending(3)
      assert length(first_batch) == 3

      second_batch = IntentQueue.claim_pending(3)
      assert length(second_batch) == 2
    end

    test "returns [] when there are no pending rows" do
      assert IntentQueue.claim_pending(10) == []
    end

    test "scans across all rooms" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item(%{chunk_id: "a1"}))
      IntentQueue.enqueue("intentq-room-b", "d1", sample_item(%{chunk_id: "b1"}))

      claims = IntentQueue.claim_pending(10)
      rooms = claims |> Enum.map(fn {r, _, _} -> r end) |> Enum.sort()
      assert rooms == ["intentq-room-a", "intentq-room-b"]
    end

    test "treats a row missing :status as :pending (legacy backward compat)" do
      # Simulate a row inserted before stage 1 shipped: no :status,
      # no :attempts. Bypass enqueue/3 (which stamps defaults) and
      # write directly to the ETS table so we can prove the read
      # path handles the missing key.
      :ets.insert(
        :meeting_intent_queue,
        {{"intentq-room-a", "legacy"},
         %{
           intent: :create_task,
           target_role: :engineering,
           confidence: 0.9,
           chunk_id: "legacy-chunk",
           inserted_at_monotonic: System.monotonic_time(:millisecond),
           meeting_id: "meeting-legacy"
         }}
      )

      claims = IntentQueue.claim_pending(10)

      assert [{"intentq-room-a", "legacy", %{chunk_id: "legacy-chunk", status: :dispatching}}] =
               claims
    end

    test "concurrent claims — three-item queue, five racing callers, exactly three succeed" do
      for i <- 1..3 do
        IntentQueue.enqueue("intentq-room-a", "d#{i}", sample_item(%{chunk_id: "c#{i}"}))
      end

      # Five racing tasks each try to claim two items. Because
      # claim_pending is serialised through GenServer.call/2, exactly
      # three rows total will be handed out across all tasks.
      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> IntentQueue.claim_pending(2) end)
        end)
        |> Enum.map(&Task.await/1)

      claimed_keys =
        results
        |> List.flatten()
        |> Enum.map(fn {_, dk, _} -> dk end)
        |> Enum.sort()

      assert claimed_keys == ["d1", "d2", "d3"]
    end
  end

  describe "mark_dispatched/2" do
    test "removes the row from the queue" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      [{room_id, dedupe_key, _}] = IntentQueue.claim_pending(10)

      assert :ok = IntentQueue.mark_dispatched(room_id, dedupe_key)

      assert IntentQueue.list_for_room("intentq-room-a") == []
    end

    test "is idempotent — a repeat call is :ok" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      assert :ok = IntentQueue.mark_dispatched("intentq-room-a", "d1")
      assert :ok = IntentQueue.mark_dispatched("intentq-room-a", "d1")
    end

    test "no-op on a row that never existed" do
      assert :ok = IntentQueue.mark_dispatched("intentq-room-a", "never-was")
    end
  end

  describe "mark_retry/3" do
    test "increments :attempts, resets :status to :pending, and stamps last_error" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      [{room_id, dedupe_key, _}] = IntentQueue.claim_pending(10)

      assert {:ok, 1} = IntentQueue.mark_retry(room_id, dedupe_key, :simulated_transport)

      [item] = IntentQueue.list_for_room("intentq-room-a")
      assert item.attempts == 1
      assert item.status == :pending
      assert item.last_error == inspect(:simulated_transport)
      # `list_stalled/1` guard: claimed_at is cleared on retry so the
      # sweep doesn't flag a healthy pending row.
      assert item.claimed_at_monotonic == nil
    end

    test "allows a retried row to be re-claimed" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      [{room_id, dedupe_key, _}] = IntentQueue.claim_pending(10)

      assert {:ok, 1} = IntentQueue.mark_retry(room_id, dedupe_key, :retry)

      # Same row shows up on the next claim because status is back to
      # :pending.
      assert [{^room_id, ^dedupe_key, %{attempts: 1, status: :dispatching}}] =
               IntentQueue.claim_pending(10)
    end

    test "returns {:exhausted, attempts} on the 3rd attempt" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      [{room_id, dedupe_key, _}] = IntentQueue.claim_pending(10)

      assert {:ok, 1} = IntentQueue.mark_retry(room_id, dedupe_key, :fail_1)

      # Re-claim to simulate the dispatcher walking through attempts.
      [{^room_id, ^dedupe_key, _}] = IntentQueue.claim_pending(10)
      assert {:ok, 2} = IntentQueue.mark_retry(room_id, dedupe_key, :fail_2)

      [{^room_id, ^dedupe_key, _}] = IntentQueue.claim_pending(10)
      assert {:exhausted, 3} = IntentQueue.mark_retry(room_id, dedupe_key, :fail_3)
    end

    test "returns {:error, :not_found} for a missing row" do
      assert {:error, :not_found} =
               IntentQueue.mark_retry("intentq-room-a", "never-was", :anything)
    end
  end

  describe "mark_dropped/3" do
    test "removes the row" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      assert :ok = IntentQueue.mark_dropped("intentq-room-a", "d1", :no_assignee)
      assert IntentQueue.list_for_room("intentq-room-a") == []
    end

    test "fires drop telemetry with the supplied reason" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :drop], :queue_drop)

      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())

      assert :ok = IntentQueue.mark_dropped("intentq-room-a", "d1", :max_attempts_exceeded)

      assert_receive {:queue_drop, %{count: 1},
                      %{
                        room_id: "intentq-room-a",
                        dedupe_key: "d1",
                        reason: :max_attempts_exceeded,
                        removed_count: 1
                      }},
                     500
    end

    test "no-op on a missing row does NOT fire telemetry" do
      attach_telemetry!([:platform, :meetings, :intent_queue, :drop], :queue_drop_noop)

      assert :ok = IntentQueue.mark_dropped("intentq-room-a", "never-was", :no_assignee)
      refute_receive {:queue_drop_noop, _, _}, 100
    end
  end

  describe "list_stalled/1" do
    test "returns rows whose claimed_at is older than the stall window" do
      # Enqueue and claim so status is :dispatching. Manually rewind
      # claimed_at_monotonic to before the stall cutoff so the sweep
      # will flag it. We can't wait real time here.
      IntentQueue.enqueue("intentq-room-a", "old", sample_item())
      IntentQueue.enqueue("intentq-room-a", "fresh", sample_item())
      _ = IntentQueue.claim_pending(10)

      old_ts = System.monotonic_time(:millisecond) - :timer.seconds(10)

      # Rewind the "old" row's claimed_at via a direct ETS update —
      # the queue's public API doesn't expose a manual rewind because
      # in production only the passage of time gets a row here.
      [{key, item}] = :ets.lookup(:meeting_intent_queue, {"intentq-room-a", "old"})
      :ets.insert(:meeting_intent_queue, {key, Map.put(item, :claimed_at_monotonic, old_ts)})

      stalled = IntentQueue.list_stalled(:timer.seconds(5))

      assert stalled == [{"intentq-room-a", "old"}]
    end

    test "returns [] when nothing is claimed" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      # Not claimed → :status is :pending → not stalled.
      assert IntentQueue.list_stalled(:timer.seconds(5)) == []
    end

    test "returns [] when claimed rows are still inside the stall window" do
      IntentQueue.enqueue("intentq-room-a", "d1", sample_item())
      _ = IntentQueue.claim_pending(10)

      # Big stall window — the claim was moments ago, well within.
      assert IntentQueue.list_stalled(:timer.hours(1)) == []
    end
  end

  describe "max_attempts/0" do
    test "reflects the module attribute" do
      assert IntentQueue.max_attempts() == 3
    end
  end
end
