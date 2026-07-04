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

  alias Platform.Chat
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

  describe "stamp_router_dispatched/1 (task 019f2566 stage 1)" do
    defp create_processing_transcript do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      transcript
    end

    test "sets router_dispatched_at to a UTC datetime on the matching row" do
      transcript = create_processing_transcript()
      assert is_nil(transcript.router_dispatched_at)

      before = DateTime.utc_now()
      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      later = DateTime.utc_now()

      reloaded = Meetings.get_transcript(transcript.id)
      assert %DateTime{} = reloaded.router_dispatched_at

      # Stamped time falls within the call window.
      assert DateTime.compare(reloaded.router_dispatched_at, before) in [:eq, :gt]
      assert DateTime.compare(reloaded.router_dispatched_at, later) in [:eq, :lt]
    end

    test "returns {0, nil} for an unknown transcript id" do
      missing_id = Ecto.UUID.generate()
      assert {0, nil} = Meetings.stamp_router_dispatched(missing_id)
    end

    test "second call re-stamps to a newer timestamp" do
      transcript = create_processing_transcript()

      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      first = Meetings.get_transcript(transcript.id).router_dispatched_at

      # Force a monotonic gap so the re-stamp is strictly newer.
      Process.sleep(2)

      assert {1, nil} = Meetings.stamp_router_dispatched(transcript.id)
      second = Meetings.get_transcript(transcript.id).router_dispatched_at

      assert DateTime.compare(second, first) == :gt
    end
  end

  describe "list_stalled_router_dispatches/1 (task 019f2566 stage 2)" do
    defp create_stalled_transcript(offset_ms) do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Transcript, where: t.id == ^transcript.id),
          set: [router_dispatched_at: DateTime.add(DateTime.utc_now(), offset_ms, :millisecond)]
        )

      Meetings.get_transcript(transcript.id)
    end

    test "returns processing transcripts whose router_dispatched_at is older than the window" do
      stale = create_stalled_transcript(-500)
      _fresh = create_stalled_transcript(-50)

      results = Meetings.list_stalled_router_dispatches(200)

      assert Enum.any?(results, &(&1.id == stale.id))
      refute Enum.empty?(results)
    end

    test "excludes fresh dispatches (within the window)" do
      fresh = create_stalled_transcript(-50)

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == fresh.id))
    end

    test "excludes transcripts whose status is not processing" do
      {:ok, done} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "complete",
          summary: "ok"
        })

      {1, nil} =
        Platform.Repo.update_all(
          from(t in Transcript, where: t.id == ^done.id),
          set: [router_dispatched_at: DateTime.add(DateTime.utc_now(), -600, :millisecond)]
        )

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == done.id))
    end

    test "excludes transcripts whose router_dispatched_at IS NULL" do
      # Stage 2 covers "router fired but stalled" only. A transcript
      # with NULL router_dispatched_at means the router never fired —
      # the belt-and-braces path is deferred to a later stage.
      {:ok, never_dispatched} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      results = Meetings.list_stalled_router_dispatches(200)

      refute Enum.any?(results, &(&1.id == never_dispatched.id))
    end

    test "returns an empty list when no dispatches are stalled" do
      _fresh = create_stalled_transcript(-50)

      assert Meetings.list_stalled_router_dispatches(1_000) == []
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

  describe "post_fallback_notice/3 (task 019f2566 stage 5)" do
    defp create_execution_space! do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      space
    end

    defp find_fallback_notice(space_id, transcript_id) do
      space_id
      |> Chat.list_messages()
      |> Kernel.||([])
      |> Enum.find(fn m ->
        m.metadata["source"] == "meeting_summarizer_fallback" and
          m.metadata["transcript_id"] == transcript_id
      end)
    end

    test "posts a system message naming the previously-assigned agent slug" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-alpha",
                 stalled_for_ms: 12 * 60 * 1_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg, "expected a fallback notice message in the space"
      assert msg.content_type == "system"
      # Legacy `@slug` mention — decorated as-highlighted by ContentRenderer.
      assert msg.content =~ "@scribe-alpha"
      # Human-readable stall window renders in minutes for a 12-minute stall.
      assert msg.content =~ "12 minutes"
      # Deep-link to Control Center → Roles so operators can reassign fast.
      assert msg.content =~ "/control-center/roles"
      # Metadata mirrors the notice for downstream audit consumers.
      assert msg.metadata["mode"] == "completed"
      assert msg.metadata["previously_assigned_agent"] == "scribe-alpha"
    end

    test "degrades gracefully when previously_assigned_agent is nil" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: nil,
                 stalled_for_ms: 60 * 60 * 1_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "The assigned summarizer"
      refute msg.content =~ "@"
      assert msg.content =~ "1 hour"
    end

    test "uses the `also_failed` copy when mode is :also_failed" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-beta",
                 stalled_for_ms: 90 * 60 * 1_000,
                 mode: :also_failed
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "Summary fallback also failed"
      assert msg.content =~ "@scribe-beta"
      # 90 minutes → "1 hour" rounding is fine; the important assertion is
      # the shape of the "also failed" copy and its link back to Roles.
      assert msg.content =~ "/control-center/roles"
      assert msg.metadata["mode"] == "also_failed"
    end

    test "returns {:error, ...} for a space that does not exist" do
      transcript_id = Platform.Types.UUIDv7.generate()

      assert {:error, _} =
               Meetings.post_fallback_notice(Ecto.UUID.generate(), transcript_id, %{
                 previously_assigned_agent: "scribe-gamma",
                 stalled_for_ms: 1_000
               })
    end

    test "renders sub-minute stalls in seconds" do
      space = create_execution_space!()
      transcript_id = Platform.Types.UUIDv7.generate()

      assert :ok =
               Meetings.post_fallback_notice(space.id, transcript_id, %{
                 previously_assigned_agent: "scribe-delta",
                 stalled_for_ms: 47_000
               })

      msg = find_fallback_notice(space.id, transcript_id)
      assert msg
      assert msg.content =~ "47 seconds"
    end
  end
end
