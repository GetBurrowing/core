defmodule Platform.Meetings.PubSubTest do
  @moduledoc """
  Tests for `Platform.Meetings.PubSub` — topic helpers + broadcast
  fan-out for the Meetings domain.

  Focus is the transcript-chunk pair (task 019f2452 stage 2):
  canonical `meeting:transcript_chunk` + per-room
  `meeting:transcript_chunk:{room_id}` mirror the same pattern as
  `meeting:finished`, so we cover the dual-broadcast contract that
  the Meeting Producer classifier depends on.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  describe "transcript_chunk_topic/0 and /1" do
    test "returns the canonical string" do
      assert MeetingsPubSub.transcript_chunk_topic() == "meeting:transcript_chunk"
    end

    test "returns a per-room string" do
      assert MeetingsPubSub.transcript_chunk_topic("room-abc") ==
               "meeting:transcript_chunk:room-abc"
    end
  end

  describe "broadcast_transcript_chunk/2" do
    test "fires on the canonical topic" do
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      payload = %{
        room_id: "room-canonical",
        transcript_id: Ecto.UUID.generate(),
        segment: %{text: "hello world"},
        meeting_id: nil
      }

      assert :ok = MeetingsPubSub.broadcast_transcript_chunk("room-canonical", payload)

      assert_receive {:transcript_chunk, ^payload}, 200

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "fires on the per-room topic" do
      room_id = "room-per-room-#{System.unique_integer([:positive])}"
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      payload = %{
        room_id: room_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{text: "per-room segment"},
        meeting_id: nil
      }

      assert :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)

      assert_receive {:transcript_chunk, ^payload}, 200

      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end

    test "fires on BOTH topics for a single call" do
      room_id = "room-both-#{System.unique_integer([:positive])}"

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      payload = %{
        room_id: room_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{text: "both topics"},
        meeting_id: nil
      }

      assert :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)

      # Canonical delivery.
      assert_receive {:transcript_chunk, ^payload}, 200
      # Per-room delivery.
      assert_receive {:transcript_chunk, ^payload}, 200

      MeetingsPubSub.unsubscribe_transcript_chunk()
      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end

    test "per-room subscriber does NOT receive events from other rooms" do
      room_a = "room-a-#{System.unique_integer([:positive])}"
      room_b = "room-b-#{System.unique_integer([:positive])}"

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_a)

      payload = %{
        room_id: room_b,
        transcript_id: Ecto.UUID.generate(),
        segment: %{text: "wrong room"},
        meeting_id: nil
      }

      assert :ok = MeetingsPubSub.broadcast_transcript_chunk(room_b, payload)

      refute_receive {:transcript_chunk, _}, 100

      MeetingsPubSub.unsubscribe_transcript_chunk(room_a)
    end

    test "unsubscribe stops future deliveries" do
      room_id = "room-unsub-#{System.unique_integer([:positive])}"

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)
      assert :ok = MeetingsPubSub.unsubscribe_transcript_chunk(room_id)

      payload = %{
        room_id: room_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{text: "post-unsubscribe"},
        meeting_id: nil
      }

      assert :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)

      refute_receive {:transcript_chunk, _}, 100
    end
  end
end
