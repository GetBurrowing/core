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
end
