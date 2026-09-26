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

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Roles

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

  describe "legit_room?/1 (task 019f3312 stage 1)" do
    # `legit_room?/1` is the tightened successor to `app_registered_room?/1`
    # for the LiveKit webhook hot path. Regex + chat_spaces existence
    # check closes the "well-formed `space-<uuid>` name pointing at a
    # non-existent space" attack observed in the phantom-flood incident
    # (curl-forged webhook deliveries with UUIDs that no Suite space had
    # ever registered).

    defp create_chat_space! do
      {:ok, space} =
        Chat.create_space(%{
          name: "Legit Room Test Space",
          slug: "legit-room-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      space
    end

    test "returns true for a payload whose name matches a real chat_space" do
      space = create_chat_space!()
      name = Meetings.room_name_for_space(space.id)

      assert Meetings.legit_room?(%{"name" => name, "sid" => "RM_anything"})
    end

    test "returns true even without sid when the name resolves" do
      space = create_chat_space!()
      name = Meetings.room_name_for_space(space.id)

      assert Meetings.legit_room?(%{"name" => name})
    end

    test "returns false for a well-formed space-<uuid> with NO matching chat_space" do
      # Bug 2 fix: the old regex-only guard accepted these. Attacker
      # curl'd exactly this shape (well-formed random UUID) at prod and
      # spawned phantom transcripts en masse.
      fake_uuid = Ecto.UUID.generate()

      refute Meetings.legit_room?(%{
               "name" => "space-#{fake_uuid}",
               "sid" => "RM_forged_by_attacker"
             })
    end

    test "returns false for LiveKit auto-generated RM_<random> names" do
      refute Meetings.legit_room?(%{"name" => "RM_26KcSg8ZBUGd", "sid" => "RM_26KcSg8ZBUGd"})
    end

    test "returns false for space- with a non-uuid suffix" do
      refute Meetings.legit_room?(%{"name" => "space-not-a-uuid", "sid" => "RM_x"})
      refute Meetings.legit_room?(%{"name" => "space-1234", "sid" => "RM_x"})
    end

    test "returns false for the predecessor meeting-<uuid> naming" do
      # Even if a chat_space happens to exist with the same UUID, the
      # `meeting-` prefix is not the app-controlled contract.
      space = create_chat_space!()
      refute Meetings.legit_room?(%{"name" => "meeting-#{space.id}", "sid" => "RM_x"})
    end

    test "returns false when name is missing entirely" do
      refute Meetings.legit_room?(%{"sid" => "RM_only_sid"})
    end

    test "returns false when name is nil" do
      refute Meetings.legit_room?(%{"name" => nil, "sid" => "RM_x"})
    end

    test "returns false for malformed / non-map payloads" do
      refute Meetings.legit_room?(nil)
      refute Meetings.legit_room?("space-abc")
      refute Meetings.legit_room?(%{})
      refute Meetings.legit_room?(42)
    end

    test "reproduces the investigator's curl payload — bogus name, no space" do
      # Reproduction of the exact attacker payload shape from the
      # investigator's report — a `space-<random-uuid>` that no Suite
      # space had ever registered. The regex-only guard accepted this;
      # the tightened guard rejects it.
      curl_payload = %{
        "name" => "space-00000000-0000-0000-0000-000000000000",
        "sid" => "RM_curl_repro"
      }

      refute Meetings.legit_room?(curl_payload)
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

  describe "room-wide transcript lookups (task 019ff6f3 stage 1)" do
    # Every id and every line of speech below is invented.
    defp invented_room, do: "space-#{Ecto.UUID.generate()}"

    defp invented_segments(n) do
      for i <- 1..n do
        %{
          "participant_identity" => "participant-#{i}",
          "speaker_name" => "Speaker #{i}",
          "text" => "Invented line number #{i} for this fixture.",
          "start_time" => i * 1000,
          "end_time" => i * 1000 + 500
        }
      end
    end

    # `inserted_at` is set by `timestamps/0` and is not castable through the
    # changeset, so the fixture pins it with an explicit update. Relying on
    # wall-clock ordering between two inserts would make the ordering that
    # this whole describe block is about depend on clock resolution.
    defp transcript_at(room_id, segment_count, %DateTime{} = inserted_at, status \\ "recording") do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: room_id,
          status: status,
          segments: invented_segments_or_empty(segment_count)
        })

      {1, nil} =
        Repo.update_all(
          from(t in Transcript, where: t.id == ^transcript.id),
          set: [inserted_at: inserted_at]
        )

      Meetings.get_transcript(transcript.id)
    end

    defp invented_segments_or_empty(0), do: []
    defp invented_segments_or_empty(n), do: invented_segments(n)

    # The load-bearing fixture: one populated row, then an EMPTY row inserted
    # strictly later. This is the shape that today's `desc: inserted_at`
    # lookup gets wrong.
    defp shadowed_room do
      room_id = invented_room()
      base = ~U[2026-01-01 10:00:00.000000Z]

      populated = transcript_at(room_id, 7, base)
      empty = transcript_at(room_id, 0, DateTime.add(base, 600, :second))

      {room_id, populated, empty}
    end

    test "list_transcripts_for_room/1 returns every row oldest first, any status" do
      room_id = invented_room()
      base = ~U[2026-01-01 10:00:00.000000Z]

      first = transcript_at(room_id, 3, base, "failed")
      second = transcript_at(room_id, 0, DateTime.add(base, 60, :second), "complete")
      third = transcript_at(room_id, 1, DateTime.add(base, 120, :second), "recording")

      # A different room's row must not leak in.
      _other = transcript_at(invented_room(), 5, base)

      assert [first.id, second.id, third.id] ==
               Enum.map(Meetings.list_transcripts_for_room(room_id), & &1.id)
    end

    test "list_transcripts_for_room/1 is [] for a room with no rows" do
      assert Meetings.list_transcripts_for_room(invented_room()) == []
    end

    test "room_has_segments?/1 is true when only the OLDER row is populated" do
      {room_id, _populated, empty} = shadowed_room()

      # Anti-vacuity: the newest row really is the empty one, so a per-row
      # check on the newest row would answer false here.
      assert empty.segments == []
      assert Meetings.room_has_segments?(room_id)
    end

    test "room_has_segments?/1 is false when every row of the room is empty" do
      room_id = invented_room()
      base = ~U[2026-01-01 10:00:00.000000Z]
      transcript_at(room_id, 0, base)
      transcript_at(room_id, 0, DateTime.add(base, 60, :second))

      refute Meetings.room_has_segments?(room_id)
    end

    test "room_has_segments?/1 is false for an unknown room and ignores other rooms" do
      populated_room = invented_room()
      transcript_at(populated_room, 4, ~U[2026-01-01 10:00:00.000000Z])

      refute Meetings.room_has_segments?(invented_room())
      assert Meetings.room_has_segments?(populated_room)
    end

    test "get_summarizable_transcript_for_room/1 picks the populated row when the EMPTY row is newest" do
      {room_id, populated, empty} = shadowed_room()

      assert DateTime.compare(empty.inserted_at, populated.inserted_at) == :gt

      selected = Meetings.get_summarizable_transcript_for_room(room_id)

      assert selected.id == populated.id,
             "expected the populated row #{populated.id} (7 segments), got #{selected.id} " <>
               "with #{length(selected.segments)} segments"
    end

    test "get_summarizable_transcript_for_room/1 direction control: same answer when the populated row is NEWEST" do
      # If this passed but the case above failed, the implementation is
      # ordering by recency and the pair of tests is what detects it.
      room_id = invented_room()
      base = ~U[2026-01-01 10:00:00.000000Z]

      empty = transcript_at(room_id, 0, base)
      populated = transcript_at(room_id, 7, DateTime.add(base, 600, :second))

      assert DateTime.compare(populated.inserted_at, empty.inserted_at) == :gt

      selected = Meetings.get_summarizable_transcript_for_room(room_id)

      assert selected.id == populated.id,
             "expected the populated row #{populated.id} (7 segments), got #{selected.id} " <>
               "with #{length(selected.segments)} segments"
    end

    test "get_summarizable_transcript_for_room/1 breaks a segment-count tie toward the OLDEST row" do
      room_id = invented_room()
      base = ~U[2026-01-01 10:00:00.000000Z]

      oldest = transcript_at(room_id, 4, base)
      _newer = transcript_at(room_id, 4, DateTime.add(base, 300, :second))

      assert Meetings.get_summarizable_transcript_for_room(room_id).id == oldest.id
    end

    test "get_summarizable_transcript_for_room/1 returns a terminal-status row rather than nil" do
      room_id = invented_room()
      failed = transcript_at(room_id, 9, ~U[2026-01-01 10:00:00.000000Z], "failed")

      selected = Meetings.get_summarizable_transcript_for_room(room_id)
      assert selected.id == failed.id
      assert selected.status == "failed"
    end

    test "get_summarizable_transcript_for_room/1 is nil for a room with no rows" do
      assert Meetings.get_summarizable_transcript_for_room(invented_room()) == nil
    end

    test "list_rooms_with_multiple_transcripts/0 reports count and populated_count" do
      {room_id, _populated, _empty} = shadowed_room()
      single_room = invented_room()
      transcript_at(single_room, 3, ~U[2026-01-01 10:00:00.000000Z])

      rows = Meetings.list_rooms_with_multiple_transcripts()

      assert %{count: 2, populated_count: 1} =
               Enum.find(rows, &(&1.room_id == room_id))

      # A room with exactly one row is not a duplicate.
      refute Enum.any?(rows, &(&1.room_id == single_room))
    end

    test "list_silently_failed_transcripts/0 matches failed + NULL summary + segments present" do
      base = ~U[2026-01-01 10:00:00.000000Z]

      silent = transcript_at(invented_room(), 6, base, "failed")

      # Each of these differs from `silent` in exactly one condition.
      failed_but_empty = transcript_at(invented_room(), 0, base, "failed")
      populated_but_complete = transcript_at(invented_room(), 6, base, "complete")

      failed_with_summary = transcript_at(invented_room(), 6, base, "failed")

      {1, nil} =
        Repo.update_all(
          from(t in Transcript, where: t.id == ^failed_with_summary.id),
          set: [summary: "An invented summary."]
        )

      ids = Enum.map(Meetings.list_silently_failed_transcripts(), & &1.id)

      assert silent.id in ids
      refute failed_but_empty.id in ids
      refute populated_but_complete.id in ids
      refute failed_with_summary.id in ids
    end
  end

  describe "claim_router_dispatch/1 (task 019fa56b-c81f stage 2)" do
    test "first claim wins — {:ok, :claimed} and nil -> non-nil transition" do
      transcript = create_processing_transcript()
      assert is_nil(transcript.router_dispatched_at)

      before = DateTime.utc_now()
      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)
      later = DateTime.utc_now()

      reloaded = Meetings.get_transcript(transcript.id)
      assert %DateTime{} = reloaded.router_dispatched_at
      assert DateTime.compare(reloaded.router_dispatched_at, before) in [:eq, :gt]
      assert DateTime.compare(reloaded.router_dispatched_at, later) in [:eq, :lt]
    end

    test "second claim loses and does NOT move the timestamp" do
      transcript = create_processing_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)
      first = Meetings.get_transcript(transcript.id).router_dispatched_at

      Process.sleep(2)

      assert {:error, :already_dispatched} = Meetings.claim_router_dispatch(transcript.id)
      second = Meetings.get_transcript(transcript.id).router_dispatched_at

      # This is the whole difference from `stamp_router_dispatched/1`,
      # which re-stamps unconditionally: the claim is a one-way latch,
      # so the sweeper's stall clock keeps measuring from the FIRST
      # dispatch rather than being reset by a losing racer.
      assert DateTime.compare(second, first) == :eq
    end

    test "an unknown (but well-formed) id is :no_such_transcript, NOT :already_dispatched" do
      # `update_all` answers 0 for both "somebody already claimed it"
      # and "there is no such row". Collapsing them would make a typo'd
      # or deleted transcript id look like a healthy dedupe and silently
      # suppress a dispatch that nobody is actually handling.
      assert {:error, :no_such_transcript} =
               Meetings.claim_router_dispatch(Ecto.UUID.generate())
    end

    test "a non-UUID id is :no_such_transcript rather than a raised cast error" do
      # `meeting_transcripts.id` is a UUIDv7 custom type; querying it
      # with a free-form string raises Ecto.Query.CastError. The claim
      # sits on a dispatch path that must never raise.
      assert {:error, :no_such_transcript} = Meetings.claim_router_dispatch("not-a-uuid")
      assert {:error, :no_such_transcript} = Meetings.claim_router_dispatch(nil)
    end

    test "the claim is PER ROW — a claimed transcript does not latch a different one" do
      claimed = create_processing_transcript()
      other = create_processing_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(claimed.id)
      assert {:error, :already_dispatched} = Meetings.claim_router_dispatch(claimed.id)

      # The point of the assertion: the guard is `WHERE id = $1 AND
      # router_dispatched_at IS NULL`, not a process-wide latch.
      assert {:ok, :claimed} = Meetings.claim_router_dispatch(other.id)
      refute is_nil(Meetings.get_transcript(other.id).router_dispatched_at)
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
        Repo.update_all(
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
        Repo.update_all(
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
                        segment: %{"id" => <<_::binary>>} = delivered,
                        meeting_id: nil
                      }},
                     200

      # Task 01a06672: `append_segment/2` mints `"id"` / `"spoken_at"` before
      # persisting, so the broadcast segment is the caller's map plus those.
      assert Map.drop(delivered, ["id", "spoken_at"]) == segment

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
                        segment: %{"id" => <<_::binary>>} = delivered,
                        meeting_id: nil
                      }},
                     200

      # Task 01a06672: `append_segment/2` mints `"id"` / `"spoken_at"` before
      # persisting, so the broadcast segment is the caller's map plus those.
      assert Map.drop(delivered, ["id", "spoken_at"]) == segment

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
      missing_id = Ecto.UUID.generate()

      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:error, :not_found} = Meetings.append_segment(missing_id, make_segment())

      # Scoped to `missing_id` on purpose. `meeting:transcript_chunk` is the
      # process-global topic, so every append in every other async test in the
      # run lands in this mailbox too; a bare `{:transcript_chunk, _}` refutes
      # on their traffic and fails this test for reasons it does not assert.
      refute_receive {:transcript_chunk, %{transcript_id: ^missing_id}}, 100

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
                        segment: %{"id" => <<_::binary>>} = delivered,
                        meeting_id: nil
                      }},
                     200

      # Task 01a06672: `append_segment/2` mints `"id"` / `"spoken_at"` before
      # persisting, so the broadcast segment is the caller's map plus those.
      assert Map.drop(delivered, ["id", "spoken_at"]) == segment

      assert_receive {:transcript_chunk,
                      %{
                        room_id: ^room_id,
                        transcript_id: ^transcript_id,
                        segment: %{"id" => <<_::binary>>} = delivered,
                        meeting_id: nil
                      }},
                     200

      # Task 01a06672: `append_segment/2` mints `"id"` / `"spoken_at"` before
      # persisting, so the broadcast segment is the caller's map plus those.
      assert Map.drop(delivered, ["id", "spoken_at"]) == segment

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

  describe "verify_livekit_jwt/2 (task 019f3312 stage 2)" do
    alias Platform.LivekitTestHelpers

    setup do
      prev_livekit = Application.get_env(:platform, :livekit)

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: LivekitTestHelpers.default_secret()
      )

      on_exit(fn ->
        case prev_livekit do
          nil -> Application.delete_env(:platform, :livekit)
          v -> Application.put_env(:platform, :livekit, v)
        end
      end)

      :ok
    end

    test "returns :ok for a freshly-signed payload" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      assert :ok = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :missing_secret} when LIVEKIT_API_SECRET is unset" do
      Application.put_env(:platform, :livekit, api_key: "x", api_secret: nil)

      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      assert {:error, :missing_secret} = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :malformed} for nil / empty / non-triple tokens" do
      assert {:error, :malformed} = Meetings.verify_livekit_jwt(nil, "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("", "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("abc.def", "")
      assert {:error, :malformed} = Meetings.verify_livekit_jwt("not-a-jwt", "")
    end

    test "returns {:error, :bad_signature} when HS256 doesn't verify" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      [h, p, s] = String.split(jwt, ".", parts: 3)

      # Flip a byte inside the sig — mid-string, unambiguously changes
      # decoded bytes regardless of the trailing base64 padding-bit alphabet.
      mid = div(String.length(s), 2)
      original = String.at(s, mid)
      replacement = if original == "A", do: "B", else: "A"

      flipped =
        String.slice(s, 0, mid) <> replacement <> String.slice(s, (mid + 1)..-1//1)

      tampered = Enum.join([h, p, flipped], ".")
      assert {:error, :bad_signature} = Meetings.verify_livekit_jwt(tampered, body)
    end

    test "rejects non-canonical base64 padding-bit permutations of a valid sig" do
      # Regression pin for a stochastic bug: HMAC-SHA256 = 32 bytes = 43 base64url
      # chars, and the last char has 2 unused padding bits. Chars "A" (000000) and
      # "B" (000001) differ ONLY in those unused bits, so a naive decode-then-
      # byte-compare would accept "…B" as a valid encoding of a signature that
      # canonically ends in "…A" (and vice versa). Any 4-char cluster of the last
      # position (e.g. A/B/C/D when data nibble is 0000) collapses to the same
      # decoded bytes. Enforcing canonical encoding closes the replay-variant hole.
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      [h, p, s] = String.split(jwt, ".", parts: 3)
      prefix = String.slice(s, 0..-2//1)
      last = String.last(s)

      # For any last char, at least one other char in its 4-member equivalence
      # class exists — pick a variant that differs only in the unused low bits.
      variant =
        case last do
          "A" -> "B"
          "B" -> "A"
          "C" -> "D"
          "D" -> "C"
          # Fall back: increment/decrement within a same-nibble neighbor.
          _ -> if last == "E", do: "F", else: "A"
        end

      tampered_body = Enum.join([h, p, prefix <> variant], ".")

      # If verify decodes sig-bytes and byte-compares, this returns :ok for
      # canonical-"A" (and similar) sigs — the exact stochastic regression that
      # blocked PR #552 CI. Canonical text compare rejects it deterministically.
      result = Meetings.verify_livekit_jwt(tampered_body, body)

      if variant == last do
        # No perturbation — shouldn't hit this branch given the case above.
        assert :ok = result
      else
        assert {:error, reason} = result
        assert reason in [:bad_signature, :malformed]
      end
    end

    test "returns {:error, :body_hash_mismatch} when body doesn't match sha256 claim" do
      original = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "a"}})
      {_original, jwt} = LivekitTestHelpers.sign_livekit_payload(original)

      tampered = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "b"}})
      assert {:error, :body_hash_mismatch} = Meetings.verify_livekit_jwt(jwt, tampered)
    end

    test "returns {:error, :expired} when exp is in the past" do
      body = Jason.encode!(%{"event" => "room_started"})
      body_hash = :crypto.hash(:sha256, body) |> Base.encode64()

      past = System.system_time(:second) - 60

      claims = %{
        "iss" => "test-livekit-key",
        "nbf" => past - 60,
        "exp" => past,
        "sha256" => body_hash
      }

      jwt = Meetings.encode_jwt(claims, LivekitTestHelpers.default_secret())
      assert {:error, :expired} = Meetings.verify_livekit_jwt(jwt, body)
    end

    test "returns {:error, :malformed} when exp is missing" do
      body = Jason.encode!(%{"event" => "room_started"})
      body_hash = :crypto.hash(:sha256, body) |> Base.encode64()

      # No `exp` claim.
      claims = %{"iss" => "test-livekit-key", "sha256" => body_hash}
      jwt = Meetings.encode_jwt(claims, LivekitTestHelpers.default_secret())
      assert {:error, :malformed} = Meetings.verify_livekit_jwt(jwt, body)
    end
  end

  # ── Shared guest-invite resolver (task 019f498d stage 2) ─────────────────
  #
  # `resolve_guest_invite/2` is the single place `PlatformWeb.MeetingLive`
  # (with `chrome_mode: :none` on the `meet.` host) branches the invite
  # token into `{name_entry, in_meeting, expired, invalid}`. Pinning each
  # branch here keeps the guest ingress from drifting from what the
  # context returns.
  describe "resolve_guest_invite/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.GuestInvite
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    # The resolver never mints a LiveKit token — it only verifies the
    # HMAC + does a slug lookup — so it does not depend on the
    # `Application.put_env(:platform, :livekit, ...)` global. That means
    # this describe can stay in the `async: true` module without
    # racing other tests that mutate the livekit config.

    defp create_project! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Guest Invite Resolver Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      project
    end

    defp create_meeting!(attrs \\ %{}) do
      project = Map.get_lazy(attrs, :project, fn -> create_project!() end)
      name = Map.get(attrs, :name, "Guest Kickoff #{System.unique_integer([:positive])}")

      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
      Platform.Repo.preload(meeting, :chat_space)
    end

    test "returns :in_meeting with preloaded chat_space when token carries a display_name" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      assert {:ok, %{state: :in_meeting, meeting: resolved, display_name: "Jane Doe"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert %Meeting{} = resolved
      assert resolved.id == meeting.id
      # `:chat_space` must be preloaded — downstream `guest_join_event_payload/2`
      # reads `meeting.chat_space.slug` and would blow up on a NotLoaded assoc.
      assert %Chat.Space{} = resolved.chat_space
    end

    test "returns :name_entry when token payload carries nil display_name" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      assert {:ok, %{state: :name_entry, meeting: resolved}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert resolved.id == meeting.id
      assert %Chat.Space{} = resolved.chat_space
    end

    test "returns {:error, :expired} for a past-expiry token" do
      meeting = create_meeting!()
      # 60s in the past → GuestInvite.verify returns {:error, :expired}.
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      assert {:error, :expired} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "returns {:error, :invalid} when the HMAC signature is tampered" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")
      # Flip a byte early in the token so the signature check fails.
      tampered = String.replace(token, ~r/./, "X", global: false)

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, tampered)
    end

    test "returns {:error, :invalid} when URL slug differs from payload slug" do
      meeting_a = create_meeting!()
      meeting_b = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      # Token signed against meeting_a, then hit at meeting_b's URL.
      token = GuestInvite.sign(meeting_a.slug, expires_at, "Jane Doe")

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting_b.slug, token)
    end

    test "returns {:error, :invalid} when the payload slug no longer resolves to a meeting" do
      # Sign for a slug that has no Meeting row (deleted-after-issue).
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      slug = "ghost-meeting-#{System.unique_integer([:positive])}"
      token = GuestInvite.sign(slug, expires_at, "Jane Doe")

      assert {:error, :invalid} = Meetings.resolve_guest_invite(slug, token)
    end

    test "returns {:error, :invalid} for a completely malformed token string" do
      # Not a Plug.Crypto-signed token at all.
      assert {:error, :invalid} =
               Meetings.resolve_guest_invite("some-meeting", "definitely-not-a-token")
    end

    # ── meeting_id-bound tokens (task 019f9b14 stage 3) ──────────────────
    #
    # `meetings` carries `unique_index(:meetings, [:project_id, :slug])`, so
    # the same slug can legally exist in two projects in two different orgs.
    # Before this stage the resolver looked the meeting up by slug alone via
    # `Repo.get_by/3`, which RAISES `Ecto.MultipleResultsError` on the second
    # match — a 500 on a public, unauthenticated ingress. And "just take the
    # first row" would have admitted a guest holding org A's token into org
    # B's meeting and its LiveKit room. These pin both halves.

    defp create_colliding_meetings!(slug) do
      project_a = create_project!()
      project_b = create_project!()

      {:ok, meeting_a} =
        Meetings.create_meeting(%{project_id: project_a.id, name: "Standup A", slug: slug})

      {:ok, meeting_b} =
        Meetings.create_meeting(%{project_id: project_b.id, name: "Standup B", slug: slug})

      {Platform.Repo.preload(meeting_a, :chat_space),
       Platform.Repo.preload(meeting_b, :chat_space)}
    end

    test "an id-bearing token resolves to ITS meeting when two projects share the slug" do
      slug = "shared-standup-#{System.unique_integer([:positive])}"
      {meeting_a, meeting_b} = create_colliding_meetings!(slug)

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      token_a =
        GuestInvite.sign(slug, expires_at, "Jane Doe", meeting_id: meeting_a.id)

      token_b =
        GuestInvite.sign(slug, expires_at, "Jane Doe", meeting_id: meeting_b.id)

      assert {:ok, %{state: :in_meeting, meeting: resolved_a}} =
               Meetings.resolve_guest_invite(slug, token_a)

      assert {:ok, %{state: :in_meeting, meeting: resolved_b}} =
               Meetings.resolve_guest_invite(slug, token_b)

      # Same URL slug, two different tokens, two different meetings. This is
      # the cross-org admission path the id closes.
      assert resolved_a.id == meeting_a.id
      assert resolved_b.id == meeting_b.id
      refute resolved_a.id == resolved_b.id
      assert %Chat.Space{} = resolved_a.chat_space
      assert %Chat.Space{} = resolved_b.chat_space
    end

    test "an id-bearing token whose meeting was deleted resolves to :invalid" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe", meeting_id: meeting.id)

      Platform.Repo.delete!(%Meeting{id: meeting.id})

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "an id-bearing token whose meeting's slug no longer matches the URL is :invalid" do
      meeting_a = create_meeting!()
      meeting_b = create_meeting!()

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      # Payload's slug agrees with the URL (so the existing tamper guard
      # passes) but the id points at a different meeting. Defence in depth:
      # the two identifiers must agree with each other, not just with the URL.
      token =
        GuestInvite.sign(meeting_a.slug, expires_at, "Jane Doe", meeting_id: meeting_b.id)

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting_a.slug, token)
    end

    test "an id-bearing token carrying a non-UUID meeting_id is :invalid, not a crash" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe", meeting_id: "not-a-uuid")

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    # ── Legacy (pre-019f9b14) slug-only tokens ───────────────────────────
    #
    # These are in the wild with a 24h expiry. Backwards compatibility is
    # load-bearing until they age out.

    test "a legacy slug-only token with a unique slug still resolves :in_meeting" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)

      # Exactly the old mint shape — guest_space_id, no meeting_id.
      token =
        GuestInvite.sign(meeting.slug, expires_at, "Jane Doe",
          guest_space_id: meeting.chat_space_id
        )

      assert {:ok, %{state: :in_meeting, meeting: resolved, display_name: "Jane Doe"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert resolved.id == meeting.id
      assert %Chat.Space{} = resolved.chat_space
    end

    test "a legacy slug-only token with a unique slug still resolves :name_entry" do
      meeting = create_meeting!()
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, nil)

      assert {:ok, %{state: :name_entry, meeting: resolved}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert resolved.id == meeting.id
      assert %Chat.Space{} = resolved.chat_space
    end

    test "a legacy slug-only token with a COLLIDING slug is :invalid and does not raise" do
      slug = "ambiguous-standup-#{System.unique_integer([:positive])}"
      {_meeting_a, _meeting_b} = create_colliding_meetings!(slug)

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(slug, expires_at, "Jane Doe")

      # The whole point: refuse rather than gamble on a project, and — the
      # bug this stage closes — never raise `Ecto.MultipleResultsError` on
      # the public guest ingress.
      assert {:error, :invalid} = Meetings.resolve_guest_invite(slug, token)
    end

    test "the ambiguous legacy path raises nothing at all" do
      slug = "ambiguous-noraise-#{System.unique_integer([:positive])}"
      {_a, _b} = create_colliding_meetings!(slug)

      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(slug, expires_at, nil)

      # Explicit: any exception (not just MultipleResultsError) fails here.
      result =
        try do
          Meetings.resolve_guest_invite(slug, token)
        rescue
          e -> flunk("resolve_guest_invite/2 raised #{inspect(e.__struct__)}")
        end

      assert result == {:error, :invalid}
    end
  end

  # ── The invite ROW is the authority on a guest link (task 019fb954 stage 4)
  #
  # An HMAC cannot be un-issued: once signed it verifies until its embedded
  # expiry passes, and `GuestInvite.verify/2` is a pure function with no Repo
  # access. So revocation has to be a row fact checked by the Repo-backed
  # resolver, which is what this group pins.
  #
  # WHY THE PAIRED ASSERTION IN THE FIRST TEST IS THE POINT. Asserting only
  # that the revoked token fails passes on an implementation that kills every
  # link on the meeting (rotate the signing key, stamp the meeting row) —
  # which is the exact design this whole task exists to avoid, because one
  # forwardable, unattributable link is what per-row invites replace.
  # Asserting only that the surviving token still works passes on a revoke
  # that does nothing at all. Both halves, always.
  #
  # WHY SEVERAL TESTS ASSERT WHICH TABLE WAS QUERIED. `{:error, :invalid}` is
  # returned for at least five distinct reasons (bad signature, slug
  # tampering, missing invite row, row/payload meeting disagreement,
  # malformed invite id). A test that asserts only the tuple cannot tell those
  # apart, so a mutation collapsing two of them survives. Ecto's query
  # telemetry is the cheapest available provenance: it says whether the row
  # gate ran, and whether the resolver bailed before ever reading `meetings`.
  describe "resolve_guest_invite/2 invite-row gate (task 019fb954 stage 4)" do
    alias Platform.Meetings.GuestInvite

    @query_event [:platform, :repo, :query]

    test "the query event name is the one Repo actually emits" do
      # Guards every `refute "meeting_invites" in sources` below from going
      # vacuous because the event name drifted away from what Repo emits.
      assert Platform.Repo.config()[:telemetry_prefix] ++ [:query] == @query_event
    end

    test "revoking one guest's invite kills that link and leaves the other's alone" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite_a, token: token_a}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest A"})

      assert {:ok, %{invite: invite_b, token: token_b}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest B"})

      refute invite_a.id == invite_b.id

      # Both work before the revoke — otherwise the "b still works" half
      # below could be passing on a fixture that never worked.
      assert {:ok, %{state: :in_meeting}} = Meetings.resolve_guest_invite(meeting.slug, token_a)
      assert {:ok, %{state: :in_meeting}} = Meetings.resolve_guest_invite(meeting.slug, token_b)

      assert {:ok, revoked} = Meetings.revoke_invite(invite_a)
      assert %DateTime{} = revoked.revoked_at

      # Half one: the revoked link is dead, and dead with its OWN reason —
      # not folded into :invalid at the context boundary.
      assert {:error, :revoked} = Meetings.resolve_guest_invite(meeting.slug, token_a)

      # Half two: the other guest on the SAME meeting is untouched. This is
      # what makes revocation per-row rather than per-meeting.
      assert {:ok, %{state: :in_meeting, display_name: "Guest B"}} =
               Meetings.resolve_guest_invite(meeting.slug, token_b)
    end

    test "revoking does not touch the signing key or any other meeting's links" do
      meeting_a = create_meeting!()
      meeting_b = create_meeting!()

      assert {:ok, %{invite: invite_a, token: token_a}} =
               Meetings.invite_guest(meeting_a, %{display_name: "Guest A"})

      assert {:ok, %{token: token_b}} =
               Meetings.invite_guest(meeting_b, %{display_name: "Guest B"})

      assert {:ok, _} = Meetings.revoke_invite(invite_a)

      assert {:error, :revoked} = Meetings.resolve_guest_invite(meeting_a.slug, token_a)

      # A key rotation would take this one down too. It must not.
      assert {:ok, %{state: :in_meeting}} =
               Meetings.resolve_guest_invite(meeting_b.slug, token_b)
    end

    test "a revoke is idempotent at the resolver too" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      assert {:ok, _} = Meetings.revoke_invite(invite)
      assert {:ok, _} = Meetings.revoke_invite(invite)

      assert {:error, :revoked} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "the ROW's expires_at is authoritative even when the token's is still in the future" do
      meeting = create_meeting!()

      # 24h default: the token payload's own expiry is comfortably ahead.
      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      assert {:ok, payload} = GuestInvite.verify(token)
      assert payload.expires_at > DateTime.to_unix(DateTime.utc_now())

      # Back-date the ROW, not the token. A host shortening a link's life
      # after issue can only write the row — the signature is already out.
      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      assert {:error, :expired} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "a row whose expires_at is still in the future resolves" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), 60, :second))
      |> Repo.update!()

      assert {:ok, %{state: :in_meeting}} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "a token naming an invite row that no longer exists is :invalid, and never reads meetings" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      Repo.delete!(invite)

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting.slug, token) end)

      assert result == {:error, :invalid}
      # Provenance: this :invalid came from the row gate. The resolver never
      # got as far as loading the meeting.
      assert "meeting_invites" in sources
      refute "meetings" in sources
    end

    test "a token whose payload meeting disagrees with the row's is :invalid at the row gate" do
      meeting_a = create_meeting!()
      meeting_b = create_meeting!()

      assert {:ok, %{invite: invite_b}} =
               Meetings.invite_guest(meeting_b, %{display_name: "Guest B"})

      # Hand-signed: `invite_guest/2` structurally cannot mint a token whose
      # meeting_id and invite_id name different meetings.
      token =
        raw_sign(%{
          meeting_slug: meeting_a.slug,
          expires_at: DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          display_name: "Guest B",
          guest_space_id: nil,
          meeting_id: meeting_a.id,
          invite_id: invite_b.id
        })

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting_a.slug, token) end)

      assert result == {:error, :invalid}
      # Distinguishes this :invalid from the pre-existing slug-mismatch one:
      # the invite row was read, and the meeting never was.
      assert "meeting_invites" in sources
      refute "meetings" in sources
    end

    test "a token carrying an invite_id but no meeting_id is :invalid" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      # nil disagrees with the row's meeting_id. This shape is not one the
      # public API produces — a row-bound token always names its meeting.
      token =
        raw_sign(%{
          meeting_slug: meeting.slug,
          expires_at: DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          display_name: "Jane Doe",
          guest_space_id: nil,
          meeting_id: nil,
          invite_id: invite.id
        })

      assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, token)
    end

    test "a non-UUID invite_id is :invalid and never reaches the database" do
      meeting = create_meeting!()

      # `sign/4`'s `is_binary` guard permits this string, and `verify/2`
      # returns it unchanged — the boundary is here.
      token =
        GuestInvite.sign(
          meeting.slug,
          DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          "Jane Doe",
          meeting_id: meeting.id,
          invite_id: "not-a-uuid"
        )

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting.slug, token) end)

      assert result == {:error, :invalid}
      # `Platform.UUID.valid?/1` refused it before Repo could raise
      # `Ecto.Query.CastError` out of a public, unauthenticated ingress. The
      # positive control for this refutation is the test below.
      refute "meeting_invites" in sources
    end

    test "a 16-byte invite_id is refused too — the Ecto.UUID.cast/1 gap" do
      meeting = create_meeting!()

      # `Ecto.UUID.cast/1` hex-encodes this into a well-formed but INVENTED
      # uuid. A fabricated id must never decide whether a link was revoked.
      token =
        GuestInvite.sign(
          meeting.slug,
          DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          "Jane Doe",
          meeting_id: meeting.id,
          invite_id: "higginshigginsxx"
        )

      assert {:ok, _} = Ecto.UUID.cast("higginshigginsxx")

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting.slug, token) end)

      assert result == {:error, :invalid}
      refute "meeting_invites" in sources
    end

    test "a live row-bound token DOES read the invite row (positive control)" do
      meeting = create_meeting!()

      assert {:ok, %{token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Jane Doe"})

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting.slug, token) end)

      assert {:ok, %{state: :in_meeting}} = result
      # Without this, every `refute "meeting_invites" in sources` above could
      # be passing because the gate does not exist.
      assert "meeting_invites" in sources
      assert "meetings" in sources
    end

    # ── The legacy path must not regress ─────────────────────────────────
    #
    # Every guest token in the wild today, plus everything the untouched
    # mint site in `MeetingLive` still produces, carries no invite_id. A row
    # gate that treats "no row named" as "no capability" locks all of them
    # out. The pre-existing `meeting_live_guest_*` suites cover this from the
    # ingress side; these cover the branch itself.

    test "a payload that OMITS invite_id entirely resolves exactly as before" do
      meeting = create_meeting!()

      # Genuinely key-absent — `sign/4` always writes the key, so a fixture
      # built from the public API is not actually a legacy token.
      token =
        raw_sign(%{
          meeting_slug: meeting.slug,
          expires_at: DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          display_name: "Jane Doe",
          guest_space_id: nil,
          meeting_id: meeting.id
        })

      {result, sources} =
        capture_repo_sources(fn -> Meetings.resolve_guest_invite(meeting.slug, token) end)

      assert {:ok, %{state: :in_meeting, display_name: "Jane Doe"}} = result
      # No row named, so no row read. The legacy path costs nothing.
      refute "meeting_invites" in sources
    end

    test "a payload with an explicit invite_id: nil resolves exactly as before" do
      meeting = create_meeting!()

      token =
        GuestInvite.sign(
          meeting.slug,
          DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          nil,
          meeting_id: meeting.id
        )

      assert {:ok, %{state: :name_entry, meeting: resolved}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert resolved.id == meeting.id
    end

    test "revoking an invite does not affect a legacy token on the same meeting" do
      meeting = create_meeting!()

      assert {:ok, %{invite: invite, token: bound_token}} =
               Meetings.invite_guest(meeting, %{display_name: "Bound Guest"})

      legacy_token =
        raw_sign(%{
          meeting_slug: meeting.slug,
          expires_at: DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600),
          display_name: "Legacy Guest",
          guest_space_id: nil,
          meeting_id: meeting.id
        })

      assert {:ok, _} = Meetings.revoke_invite(invite)

      assert {:error, :revoked} = Meetings.resolve_guest_invite(meeting.slug, bound_token)

      assert {:ok, %{state: :in_meeting, display_name: "Legacy Guest"}} =
               Meetings.resolve_guest_invite(meeting.slug, legacy_token)
    end

    # ── Helpers ──────────────────────────────────────────────────────────

    # Sign an ARBITRARY payload with the module's key and salt, bypassing
    # `sign/4`'s shape guarantees. Two shapes the signer structurally cannot
    # produce are needed here: a payload that OMITS an optional key (a real
    # legacy token), and one whose meeting_id and invite_id disagree. Key and
    # salt are duplicated on purpose — they are the token's wire format, and
    # reaching through the module would defeat the point.
    defp raw_sign(payload) do
      key = Application.get_env(:platform, :meeting_guest_signing_key)
      Plug.Crypto.sign(key, "meeting_guest_invite", payload)
    end

    # Run `fun` and return `{result, sources}` where `sources` is the list of
    # table names Ecto queried FROM THIS PROCESS (or a `Task` it spawned,
    # which carries it in `$callers`). The handler runs in the emitting
    # process, so the `:caller` discriminator discards every query the rest
    # of the concurrently-running suite is issuing — which is what makes this
    # safe under `async: true`.
    defp capture_repo_sources(fun) do
      handler_id =
        Platform.TelemetryHelpers.attach_scoped(@query_event, :caller, self(), tag: :repo_query)

      result =
        try do
          fun.()
        after
          :telemetry.detach(handler_id)
        end

      {result, drain_repo_sources([])}
    end

    defp drain_repo_sources(acc) do
      receive do
        {:repo_query, _event, _measurements, metadata} ->
          drain_repo_sources([metadata[:source] | acc])
      after
        0 -> acc
      end
    end
  end

  # ── The unscoped slug read is gone (task 019f9b14 stage 3) ───────────────
  #
  # `get_meeting_by_slug/1` was a public, unscoped `Repo.get_by(Meeting,
  # slug: slug)`. It was both a cross-org read and a latent 500. Deleting it
  # is the fix; this pins that it cannot be reintroduced silently. The
  # arity-2 (explicit project_id, used by `dedupe_slug/4`) is NOT an
  # authorization surface and deliberately stays.
  describe "unscoped slug read surface (task 019f9b14 stage 3)" do
    test "Platform.Meetings does not export an arity-1 get_meeting_by_slug" do
      Code.ensure_loaded!(Platform.Meetings)
      refute function_exported?(Platform.Meetings, :get_meeting_by_slug, 1)
    end

    test "the project-scoped arity-2 lookup is still exported" do
      Code.ensure_loaded!(Platform.Meetings)
      assert function_exported?(Platform.Meetings, :get_meeting_by_slug, 2)
    end
  end

  # ── mint_guest_join_bundle/2 (task 019f498d stage 2) ─────────────────────
  #
  # Thin alias over `guest_livekit_token/2` so downstream callers can
  # standardise on the "mint bundle" verb. The full success-shape
  # (`{:ok, bundle}`) contract is covered by `guest_token_test.exs`
  # (an `async: false` module that mutates `Application.put_env(:platform,
  # :livekit, ...)` safely) — the same code path is exercised end-to-end
  # via `PlatformWeb.MeetingLive.mount/3`'s guest branch (chrome_mode:
  # :none), which calls `mint_guest_join_bundle/2` under the hood.
  #
  # We pin only the failure branches here — those don't require
  # LiveKit env, so they're safe under `async: true`.
  describe "mint_guest_join_bundle/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    defp create_bundle_meeting! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Bundle Alias Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Bundle Kickoff"})

      Platform.Repo.preload(meeting, :chat_space)
    end

    test "propagates {:error, :missing_display_name} for an empty display name" do
      meeting = create_bundle_meeting!()

      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, "")
    end

    test "propagates {:error, :missing_display_name} for a whitespace-only display name" do
      meeting = create_bundle_meeting!()

      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, "   ")
    end

    test "propagates {:error, :missing_display_name} for a nil display name" do
      meeting = create_bundle_meeting!()

      # `guest_livekit_token/2`'s catch-all clause returns this for any
      # non-binary — the alias must forward it unchanged.
      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, nil)
    end
  end

  # ── guest_join_event_payload/2 (task 019f498d stage 2) ───────────────────
  #
  # Payload shape MeetingClient's phx-hook consumes. Load-bearing keys
  # are `:token` + `:url`; the rest are surfaced for parity + debug.
  describe "guest_join_event_payload/2 (task 019f498d stage 2)" do
    alias Platform.Meetings.Meeting
    alias Platform.Tasks

    defp create_payload_meeting! do
      org_id = Platform.TenancyFixtures.fabrikam_org_id()

      {:ok, project} =
        Tasks.create_project(%{
          name: "Payload Shape Project #{System.unique_integer([:positive])}",
          org_id: org_id
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Payload Kickoff"})

      Platform.Repo.preload(meeting, :chat_space)
    end

    test "maps bundle -> push_event map with token/url/room_name/space_slug" do
      meeting = create_payload_meeting!()

      bundle = %{
        token: "jwt.payload.signature",
        identity: "guest:abc",
        room_name: "space-#{meeting.chat_space_id}",
        livekit_url: "wss://livekit.test"
      }

      payload = Meetings.guest_join_event_payload(bundle, meeting)

      assert payload.token == bundle.token
      assert payload.url == bundle.livekit_url
      assert payload.room_name == bundle.room_name
      assert payload.space_slug == meeting.chat_space.slug
    end

    test "space_slug is nil when the meeting's chat_space is nil" do
      meeting = %Meeting{
        id: Ecto.UUID.generate(),
        name: "No-space Meeting",
        chat_space_id: nil,
        chat_space: nil
      }

      bundle = %{
        token: "t",
        identity: "guest:x",
        room_name: "space-none",
        livekit_url: nil
      }

      payload = Meetings.guest_join_event_payload(bundle, meeting)
      assert payload.space_slug == nil
      assert payload.url == nil
    end
  end

  # ── complete_transcript/2 → scribe attention dispatch (task 019f5e0b stage 2) ─
  #
  # Progressive-enhancement hook: after `Repo.update` succeeds, opportunistically
  # broadcast a `meeting_scribe_completion` attention signal to the runtime linked
  # to whichever agent currently holds the `meeting_scribe` role. Every failure
  # branch is swallowed via telemetry so the existing Summarizer path (which
  # calls `complete_transcript/2` at the tail of `run_summary/1`) stays intact.
  describe "complete_transcript/2 → scribe attention dispatch (task 019f5e0b stage 2)" do
    @scribe_event [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable]

    defp create_agent!(attrs \\ %{}) do
      defaults = %{
        slug: "scribe-agent-#{System.unique_integer([:positive])}",
        name: "Test Scribe Agent",
        status: "active"
      }

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(Map.merge(defaults, attrs))
        |> Repo.insert()

      agent
    end

    defp create_user! do
      Repo.insert!(%Platform.Accounts.User{
        email: "scribe_hook_#{System.unique_integer([:positive])}@example.com",
        name: "Scribe Hook Test User",
        oidc_sub: "oidc-scribe-hook-#{System.unique_integer([:positive])}"
      })
    end

    defp create_processing_transcript_with_space do
      space_id = Ecto.UUID.generate()

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{space_id}",
          space_id: space_id,
          status: "processing"
        })

      transcript
    end

    # Run `fun` in a bare-spawned process (no `$callers`, so nothing about it
    # says "this test"), with sandbox access so a boot-attached handler that
    # persists the event does not crash there, and wait for it to finish.
    defp foreign_emission!(fun) do
      test_pid = self()

      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :go -> fun.()
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, pid)
      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    # The fallback's metadata carries no per-test id (agent/reason/actor/
    # resource only) and the refute tests unassign the role, so the only thing
    # that separates this test's emission from a sibling's is the emitting
    # process: `complete_transcript/2` dispatches synchronously in its caller
    # (task 01a08b5f stage 2).
    defp attach_scribe_telemetry! do
      Platform.TelemetryHelpers.attach_scoped(@scribe_event, :caller, self())
      :ok
    end

    test "the scribe becomes writable in the meeting's chat space before the signal fires" do
      # Task 019fb90f stage 2 — the behaviour change, at the layer it actually
      # lands. `maybe_dispatch_scribe_attention/1` already put
      # `transcript.space_id` in the payload, so routing the broadcast through
      # `Platform.Federation.AttentionDispatch` makes the scribe a participant
      # of the meeting's chat space with no payload change here.
      #
      # Before this, a scribe dispatched on transcript completion could not post
      # a message or create its action-items canvas in the space it was told
      # about: the dispatch was dead on arrival and nothing errored.
      Platform.TelemetryHelpers.attach_scoped(
        [:platform, :chat, :dispatch_auto_invite],
        :caller,
        self(),
        tag: :auto_invite
      )

      user = create_user!()
      agent = create_agent!()

      runtime_id = "scribe-writable-#{System.unique_integer([:positive])}"
      {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
      {:ok, _linked} = Federation.link_agent(runtime, agent)

      :ok = Roles.unassign_role("meeting_scribe")
      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      n = System.unique_integer([:positive, :monotonic])

      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Scribe Meeting #{n}",
          slug: "scribe-meeting-#{n}",
          kind: "meeting"
        })

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{space.id}",
          space_id: space.id,
          status: "processing"
        })

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

      # Negative control: the agent is NOT in the meeting space beforehand.
      # `create_space/1` auto-adds nobody but the Historian, so membership does
      # not follow from creation.
      refute Platform.Chat.get_agent_participant(space.id, agent.id)

      assert {:ok, %Transcript{status: "complete"}} =
               Meetings.complete_transcript(transcript.id, "the summary text")

      # Positional: invite first, signal second.
      assert_receive first, 500

      assert {:auto_invite, _event, %{count: 1}, %{outcome: :invited, source: :meeting_scribe}} =
               first

      assert_receive second, 500
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second

      assert %Platform.Chat.Participant{attention_mode: "mention", role: "member"} =
               Platform.Chat.get_agent_participant(space.id, agent.id)
    end

    test "happy path: broadcasts attention signal on runtime topic when scribe role + runtime are wired" do
      user = create_user!()
      agent = create_agent!()

      runtime_id = "scribe-runtime-#{System.unique_integer([:positive])}"
      {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
      {:ok, _linked} = Federation.link_agent(runtime, agent)

      :ok = Roles.unassign_role("meeting_scribe")
      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

      transcript = create_processing_transcript_with_space()
      transcript_id = transcript.id
      space_id = transcript.space_id
      room_id = transcript.room_id

      assert {:ok, %Transcript{status: "complete"}} =
               Meetings.complete_transcript(transcript.id, "the summary text")

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: broadcast_topic,
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_scribe_completion",
                           space_id: ^space_id,
                           room_id: ^room_id,
                           transcript_id: ^transcript_id
                         }
                       }
                     },
                     500

      assert broadcast_topic == "runtime:#{runtime_id}"
    end

    test "no-scribe fallback: no broadcast, no telemetry, Summarizer path unchanged" do
      attach_scribe_telemetry!()
      :ok = Roles.unassign_role("meeting_scribe")

      # Subscribe to any runtime topic just to prove we don't get spurious deliveries.
      PlatformWeb.Endpoint.subscribe("runtime:no-scribe-#{System.unique_integer([:positive])}")

      transcript = create_processing_transcript_with_space()

      assert {:ok, %Transcript{status: "complete", summary: "no scribe present"}} =
               Meetings.complete_transcript(transcript.id, "no scribe present")

      # No broadcast landed (progressive-enhancement invariant).
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 100
      # No `assignee_unresolvable` telemetry either — the nil-role branch is a
      # pure silent no-op, not a fallback surface.
      refute_receive {:telemetry, @scribe_event, _, _}, 100
    end

    # Task 01a08b5f stage 2. The forwarder is VM-global and this event carries
    # no per-test id (its metadata is agent/reason/actor/resource only), so a
    # sibling module's fallback lands in this mailbox and trips the refute
    # above. A bare `spawn` carries no `$callers`, so it stands in for that
    # sibling; it is allowed into the sandbox only so the boot-attached audit
    # bridge, which persists this event, does not crash in a foreign process.
    test "a sibling's scribe_dispatch fallback from outside this test's caller chain does not reach its mailbox" do
      attach_scribe_telemetry!()

      foreign_emission!(fn ->
        :telemetry.execute(@scribe_event, %{count: 1}, %{
          agent_id: Ecto.UUID.generate(),
          reason: :runtime_unresolvable,
          actor_type: "system",
          resource_type: "agent",
          resource_id: Ecto.UUID.generate()
        })
      end)

      refute_receive {:telemetry, @scribe_event, _, _}, 50
    end

    test "runtime-offline fallback: role assigned but no linked runtime → :runtime_unresolvable telemetry" do
      attach_scribe_telemetry!()

      agent = create_agent!()
      :ok = Roles.unassign_role("meeting_scribe")
      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      transcript = create_processing_transcript_with_space()

      # Existing complete_transcript contract still returns {:ok, transcript}.
      assert {:ok, %Transcript{status: "complete"}} =
               Meetings.complete_transcript(transcript.id, "runtime offline path")

      agent_id = agent.id

      assert_receive {:telemetry, @scribe_event, %{count: 1},
                      %{
                        agent_id: ^agent_id,
                        reason: :runtime_unresolvable,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: ^agent_id
                      }},
                     500
    end
  end

  # ── on_scribe_canvas_created/2 → triage attention dispatch (task 019f5e2a stage 2)
  #
  # Server-side hook invoked by the scribe runtime handler after it creates a
  # completion canvas for a meeting transcript. Resolves the `triage_officer`
  # role and calls `Federation.dispatch_triage_attention/2`. Nil-role branch is
  # a silent no-op (avoids audit noise for orgs without triage assigned).
  describe "on_scribe_canvas_created/2 → triage attention dispatch (task 019f5e2a)" do
    @triage_event [:platform, :meetings, :triage_dispatch, :assignee_unresolvable]

    # Same shape as `attach_scribe_telemetry!/0`: no per-test id in the
    # metadata, `on_scribe_canvas_created/2` dispatches in its caller.
    defp attach_triage_telemetry! do
      Platform.TelemetryHelpers.attach_scoped(@triage_event, :caller, self())
      :ok
    end

    test "happy path: broadcasts triage attention on runtime topic when triage role + runtime are wired" do
      user = create_user!()
      agent = create_agent!()

      runtime_id = "triage-runtime-#{System.unique_integer([:positive])}"
      {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
      {:ok, _linked} = Federation.link_agent(runtime, agent)

      :ok = Roles.unassign_role("triage_officer")
      {:ok, _} = Roles.assign_role("triage_officer", agent.id)

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

      transcript = create_processing_transcript_with_space()
      transcript_id = transcript.id
      space_id = transcript.space_id
      room_id = transcript.room_id
      canvas_id = Ecto.UUID.generate()
      canvas = %Platform.Chat.Canvas{id: canvas_id}

      assert :ok = Meetings.on_scribe_canvas_created(transcript, canvas)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: broadcast_topic,
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_triage_dispatch",
                           space_id: ^space_id,
                           room_id: ^room_id,
                           transcript_id: ^transcript_id,
                           canvas_id: ^canvas_id
                         }
                       }
                     },
                     500

      assert broadcast_topic == "runtime:#{runtime_id}"
    end

    test "no-triage fallback: no broadcast, no telemetry when triage role is unassigned" do
      attach_triage_telemetry!()
      :ok = Roles.unassign_role("triage_officer")

      # Subscribe to any runtime topic to prove no spurious deliveries.
      PlatformWeb.Endpoint.subscribe("runtime:no-triage-#{System.unique_integer([:positive])}")

      transcript = create_processing_transcript_with_space()
      canvas = %Platform.Chat.Canvas{id: Ecto.UUID.generate()}

      assert :ok = Meetings.on_scribe_canvas_created(transcript, canvas)

      # Silent no-op: no broadcast and no fallback telemetry.
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 100
      refute_receive {:telemetry, @triage_event, _, _}, 100
    end

    test "runtime-offline fallback: triage role assigned but no linked runtime → :runtime_unresolvable telemetry" do
      attach_triage_telemetry!()

      agent = create_agent!()
      :ok = Roles.unassign_role("triage_officer")
      {:ok, _} = Roles.assign_role("triage_officer", agent.id)

      transcript = create_processing_transcript_with_space()
      canvas = %Platform.Chat.Canvas{id: Ecto.UUID.generate()}

      assert :ok = Meetings.on_scribe_canvas_created(transcript, canvas)

      agent_id = agent.id

      assert_receive {:telemetry, @triage_event, %{count: 1},
                      %{
                        agent_id: ^agent_id,
                        reason: :runtime_unresolvable,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: ^agent_id
                      }},
                     500
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: parse_identity/1 does not FABRICATE an identity" do
    # This is a fabricated-value site, NOT a raise site. `parse_identity/1`
    # splits a LiveKit webhook `identity` string and the result is persisted
    # as the meeting_participants.user_id / .agent_id FOREIGN KEY.
    #
    # A bare `Ecto.UUID.cast/1` hex-encodes any 16-byte suffix and returns
    # {:ok, _}, so `"user:higginshigginsxx"` used to yield
    # {:user, "68696767-696e-7368-6967-67696e737878"} — a well-formed,
    # real-looking FK belonging to NOBODY. Nothing raised. An assert_raise
    # test cannot see this; assert on the RETURNED VALUE.
    @slug_16 "higginshigginsxx"

    test "a 16-character identity suffix yields :unknown, not an invented uuid" do
      assert Meetings.parse_identity("user:" <> @slug_16) == :unknown
      assert Meetings.parse_identity("agent:" <> @slug_16) == :unknown
      assert Meetings.parse_identity("guest:" <> @slug_16) == :unknown
    end

    test "a raw 16-byte binary suffix yields :unknown too" do
      raw = :crypto.strong_rand_bytes(16)
      assert Meetings.parse_identity("user:" <> raw) == :unknown
    end

    test "short junk yields :unknown (green even before the fix — kept as contrast)" do
      # Deliberately retained next to the 16-character cases so the next
      # reader can see WHY the 16-character ones exist: this assertion alone
      # passes against the buggy bare cast.
      assert Meetings.parse_identity("user:higgins") == :unknown
    end

    test "a canonical uuid still parses" do
      id = Ecto.UUID.generate()
      assert Meetings.parse_identity("user:" <> id) == {:user, id}
      assert Meetings.parse_identity("agent:" <> id) == {:agent, id}
    end
  end

  describe "transcriber presence" do
    defp presence_room! do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      room_name = "space-#{space.id}"

      {:ok, room} =
        %Platform.Meetings.Room{}
        |> Platform.Meetings.Room.changeset(%{
          space_id: space.id,
          livekit_room_name: room_name
        })
        |> Repo.insert()

      {space, room}
    end

    defp presence_transcript!(space_id, room_name) do
      {:ok, transcript} =
        Meetings.create_transcript(%{room_id: room_name, space_id: space_id})

      transcript
    end

    defp join!(room, display_name, seconds_ago, opts \\ []) do
      joined_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

      left_at =
        case Keyword.get(opts, :present_for) do
          nil -> nil
          secs -> DateTime.add(joined_at, secs, :second)
        end

      {:ok, participant} =
        Meetings.participant_joined(room, %{
          display_name: display_name,
          joined_at: joined_at,
          left_at: left_at,
          metadata: Keyword.get(opts, :metadata, %{})
        })

      participant
    end

    test "transcript room_id is a NAME, not the participants' UUID FK" do
      # The bug this guards: `meeting_transcripts.room_id` holds the LiveKit
      # room name while `meeting_participants.room_id` holds the meeting_rooms
      # UUID. A direct join between them silently matches nothing.
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      refute transcript.room_id == room.id
      assert transcript.room_id == room.livekit_room_name
    end

    test "returns the longest window when a marker participant was present" do
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "meeting-transcriber", 600, present_for: 600)

      assert Meetings.transcriber_presence_seconds(transcript) >= 600
      assert Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "a marker participant present only briefly is below threshold" do
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "meeting-transcriber", 5, present_for: 5)

      assert Meetings.transcriber_presence_seconds(transcript) == 5
      refute Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "human participants alone never count as transcriber presence" do
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "Harper", 3600)
      join!(room, "Alex", 3600)

      assert Meetings.transcriber_presence_seconds(transcript) == 0
      refute Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "a nil left_at is measured to now rather than skipped" do
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      # room_finished can fire before the transcriber's leave webhook lands.
      join!(room, "meeting-transcriber", 1800)

      assert Meetings.transcriber_presence_seconds(transcript) >= 1800
      assert Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "matches the marker in metadata identity as well as display_name" do
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "Transcription Bot", 600,
        metadata: %{"identity" => "meeting-transcriber-#{Ecto.UUID.generate()}"}
      )

      assert Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "an unresolvable room name returns 0 without raising" do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      transcript = presence_transcript!(space.id, "space-#{Ecto.UUID.generate()}")

      assert Meetings.transcriber_presence_seconds(transcript) == 0
      refute Meetings.transcriber_present_for_threshold?(transcript)
      assert Meetings.transcriber_presence_seconds(nil) == 0
    end

    test "a transcriber: identity resolves to no FK — parse_identity returns :unknown" do
      # Why the marker match runs over display_name/metadata rather than the
      # parsed identity kind: parse_identity/1 accepts only the identities
      # Suite itself mints (user:/agent:/guest:), so a transcriber lands as a
      # nil-FK row whatever prefix it joins with. This says nothing about
      # which prefix the external worker actually uses.
      assert Meetings.parse_identity("transcriber:" <> Ecto.UUID.generate()) == :unknown
    end

    test "an identity-prefix marker alone is enough to detect a transcriber" do
      # The `transcriber:` entry in @transcriber_identity_markers is not
      # decorative. A row whose display_name matches no marker is detected by
      # that entry alone, via metadata["identity"]. Mutation: delete
      # `"transcriber:"` from the marker list and this test fails.
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "Transcription", 600, metadata: %{"identity" => "transcriber:#{room_name}"})

      assert Meetings.transcriber_presence_seconds(transcript) >= 600
      assert Meetings.transcriber_present_for_threshold?(transcript)
    end

    test "a display name carrying no marker is not a transcriber on its own" do
      # The counterpart to the test above, and the reason the identity marker
      # carries the check: "Transcription" contains neither marker, so an
      # identityless row with that display_name measures zero. Mutation: add
      # a `"transcription"` marker to the list and this test fails.
      {space, room} = presence_room!()
      room_name = room.livekit_room_name
      transcript = presence_transcript!(space.id, room_name)

      join!(room, "Transcription", 3600)

      assert Meetings.transcriber_presence_seconds(transcript) == 0
      refute Meetings.transcriber_present_for_threshold?(transcript)
    end
  end

  describe "fail_transcript/1,2" do
    defp failing_transcript! do
      {:ok, space} = Chat.create_space(%{kind: "execution"})

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          space_id: space.id
        })

      transcript
    end

    test "arity-2 stores the failed status and the given reason" do
      transcript = failing_transcript!()

      assert {:ok, failed} = Meetings.fail_transcript(transcript.id, "no transcript arrived")

      reloaded = Meetings.get_transcript(failed.id)
      assert reloaded.status == "failed"
      assert reloaded.summary == "no transcript arrived"
      assert reloaded.completed_at
    end

    test "arity-1 still marks failed and leaves the summary untouched" do
      transcript = failing_transcript!()
      {:ok, _} = Meetings.update_transcript_summary(transcript.id, "partial work")

      assert {:ok, _} = Meetings.fail_transcript(transcript.id)

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "failed"
      assert reloaded.summary == "partial work"
    end

    test "emits transcription_failed telemetry carrying the transcript id" do
      transcript = failing_transcript!()

      # Scoped to this transcript and detached on exit by the helper: a global
      # detach here would silently disarm telemetry for unrelated tests.
      Platform.TelemetryHelpers.attach_scoped(
        [:platform, :meetings, :transcription_failed],
        {:transcript_id, transcript.id},
        self()
      )

      {:ok, _} = Meetings.fail_transcript(transcript.id, "no transcript arrived")

      assert_receive {:telemetry, [:platform, :meetings, :transcription_failed], measurements,
                      metadata}

      assert metadata.transcript_id == transcript.id
      assert metadata.room_id == transcript.room_id
      assert is_integer(measurements.presence_seconds)
    end

    # Task 01a089b3-7f84 stage 1 — the telemetry→audit bridge for transcript
    # failure. This is LOAD-BEARING for the later stages of this task, which
    # CLEAR `failure_reason` on a successful retry: once that lands, the
    # audit row is the only durable record that a transcript ever failed.
    #
    # DEMONSTRATED RED: removing `[:platform, :meetings, :transcription_failed]`
    # from `Platform.Audit.TelemetryHandler`'s @events makes the test below
    # ("fail_transcript bridges into a durable audit row") fail with
    # `[] != one row` — the emit still succeeds and nothing raises, the row
    # simply never appears. The registration IS the mechanism.
    test "fail_transcript bridges into a durable audit row" do
      # `attach/0` is idempotent; call it so a handler detached by an earlier
      # raise in this VM cannot masquerade as a missing registration.
      Platform.Audit.TelemetryHandler.attach()
      transcript = failing_transcript!()

      {:ok, _} = Meetings.fail_transcript(transcript.id, nil, {:llm_failed, :boom})

      # NB: the column is `event_type`, not `event_name`.
      rows =
        Platform.Audit.Event
        |> Ecto.Query.where(event_type: "platform.meetings.transcription_failed")
        |> Platform.Repo.all()

      assert [row] = rows
      assert row.resource_id == transcript.id
      assert row.resource_type == "meeting_transcript"
      # "execute" here would mean the metadata enrichment was lost —
      # `build_attrs/3` defaults `action` when metadata omits it.
      assert row.action == "failed"
      assert row.metadata["failure_reason"] =~ "llm_failed"
    end

    test "transcription_failed is registered on the audit telemetry handler" do
      assert [:platform, :meetings, :transcription_failed] in Platform.Audit.TelemetryHandler.events()
    end

    test "post_transcription_failure_to_space/2 posts a system notice naming no host" do
      {:ok, space} = Chat.create_space(%{kind: "execution"})
      transcript_id = Ecto.UUID.generate()

      assert :ok = Meetings.post_transcription_failure_to_space(space.id, transcript_id)

      message =
        space.id
        |> Chat.list_messages(limit: 50)
        |> Enum.find(&(&1.metadata["source"] == "meeting_transcription_failure"))

      assert message
      assert message.content_type == "system"
      assert message.metadata["transcript_id"] == transcript_id
      refute message.content =~ "http"
      refute message.content =~ "://"
    end

    test "returns :not_found for an unknown transcript" do
      assert {:error, :not_found} = Meetings.fail_transcript(Ecto.UUID.generate(), "reason")
    end
  end

  describe "UUID boundary: Meetings getters are total over their input" do
    @slug_16 "higginshigginsxx"

    test "get_meeting/1, get_room/1 and the transcript getters return nil" do
      for id <- ["higgins", @slug_16, ""] do
        assert Meetings.get_meeting(id) == nil
        assert Meetings.get_room(id) == nil
        assert Meetings.get_transcript(id) == nil
        assert Meetings.get_transcript_with_segments(id) == nil
      end
    end

    test "recording transitions never raise a cast error on a malformed id" do
      # guard_enabled/0 runs FIRST in both with-chains, so in a suite with
      # meetings disabled the observable outcome is :meetings_disabled. What
      # this asserts is the absence of Ecto.Query.CastError either way — the
      # webhook body's recording_id is not trusted at any point in the chain.
      assert {:error, reason} = Meetings.stop_recording(@slug_16)
      assert reason in [:not_found, :meetings_disabled]

      assert {:error, reason} = Meetings.recording_completed(@slug_16, %{})
      assert reason in [:not_found, :meetings_disabled]
    end
  end

  describe "meeting_live?/1" do
    defp live_predicate_meeting! do
      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Live Predicate #{System.unique_integer([:positive])}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Standup #{System.unique_integer([:positive])}"
        })

      meeting
    end

    test "true while the meeting is live, false once it has ended" do
      meeting = live_predicate_meeting!()
      {:ok, live} = Meetings.start_meeting(meeting)

      assert Meetings.meeting_live?(live.id)

      {:ok, ended} = Meetings.end_meeting(live)
      refute Meetings.meeting_live?(ended.id)
    end

    test "false for a meeting that is genuinely absent" do
      refute Meetings.meeting_live?(Ecto.UUID.generate())
    end

    # Ambiguity must never dismiss the caller's row: an id we cannot resolve
    # at all reads as still-live.
    test "true for an id that cannot name a row at all" do
      assert Meetings.meeting_live?(nil)
      assert Meetings.meeting_live?(:not_an_id)
      assert Meetings.meeting_live?("not-a-uuid")
    end
  end

  describe "claim lifecycle across failure (task 01a0826f)" do
    defp create_claimable_transcript do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      transcript
    end

    test "a transcript that fails releases its claim so a retry can claim again" do
      transcript = create_claimable_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      assert {:ok, _failed} =
               Meetings.fail_transcript(
                 transcript.id,
                 nil,
                 {:llm_failed, %RuntimeError{message: "timeout"}}
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert is_nil(reloaded.router_dispatched_at)
      assert reloaded.status == "failed"
      assert reloaded.failure_reason =~ "timeout"

      # The assertion that matters: the retry actually runs.
      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      # Releasing the claim did not erase why it failed.
      retried = Meetings.get_transcript(retried_id = transcript.id)
      assert retried.id == retried_id
      assert retried.status == "failed"
      assert retried.failure_reason =~ "timeout"
    end

    test "a released claim is still exclusive — only one of two concurrent retries wins" do
      transcript = create_claimable_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      assert {:ok, _failed} =
               Meetings.fail_transcript(
                 transcript.id,
                 nil,
                 {:llm_failed, %RuntimeError{message: "timeout"}}
               )

      # Releasing the claim re-opens the door ONCE, not for everybody. A
      # claim predicate that also admitted `status = "failed"` rows would
      # let both retries through and reinstate the duplicate dispatch the
      # claim exists to prevent — so the ORDER of these two results is the
      # assertion, not just their set.
      results = [
        Meetings.claim_router_dispatch(transcript.id),
        Meetings.claim_router_dispatch(transcript.id)
      ]

      assert results == [{:ok, :claimed}, {:error, :already_dispatched}]
    end

    test "a failure followed by a successful retry produces exactly one completed summary" do
      transcript = create_claimable_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      assert {:ok, _failed} =
               Meetings.fail_transcript(
                 transcript.id,
                 nil,
                 {:llm_failed, %RuntimeError{message: "timeout"}}
               )

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)

      assert {:ok, %{status: "complete", summary: "retry summary"}} =
               Meetings.complete_transcript(transcript.id, "retry summary")

      completed = Meetings.get_transcript(transcript.id)
      assert completed.status == "complete"
      assert completed.summary == "retry summary"
      assert completed.completed_at

      # The retry holds its OWN claim through completion. Only `failed`
      # releases — a completed row that let go of the claim would invite a
      # second `complete_transcript/2` write over the summary that already
      # landed, which is the exact race the claim was introduced to stop.
      refute is_nil(completed.router_dispatched_at)
      assert Meetings.claim_router_dispatch(transcript.id) == {:error, :already_dispatched}
    end

    test "completing a transcript never releases the claim" do
      transcript = create_claimable_transcript()

      assert {:ok, :claimed} = Meetings.claim_router_dispatch(transcript.id)
      claimed_at = Meetings.get_transcript(transcript.id).router_dispatched_at
      refute is_nil(claimed_at)

      assert {:ok, _completed} = Meetings.complete_transcript(transcript.id, "a summary")

      # Guards the stage-1 edit against being copy-pasted from
      # `fail_transcript/3` into `complete_transcript/2`: the claim must be
      # byte-identical across a completion, not merely still present.
      assert Meetings.get_transcript(transcript.id).router_dispatched_at == claimed_at
    end
  end

  describe "complete_transcript/2 clears failure_reason (task 01a089b3 stage 2)" do
    defp armed_transcript do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-1",
          "text" => "we agreed to ship on friday",
          "start_time" => 0,
          "end_time" => 1000
        })

      transcript
    end

    test "a transcript that failed and then succeeded carries no failure_reason" do
      transcript = armed_transcript()

      assert {:ok, failed} =
               Meetings.fail_transcript(transcript.id, nil, {:llm_failed, %{reason: :timeout}})

      # Assert the trap is ARMED before asserting it springs. Without this the
      # test passes for the wrong reason: a `failure_reason` that was never
      # written is trivially nil after completion, which is exactly the
      # vacuous ordering (succeed-then-assert) this test exists to avoid.
      refute is_nil(failed.failure_reason)
      assert failed.failure_reason =~ "timeout"

      assert {:ok, _completed} = Meetings.complete_transcript(transcript.id, "a real summary")

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary == "a real summary"

      # The fix. `failure_reason` is a one-slot latch for why the row is
      # CURRENTLY failed; a completed row holding one makes healthy
      # transcripts answer `where not is_nil(failure_reason)`.
      assert is_nil(reloaded.failure_reason)
    end

    test "fail_transcript/3 still SETS the reason it is asked to record" do
      transcript = armed_transcript()

      assert {:ok, failed} =
               Meetings.fail_transcript(transcript.id, nil, {:llm_failed, %{reason: :timeout}})

      # Positive control: the fix must be "clear on success", not "never
      # write this column". A blanket removal of the write turns this red.
      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "failed"
      refute is_nil(reloaded.failure_reason)
      assert reloaded.failure_reason == failed.failure_reason
      assert reloaded.failure_reason =~ "llm_failed"
      assert reloaded.failure_reason =~ "timeout"
    end

    test "no completed row anywhere answers a not-null failure_reason audit query" do
      transcript = armed_transcript()

      {:ok, _} = Meetings.fail_transcript(transcript.id, nil, {:llm_failed, %{reason: :timeout}})
      {:ok, _} = Meetings.complete_transcript(transcript.id, "a real summary")

      # The shape an operator actually runs to find broken transcripts. This
      # is the query the unfixed code made lie.
      count =
        Platform.Repo.one(
          from(t in "meeting_transcripts",
            where: t.status == "complete" and not is_nil(t.failure_reason),
            select: count()
          )
        )

      assert count == 0
    end
  end

  describe "meeting_transcripts_no_reason_when_complete constraint (task 01a089b3 stage 3)" do
    # These insert through `Repo` DIRECTLY, bypassing `Transcript.changeset/2`.
    # That is the point: a test that only drove `complete_transcript/2` would
    # pass with no constraint in the database at all, because stage 2's writer
    # fix already clears the column. Only a raw insert proves the DDL exists.
    defp raw_insert(status, failure_reason) do
      now = DateTime.utc_now()

      Repo.insert_all(
        "meeting_transcripts",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            room_id: "space-#{Ecto.UUID.generate()}",
            segments: [],
            status: status,
            failure_reason: failure_reason,
            inserted_at: now,
            updated_at: now
          }
        ]
      )
    end

    test "a complete row with a failure_reason cannot be inserted at all" do
      assert_raise Postgrex.Error, ~r/meeting_transcripts_no_reason_when_complete/, fn ->
        raw_insert("complete", "{:llm_failed, :timeout}")
      end
    end

    test "the constraint does not over-reach: a failed row keeps its reason" do
      assert {1, _} = raw_insert("failed", "{:llm_failed, :timeout}")

      assert Repo.exists?(
               from(t in Transcript,
                 where: t.status == "failed" and not is_nil(t.failure_reason)
               )
             )
    end

    test "a complete row with a NULL failure_reason inserts fine" do
      assert {1, _} = raw_insert("complete", nil)
    end

    test "stages 2 and 3 compose: completing a failed transcript returns {:ok, _}" do
      transcript = armed_transcript()

      assert {:ok, failed} =
               Meetings.fail_transcript(transcript.id, nil, {:llm_failed, %{reason: :timeout}})

      refute is_nil(failed.failure_reason)

      # Stage 2 clears the column, so stage 3's constraint is satisfied and the
      # caller sees the ordinary success return — not `{:error, changeset}` and
      # not a raised `Postgrex.Error` mid-success-path.
      assert {:ok, completed} = Meetings.complete_transcript(transcript.id, "we shipped")
      assert completed.status == "complete"
      assert is_nil(completed.failure_reason)
    end

    test "a changeset that would violate the constraint returns {:error, changeset}" do
      assert {1, _} = raw_insert("failed", "{:llm_failed, :timeout}")

      transcript =
        Repo.one!(from(t in Transcript, where: t.status == "failed", limit: 1))

      assert {:error, changeset} =
               transcript
               |> Transcript.changeset(%{status: "complete"})
               |> Repo.update()

      assert {"cannot be set on a complete transcript", _} = changeset.errors[:failure_reason]
    end
  end

  describe "unrecovered_failures/1 and stale_failure_reason_count/0 (task 01a089b3 stage 4)" do
    # Reproduces the incident shape: 5 rows still failed with a timeout-shaped
    # reason, PLUS ONE that failed with the SAME reason and then recovered via
    # complete_transcript/2. A fixture that seeds only never-failed rows would
    # be vacuous here — the recovered row is the entire discriminator between
    # "counts 5" (correct) and "counts 6" (the incident).
    defp fresh_transcript do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: "space-#{Ecto.UUID.generate()}",
          status: "processing"
        })

      transcript
    end

    setup do
      still_failed_ids =
        for _ <- 1..5 do
          transcript = fresh_transcript()

          {:ok, failed} =
            Meetings.fail_transcript(
              transcript.id,
              nil,
              {:llm_failed, %Req.TransportError{reason: :timeout}}
            )

          failed.id
        end

      recovered =
        fresh_transcript()
        |> then(fn transcript ->
          {:ok, failed} =
            Meetings.fail_transcript(
              transcript.id,
              nil,
              {:llm_failed, %Req.TransportError{reason: :timeout}}
            )

          failed
        end)

      {:ok, recovered} = Meetings.complete_transcript(recovered.id, "recovered on retry")

      # The live discriminator for the mutation probe below: a row that is
      # NOT `failed` (here `recording`) yet still carries a timeout-shaped
      # `failure_reason`. It models PRE-FIX PRODUCTION ROWS — transcripts that
      # failed, were rejoined through `reopen_transcript/1` before task
      # 01a08a25 made it clear the column, and are still sitting in
      # `recording`/`processing` with the old reason. No code path writes this
      # shape any more (`complete_transcript/2` and `reopen_transcript/1` both
      # clear), so it is inserted RAW via `raw_insert/2`, bypassing the
      # changeset; the CHECK constraint is scoped to `complete` and permits it.
      # A `failure_reason`-only filter misclassifies this row as an
      # unrecovered failure. This is the case `status == "failed"` guards.
      {1, _} = raw_insert("recording", "{:llm_failed, %Req.TransportError{reason: :timeout}}")

      raw_recording_id =
        Repo.one!(
          from(t in Transcript,
            where: t.status == "recording" and ilike(t.failure_reason, "%timeout%"),
            select: t.id
          )
        )

      # Non-matching failed row: guards against `:reason_matching` being
      # applied unconditionally even when the caller passes no opts.
      other = fresh_transcript()

      {:ok, other_failed} =
        Meetings.fail_transcript(other.id, nil, {:llm_failed, :bad_audio_format})

      %{
        still_failed_ids: still_failed_ids,
        recovered_id: recovered.id,
        raw_recording_id: raw_recording_id,
        other_failed_id: other_failed.id
      }
    end

    test "unrecovered_failures(reason_matching: \"timeout\") returns exactly the 5 still-failed rows",
         %{
           still_failed_ids: still_failed_ids,
           recovered_id: recovered_id,
           raw_recording_id: raw_recording_id
         } do
      results = Meetings.unrecovered_failures(reason_matching: "timeout")
      result_ids = Enum.map(results, & &1.id)

      assert length(results) == 5
      assert Enum.sort(result_ids) == Enum.sort(still_failed_ids)
      refute recovered_id in result_ids
      refute raw_recording_id in result_ids
    end

    # A completed-via-`complete_transcript/2` recovery no longer produces a
    # miscount at all: stage 2 clears `failure_reason` on success and stage
    # 3's CHECK constraint forbids a `complete` row from carrying one, so
    # `failure_reason IS NOT NULL` alone already excludes it. Asserted here
    # so a regression in either of those (the column write, or the
    # constraint) is caught as a naive-query mismatch, not silently absorbed.
    test "a failure_reason-only filter already excludes the complete_transcript/2 recovery", %{
      recovered_id: recovered_id
    } do
      naive_ids =
        Repo.all(
          from(t in Transcript,
            where: not is_nil(t.failure_reason) and ilike(t.failure_reason, "%timeout%"),
            select: t.id
          )
        )

      refute recovered_id in naive_ids
    end

    # The mutation probe: dropping the `status == "failed"` clause from the
    # query (i.e. filtering on `failure_reason` alone) makes this fixture
    # return 6 instead of 5 and the `correct_count == 5` assertion below go
    # red. The raw `recording` row (a pre-fix production shape) is what
    # supplies the 6th row — neither recovery path can any more:
    # complete_transcript/2 clears the column (previous test) and, since task
    # 01a08a25, so does reopen_transcript/1. This is the evidence the fixture
    # discriminates rather than passing vacuously.
    test "the status conjunction is load-bearing: without it the count would be 6, not 5" do
      naive_count =
        Repo.aggregate(
          from(t in Transcript,
            where: not is_nil(t.failure_reason) and ilike(t.failure_reason, "%timeout%")
          ),
          :count
        )

      assert naive_count == 6

      correct_count = length(Meetings.unrecovered_failures(reason_matching: "timeout"))
      assert correct_count == 5
      assert correct_count != naive_count
    end

    test "unrecovered_failures/0 with no opts includes a non-matching failed row", %{
      other_failed_id: other_failed_id
    } do
      result_ids = Meetings.unrecovered_failures() |> Enum.map(& &1.id)

      assert other_failed_id in result_ids
    end

    test "stale_failure_reason_count/0 is 0 for this fixture" do
      assert Meetings.stale_failure_reason_count() == 0
    end
  end

  describe "reopen_transcript/1 clears failure_reason (task 01a08a25)" do
    # Decision: CLEAR on reopen. `failure_reason` is why the row is CURRENTLY
    # failed; a reopened row is not failed, and failure history is durable in
    # `audit_events`. Every test here FAILS a row with a reason first and
    # asserts the reason is present before reopening — a test that reopens a
    # never-failed row would pass against the unfixed code and prove nothing.
    defp processing_transcript(room_id \\ "space-#{Ecto.UUID.generate()}") do
      {:ok, transcript} =
        Meetings.create_transcript(%{room_id: room_id, status: "processing"})

      transcript
    end

    defp failure_audit_count(transcript_id) do
      Repo.aggregate(
        from(e in Platform.Audit.Event,
          where:
            e.event_type == "platform.meetings.transcription_failed" and
              e.resource_id == ^transcript_id
        ),
        :count
      )
    end

    test "fail -> reopen leaves the row recording with a NULL failure_reason" do
      transcript = processing_transcript()

      {:ok, failed} =
        Meetings.fail_transcript(
          transcript.id,
          nil,
          {:llm_failed, %Req.TransportError{reason: :timeout}}
        )

      # Precondition: without this the test is vacuous.
      refute is_nil(failed.failure_reason)
      assert failed.failure_reason =~ "timeout"

      assert {:ok, reopened} = Meetings.reopen_transcript(failed)
      assert reopened.status == "recording"
      assert is_nil(reopened.failure_reason)
      assert is_nil(reopened.completed_at)

      reloaded = Repo.reload!(reopened)
      assert reloaded.status == "recording"
      assert is_nil(reloaded.failure_reason)
    end

    test "the rejoin entry point ensure_transcript/1 reuses the failed row and clears its reason" do
      room_id = "space-#{Ecto.UUID.generate()}"
      transcript = processing_transcript(room_id)

      {:ok, failed} =
        Meetings.fail_transcript(
          transcript.id,
          nil,
          {:llm_failed, %Req.TransportError{reason: :timeout}}
        )

      refute is_nil(failed.failure_reason)

      assert {:ok, rejoined} = Meetings.ensure_transcript(%{room_id: room_id})
      assert rejoined.id == transcript.id
      assert rejoined.status == "recording"
      assert is_nil(rejoined.failure_reason)
      assert is_nil(Repo.reload!(rejoined).failure_reason)
    end

    # The misattribution case: `fail_transcript/1` passes `reason = nil`, which
    # does NOT overwrite the column. Were the first run's reason kept across the
    # reopen, it would be read as the explanation of the SECOND failure.
    test "a reason-less re-fail after reopen lands with a NULL reason, not the first run's" do
      transcript = processing_transcript()

      {:ok, failed} =
        Meetings.fail_transcript(
          transcript.id,
          nil,
          {:llm_failed, %Req.TransportError{reason: :timeout}}
        )

      refute is_nil(failed.failure_reason)

      {:ok, _reopened} = Meetings.reopen_transcript(failed)

      assert {:ok, refailed} = Meetings.fail_transcript(transcript.id)
      assert refailed.status == "failed"
      assert is_nil(refailed.failure_reason)
      assert is_nil(Repo.reload!(refailed).failure_reason)
    end

    # Positive control: the fix must not degenerate into "never write this
    # column". A re-fail WITH a reason still records it, and the audit log
    # keeps both failures even though the column held only one at a time.
    test "a re-fail with a reason after reopen records it, and both failures stay audited" do
      Platform.Audit.TelemetryHandler.attach()
      transcript = processing_transcript()

      {:ok, failed} =
        Meetings.fail_transcript(
          transcript.id,
          nil,
          {:llm_failed, %Req.TransportError{reason: :timeout}}
        )

      refute is_nil(failed.failure_reason)

      {:ok, _reopened} = Meetings.reopen_transcript(failed)

      assert {:ok, refailed} =
               Meetings.fail_transcript(transcript.id, nil, {:llm_failed, :bad_audio_format})

      assert refailed.status == "failed"
      assert refailed.failure_reason =~ "bad_audio_format"
      refute refailed.failure_reason =~ "timeout"
      assert failure_audit_count(transcript.id) == 2
    end
  end
end
