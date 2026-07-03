defmodule Platform.MeetingsTest do
  @moduledoc """
  Tests for the top-level `Platform.Meetings` helpers added for the
  phantom LiveKit `RM_<random>` transcript guard + empty-transcript
  cleanup work (task 019f24e3):

    * `app_registered_room?/1` — cheap regex guard for the
      `space-<uuid>` naming convention. Used on the hot webhook path
      to reject events for rooms this app never registered.

    * `delete_transcript/1` — struct-or-id delete that returns
      `{:error, :not_found}` for missing / already-deleted / malformed
      inputs (so the cleanup handler is naturally idempotent).
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Transcript

  describe "app_registered_room?/1" do
    test "returns true for the canonical space-<uuid> pattern" do
      assert Meetings.app_registered_room?("space-019f24e3-e718-7521-ab33-f495b2e60c85")
    end

    test "returns true for any space- prefix followed by a valid uuid" do
      uuid = Ecto.UUID.generate()
      assert Meetings.app_registered_room?("space-#{uuid}")
    end

    test "rejects LiveKit auto-generated RM_<random> room names" do
      refute Meetings.app_registered_room?("RM_26KcSg8ZBUGd")
      refute Meetings.app_registered_room?("RM_abcdef123456")
    end

    test "rejects the empty string" do
      refute Meetings.app_registered_room?("")
    end

    test "rejects space- with a non-uuid suffix" do
      refute Meetings.app_registered_room?("space-not-a-uuid")
      refute Meetings.app_registered_room?("space-1234")
    end

    test "rejects the predecessor meeting-<uuid> naming" do
      uuid = Ecto.UUID.generate()
      refute Meetings.app_registered_room?("meeting-#{uuid}")
    end

    test "rejects non-binary inputs without raising" do
      refute Meetings.app_registered_room?(nil)
      refute Meetings.app_registered_room?(42)
      refute Meetings.app_registered_room?(:atom)
    end

    test "matches every room name produced by room_name_for_space/1" do
      space_id = Ecto.UUID.generate()
      name = Meetings.room_name_for_space(space_id)
      assert Meetings.app_registered_room?(name)
    end
  end

  describe "delete_transcript/1" do
    defp create_transcript(overrides \\ %{}) do
      attrs =
        Map.merge(
          %{room_id: "space-#{Ecto.UUID.generate()}", status: "recording"},
          overrides
        )

      {:ok, transcript} = Meetings.create_transcript(attrs)
      transcript
    end

    test "deletes an existing transcript struct" do
      transcript = create_transcript()

      assert {:ok, deleted} = Meetings.delete_transcript(transcript)
      assert deleted.id == transcript.id
      assert Meetings.get_transcript(transcript.id) == nil
    end

    test "deletes by string id" do
      transcript = create_transcript()

      assert {:ok, deleted} = Meetings.delete_transcript(transcript.id)
      assert deleted.id == transcript.id
      assert Meetings.get_transcript(transcript.id) == nil
    end

    test "returns {:error, :not_found} for an unknown uuid" do
      missing_id = Ecto.UUID.generate()
      assert Meetings.delete_transcript(missing_id) == {:error, :not_found}
    end

    test "returns {:error, :not_found} for a malformed id string" do
      assert Meetings.delete_transcript("not-a-uuid") == {:error, :not_found}
    end

    test "is idempotent — second delete returns :not_found" do
      transcript = create_transcript()

      assert {:ok, _} = Meetings.delete_transcript(transcript.id)
      assert Meetings.delete_transcript(transcript.id) == {:error, :not_found}
    end

    test "deleting a stale struct after the row is gone returns :not_found" do
      transcript = create_transcript()
      assert {:ok, _} = Meetings.delete_transcript(transcript)

      # `transcript` is now a stale struct pointing at a row that no
      # longer exists — the cleanup handler can plausibly call this
      # twice under retry.
      assert Meetings.delete_transcript(transcript) == {:error, :not_found}
    end

    test "matches the declared return spec — {:ok, %Transcript{}} on success" do
      transcript = create_transcript()
      assert {:ok, %Transcript{}} = Meetings.delete_transcript(transcript)
    end
  end

  describe "append_segment/2 — transcript_chunk broadcast (task 019f2452 stage 2)" do
    defp make_segment(text \\ "hello world") do
      %{
        "participant_identity" => "user-1",
        "text" => text,
        "start_time" => 0,
        "end_time" => 500
      }
    end

    defp make_transcript_for_room(room_id \\ nil) do
      room_id = room_id || "space-#{Ecto.UUID.generate()}"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id, status: "recording"})
      transcript
    end

    test "canonical subscriber receives a :transcript_chunk event after append" do
      transcript = make_transcript_for_room()
      segment = make_segment()
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "per-room subscriber receives its own room's chunk" do
      transcript = make_transcript_for_room()
      segment = make_segment("per-room hello")
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end

    test "per-room subscriber does NOT receive events from a different room" do
      transcript_a = make_transcript_for_room()
      transcript_b = make_transcript_for_room()

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(transcript_a.room_id)

      assert {:ok, %Transcript{}} =
               Meetings.append_segment(transcript_b.id, make_segment("wrong room"))

      refute_receive {:transcript_chunk, _}, 100

      MeetingsPubSub.unsubscribe_transcript_chunk(transcript_a.room_id)
    end

    test "returns {:error, :not_found} for a missing transcript and does NOT broadcast" do
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:error, :not_found} =
               Meetings.append_segment(Ecto.UUID.generate(), make_segment())

      refute_receive {:transcript_chunk, _}, 100

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "canonical + per-room subscribers both receive the same event" do
      transcript = make_transcript_for_room()
      segment = make_segment("dual delivery")
      transcript_id = transcript.id
      room_id = transcript.room_id

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk(room_id)

      assert {:ok, %Transcript{}} = Meetings.append_segment(transcript.id, segment)

      # Two deliveries (one per subscription).
      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: ^segment,
                        meeting_id: nil
                      }},
                     200

      MeetingsPubSub.unsubscribe_transcript_chunk()
      MeetingsPubSub.unsubscribe_transcript_chunk(room_id)
    end
  end
end
