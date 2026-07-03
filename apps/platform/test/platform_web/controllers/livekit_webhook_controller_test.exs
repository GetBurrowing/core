defmodule PlatformWeb.LivekitWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Meetings

  @livekit_webhook_path "/api/webhooks/livekit"

  defp unique_room_id, do: Platform.Types.UUIDv7.generate()

  # LiveKit room names in Suite are `space-<uuid>` — the app-controlled
  # value that `Meetings.app_registered_room?/1` gates on. Using
  # `meeting-<sid>` here (as the original fixture did) would slip past
  # the guard added in this stage and mask coverage. The `sid` stays
  # opaque (LiveKit-side identifier) since `room_id` in the DB still
  # keys off `sid || name`.
  defp app_room_name, do: "space-#{Ecto.UUID.generate()}"

  defp room_started_payload(room_id, room_name \\ nil) do
    %{
      "event" => "room_started",
      "room" => %{
        "sid" => room_id,
        "name" => room_name || app_room_name()
      }
    }
  end

  defp room_finished_payload(room_id, room_name \\ nil) do
    %{
      "event" => "room_finished",
      "room" => %{
        "sid" => room_id,
        "name" => room_name || app_room_name()
      }
    }
  end

  defp transcription_payload(room_id, segments, room_name \\ nil) do
    %{
      "event" => "transcription",
      "room" => %{
        "sid" => room_id,
        "name" => room_name || app_room_name()
      },
      "segments" => segments
    }
  end

  defp sample_segment(overrides \\ %{}) do
    Map.merge(
      %{
        "participant_identity" => "user-#{System.unique_integer([:positive])}",
        "speaker_name" => "Alice",
        "text" => "Hello, this is a test segment.",
        "start_time" => 1000,
        "end_time" => 2000,
        "language" => "en",
        "final" => true
      },
      overrides
    )
  end

  # ── room_started tests ──────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — room_started" do
    test "creates a transcript record for a new room", %{conn: conn} do
      room_id = unique_room_id()
      payload = room_started_payload(room_id)

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "created", "transcript_id" => transcript_id} =
               json_response(conn, 201)

      assert is_binary(transcript_id)

      transcript = Meetings.get_transcript(transcript_id)
      assert transcript != nil
      assert transcript.room_id == room_id
      assert transcript.status == "recording"
    end

    test "returns existing transcript if one already exists", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, existing} = Meetings.create_transcript(%{room_id: room_id})

      payload = room_started_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "created", "transcript_id" => transcript_id} =
               json_response(conn, 201)

      assert transcript_id == existing.id
    end

    test "ignores event with no room identifier", %{conn: conn} do
      payload = %{"event" => "room_started", "room" => %{}}

      conn = post(conn, @livekit_webhook_path, payload)

      # With the app_registered_room?/1 guard in place, an empty room map
      # trips the guard branch first (no name → unregistered), so the
      # reason is "unregistered room" rather than "no room identifier".
      assert %{"status" => "ignored", "reason" => "unregistered room"} =
               json_response(conn, 200)
    end

    test "ignores room_started for phantom RM_<random> rooms", %{conn: conn} do
      # Phantom rooms (materialised without a prior `CreateRoom`) show
      # up as `RM_<random>` names — the guard must reject them before
      # any transcript is spawned.
      room_id = unique_room_id()

      payload = %{
        "event" => "room_started",
        "room" => %{"sid" => "RM_abc123", "name" => "RM_abc123"}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post(conn, @livekit_webhook_path, payload)

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(conn, 200)
        end)

      assert log =~ "Ignoring room_started for unregistered room"
      assert log =~ "RM_abc123"

      # No transcript row was created for either the sid or a
      # would-be app room_id.
      assert Meetings.get_transcript_for_room("RM_abc123") == nil
      assert Meetings.get_transcript_for_room(room_id) == nil
    end
  end

  # ── room_finished tests ─────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — room_finished" do
    test "finalizes an active transcript", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      payload = room_finished_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "finalized",
               "transcript_id" => ^transcript_id,
               "segment_count" => 0
             } = json_response(conn, 200)

      updated = Meetings.get_transcript(transcript.id)
      # Zero-segment transcripts are completed synchronously by the summarizer
      # (no LLM call needed), so status transitions directly to "complete"
      assert updated.status == "complete"
    end

    test "finalizes transcript with accumulated segments", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      # Add some segments first
      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-1",
          "text" => "Hello",
          "start_time" => 1000,
          "end_time" => 2000
        })

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-2",
          "text" => "World",
          "start_time" => 2000,
          "end_time" => 3000
        })

      payload = room_finished_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "finalized",
               "segment_count" => 2
             } = json_response(conn, 200)
    end

    test "ignores when no active transcript exists", %{conn: conn} do
      room_id = unique_room_id()
      payload = room_finished_payload(room_id)

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "no active transcript"} =
               json_response(conn, 200)
    end

    test "ignores already-finalized transcripts", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      {:ok, _} = Meetings.finalize_transcript(transcript.id)

      payload = room_finished_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)

      # get_transcript_for_room only finds "recording" status, so this is ignored
      assert %{"status" => "ignored", "reason" => "no active transcript"} =
               json_response(conn, 200)
    end

    test "ignores event with no room identifier", %{conn: conn} do
      payload = %{"event" => "room_finished", "room" => %{}}

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "no room identifier"} =
               json_response(conn, 200)
    end

    test "ends the space's live meeting on room_finished", %{conn: conn} do
      {:ok, project} = Platform.Tasks.create_project(%{name: "Webhook End #{unique_room_id()}"})

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "End Me #{unique_room_id()}"})

      {:ok, live} = Meetings.start_meeting(meeting)
      assert live.status == "live"

      # The LiveKit join path joins the `space-<chat_space_id>` room
      # (Meetings.ensure_room/1), so room_finished fires for that name.
      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => unique_room_id(), "name" => "space-#{live.chat_space_id}"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert json_response(conn, 200)

      ended = Meetings.get_meeting(live.id)
      assert ended.status == "ended"
      assert %DateTime{} = ended.ended_at
    end

    test "leaves a scheduled meeting unchanged (no illegal transition)", %{conn: conn} do
      {:ok, project} = Platform.Tasks.create_project(%{name: "Webhook Sched #{unique_room_id()}"})

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Sched #{unique_room_id()}"})

      assert meeting.status == "scheduled"

      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => unique_room_id(), "name" => "space-#{meeting.chat_space_id}"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert json_response(conn, 200)

      assert Meetings.get_meeting(meeting.id).status == "scheduled"
    end

    test "unknown room/space does not crash and returns 200", %{conn: conn} do
      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => unique_room_id(), "name" => "space-#{Ecto.UUID.generate()}"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert json_response(conn, 200)
    end

    test "broadcasts {:meeting_finished, payload} on canonical + per-room topics",
         %{conn: conn} do
      # M8 stage 3 — the responsibility router subscribes to the
      # canonical `meeting:finished` topic to fire `meetings.summarize`;
      # per-room subscribers (LiveViews) get the same event on
      # `meeting:finished:{room_id}`.
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      # Subscribe BEFORE the webhook so the broadcast can't outrun us.
      assert :ok = Platform.Meetings.PubSub.subscribe_meeting_finished()
      assert :ok = Platform.Meetings.PubSub.subscribe_meeting_finished(room_id)

      payload = room_finished_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)
      assert json_response(conn, 200)

      transcript_id = transcript.id

      # Canonical broadcast.
      assert_receive {:meeting_finished,
                      %{transcript_id: ^transcript_id, room_id: ^room_id} = canonical_payload},
                     1_000

      # Per-room broadcast.
      assert_receive {:meeting_finished,
                      %{transcript_id: ^transcript_id, room_id: ^room_id} = per_room_payload},
                     1_000

      # Both payloads carry the same keys (subscriber routing differs,
      # the message body is identical).
      assert Map.keys(canonical_payload) |> Enum.sort() ==
               [:room_id, :space_id, :transcript_id]

      assert Map.keys(per_room_payload) |> Enum.sort() ==
               [:room_id, :space_id, :transcript_id]
    end

    test "deactivates an active room back to idle (v4 stage 1 symmetry)", %{conn: conn} do
      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Finish Room Space",
          slug: "finish-room-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, active_room} = Meetings.activate_room(room)
      assert active_room.status == "active"
      assert Meetings.get_active_room(space.id) != nil

      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => active_room.id, "name" => active_room.livekit_room_name}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert json_response(conn, 200)

      # The join-path activation is now reversed by the empty-room webhook
      # so rooms don't leak as "active" forever.
      assert Meetings.get_active_room(space.id) == nil
      assert Meetings.get_room(active_room.id).status == "idle"
    end

    # Stage 3: defensive post-hoc sweep for phantom empty transcripts.
    # Stage 2's guards on room_started/transcription should keep these
    # from being created; the sweep here covers historical rows that
    # leaked in before this task shipped or any that race past the
    # source filter.

    test "deletes a phantom RM_<random> transcript with zero segments (sweep)",
         %{conn: conn} do
      room_id = unique_room_id()
      # Simulate a historical phantom transcript created before stage 2
      # landed — the `room_started` guard blocks new ones now, but old
      # rows keyed to unregistered names still exist in prod.
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      payload = room_finished_payload(room_id, "RM_phantom_abc123")
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "deleted",
               "reason" => "phantom_empty_transcript",
               "transcript_id" => ^transcript_id
             } = json_response(conn, 200)

      # Row is gone from the DB entirely — no finalize, no summary dispatch.
      assert Meetings.get_transcript(transcript_id) == nil
    end

    test "finalizes an app-registered room with zero segments (real short call)",
         %{conn: conn} do
      # Zero-segment transcripts for LEGIT rooms still get finalized so
      # the summarizer's handle_empty_transcript/1 path marks them
      # complete with an empty summary. Deleting them here would erase
      # real meetings that ended before audio streamed.
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      # Default app_room_name() emits `space-<uuid>` which passes the guard.
      payload = room_finished_payload(room_id)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "finalized",
               "transcript_id" => ^transcript_id,
               "segment_count" => 0
             } = json_response(conn, 200)

      # Persists, but transitions to complete via summarizer's empty path.
      updated = Meetings.get_transcript(transcript_id)
      assert updated != nil
      assert updated.status == "complete"
    end

    test "finalizes (does not delete) phantom room that somehow accumulated segments",
         %{conn: conn} do
      # Defensive fallback for the "shouldn't happen but might" case:
      # stage 2's transcription guard drops segments for unregistered
      # rooms, so this branch is only reachable if something bypassed
      # the guard OR the sweep runs against a historical row. Finalize
      # instead of delete — segments are user data.
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-legacy",
          "text" => "leaked segment",
          "start_time" => 1000,
          "end_time" => 2000
        })

      payload = room_finished_payload(room_id, "RM_leaked_xyz789")
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "finalized", "segment_count" => 1} = json_response(conn, 200)

      # Row still exists — we finalized, we didn't sweep.
      assert Meetings.get_transcript(transcript.id) != nil
    end
  end

  # ── end-to-end lifecycle + idempotence ──────────────────────────────────
  #
  # These tests stitch the individual handlers together to lock in the
  # full webhook flow → transcript persistence contract that stages 1-3
  # shipped. Any regression that breaks a single handler will usually
  # show up in one of the focused describes above; these guard the
  # *composed* behavior — replaying events, sweeping historical rows,
  # and never persisting a byte for a phantom room end-to-end.

  describe "POST #{@livekit_webhook_path} — end-to-end lifecycle + idempotence" do
    test "full lifecycle for an app-registered room persists segments then finalizes",
         %{conn: conn} do
      # room_started → transcription (3 segments) → room_finished. Assert
      # the final DB row carries the segments AND has been advanced past
      # "recording" by the finalize step (zero-segment app rooms
      # transition straight to "complete" via the summarizer's empty
      # path; multi-segment ones sit at "processing" until the async
      # summary lands).
      room_id = unique_room_id()
      room_name = app_room_name()

      start_conn = post(conn, @livekit_webhook_path, room_started_payload(room_id, room_name))

      assert %{"status" => "created", "transcript_id" => transcript_id} =
               json_response(start_conn, 201)

      segments = [
        sample_segment(%{"text" => "One", "participant_identity" => "user-a"}),
        sample_segment(%{"text" => "Two", "participant_identity" => "user-b"}),
        sample_segment(%{"text" => "Three", "participant_identity" => "user-a"})
      ]

      trans_conn =
        post(conn, @livekit_webhook_path, transcription_payload(room_id, segments, room_name))

      assert %{
               "status" => "appended",
               "transcript_id" => ^transcript_id,
               "segments_appended" => 3
             } = json_response(trans_conn, 200)

      # Row now has 3 segments and is still "recording".
      mid = Meetings.get_transcript(transcript_id)
      assert length(mid.segments) == 3
      assert mid.status == "recording"

      finish_conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id, room_name))

      assert %{
               "status" => "finalized",
               "transcript_id" => ^transcript_id,
               "segment_count" => 3
             } = json_response(finish_conn, 200)

      final = Meetings.get_transcript(transcript_id)
      # Segments survive finalize.
      assert length(final.segments) == 3
      assert Enum.map(final.segments, & &1["text"]) == ["One", "Two", "Three"]
      # Multi-segment path leaves the row at "processing" — the async
      # summary task advances it to "complete" once the LLM returns.
      # Accept either since the summarizer is triggered synchronously
      # under the test task supervisor and MAY have completed already.
      assert final.status in ["processing", "complete"]
    end

    test "phantom RM_<random> lifecycle end-to-end never persists a row",
         %{conn: conn} do
      # room_started → transcription → room_finished for a phantom
      # `RM_<random>` room must be a total no-op on `meeting_transcripts`.
      # This is the whole point of stages 1-3 as a stack.
      phantom_name = "RM_abc123"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_conn =
            post(conn, @livekit_webhook_path, %{
              "event" => "room_started",
              "room" => %{"sid" => phantom_name, "name" => phantom_name}
            })

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(start_conn, 200)

          trans_conn =
            post(conn, @livekit_webhook_path, %{
              "event" => "transcription",
              "room" => %{"sid" => phantom_name, "name" => phantom_name},
              "segments" => [sample_segment(%{"text" => "Never stored"})]
            })

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(trans_conn, 200)

          finish_conn =
            post(conn, @livekit_webhook_path, %{
              "event" => "room_finished",
              "room" => %{"sid" => phantom_name, "name" => phantom_name}
            })

          # No transcript ever existed for this room_id, so room_finished
          # falls through the sweep branch (guard-triggered nil lookup) to
          # the "no active transcript" ignore.
          assert %{"status" => "ignored", "reason" => "no active transcript"} =
                   json_response(finish_conn, 200)
        end)

      # Guards fired for both room_started and transcription.
      assert log =~ "Ignoring room_started for unregistered room"
      assert log =~ "Ignoring transcription for unregistered room"

      # Absolute zero rows in `meeting_transcripts` for this phantom room.
      assert Meetings.get_transcript_for_room(phantom_name) == nil
      assert count_transcripts_for_room(phantom_name) == 0
    end

    test "room_finished sweeps a pre-existing phantom transcript (backfill catch)",
         %{conn: conn} do
      # Simulates a row that leaked in before stage 2's source-filter
      # shipped. Stage 3's post-hoc sweep must delete it on the
      # canonical `room_finished` cleanup signal.
      room_id = "RM_pre_existing"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      finish_conn =
        post(conn, @livekit_webhook_path, %{
          "event" => "room_finished",
          "room" => %{"sid" => room_id, "name" => room_id}
        })

      assert %{
               "status" => "deleted",
               "reason" => "phantom_empty_transcript",
               "transcript_id" => ^transcript_id
             } = json_response(finish_conn, 200)

      # Row gone from the DB entirely.
      assert Meetings.get_transcript(transcript_id) == nil
      assert count_transcripts_for_room(room_id) == 0
    end

    test "replaying room_started is idempotent for an app room (single row)",
         %{conn: conn} do
      room_id = unique_room_id()
      room_name = app_room_name()

      first_conn = post(conn, @livekit_webhook_path, room_started_payload(room_id, room_name))

      assert %{"status" => "created", "transcript_id" => first_id} =
               json_response(first_conn, 201)

      second_conn = post(conn, @livekit_webhook_path, room_started_payload(room_id, room_name))

      assert %{"status" => "created", "transcript_id" => second_id} =
               json_response(second_conn, 201)

      # ensure_transcript returns the existing row on the second call.
      assert first_id == second_id
      assert count_transcripts_for_room(room_id) == 1
    end

    test "replaying room_started is idempotent for a phantom room (zero rows)",
         %{conn: conn} do
      # Two consecutive room_started deliveries for the same phantom
      # room must both bounce off the guard. No transcript created,
      # ever. This matters because LiveKit's webhook retry logic will
      # re-deliver on 5xx / delivery-not-acked, and we've historically
      # returned 200 for the phantom path.
      phantom_payload = %{
        "event" => "room_started",
        "room" => %{"sid" => "RM_replay_1", "name" => "RM_replay_1"}
      }

      _ =
        ExUnit.CaptureLog.capture_log(fn ->
          first_conn = post(conn, @livekit_webhook_path, phantom_payload)

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(first_conn, 200)

          second_conn = post(conn, @livekit_webhook_path, phantom_payload)

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(second_conn, 200)
        end)

      assert count_transcripts_for_room("RM_replay_1") == 0
    end

    test "replaying room_finished on an app room finalizes once, then ignores",
         %{conn: conn} do
      # First `room_finished` finalizes the recording transcript to
      # "complete" (zero-segment app-room path via the empty summarizer).
      # A second `room_finished` finds no *active* (recording) transcript
      # — `get_transcript_for_room/1` filters by `status == "recording"`
      # — and returns the "no active transcript" ignore without touching
      # the completed row or crashing.
      room_id = unique_room_id()
      room_name = app_room_name()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      first_conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id, room_name))

      assert %{
               "status" => "finalized",
               "transcript_id" => ^transcript_id,
               "segment_count" => 0
             } = json_response(first_conn, 200)

      after_first = Meetings.get_transcript(transcript_id)
      assert after_first.status == "complete"

      second_conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id, room_name))

      assert %{"status" => "ignored", "reason" => "no active transcript"} =
               json_response(second_conn, 200)

      # Row unchanged.
      after_second = Meetings.get_transcript(transcript_id)
      assert after_second.status == "complete"
      assert after_second.id == transcript_id
    end

    test "replaying room_finished on a phantom backfill deletes once, then ignores",
         %{conn: conn} do
      # Pre-insert a legacy phantom row. First `room_finished` sweeps it.
      # Second `room_finished` finds nothing to look up (row is gone) and
      # returns the same "no active transcript" ignore without crashing.
      room_id = "RM_replay_finish"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => room_id, "name" => room_id}
      }

      first_conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "deleted",
               "reason" => "phantom_empty_transcript",
               "transcript_id" => ^transcript_id
             } = json_response(first_conn, 200)

      assert Meetings.get_transcript(transcript_id) == nil

      second_conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "no active transcript"} =
               json_response(second_conn, 200)

      assert count_transcripts_for_room(room_id) == 0
    end
  end

  # Helper: hit the DB directly (not `get_transcript_for_room/1`, which
  # filters by `status == "recording"`) so idempotence tests can assert
  # on the *total* row count for a given room_id, including any that
  # transitioned to processing/complete or that we expect to be zero.
  defp count_transcripts_for_room(room_id) do
    import Ecto.Query, only: [from: 2]

    Platform.Repo.one(
      from(t in Platform.Meetings.Transcript,
        where: t.room_id == ^room_id,
        select: count(t.id)
      )
    )
  end

  # ── transcription tests ─────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — transcription" do
    test "appends segments to an existing transcript", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})
      transcript_id = transcript.id

      segments = [
        sample_segment(%{"text" => "First segment", "participant_identity" => "user-1"}),
        sample_segment(%{"text" => "Second segment", "participant_identity" => "user-2"})
      ]

      payload = transcription_payload(room_id, segments)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "appended",
               "transcript_id" => ^transcript_id,
               "segments_appended" => 2
             } = json_response(conn, 200)

      updated = Meetings.get_transcript(transcript.id)
      assert length(updated.segments) == 2
      assert Enum.at(updated.segments, 0)["text"] == "First segment"
      assert Enum.at(updated.segments, 1)["text"] == "Second segment"
    end

    test "auto-creates transcript if none exists", %{conn: conn} do
      room_id = unique_room_id()

      segments = [sample_segment(%{"text" => "Auto-created transcript"})]
      payload = transcription_payload(room_id, segments)

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "appended",
               "transcript_id" => transcript_id,
               "segments_appended" => 1
             } = json_response(conn, 200)

      transcript = Meetings.get_transcript(transcript_id)
      assert transcript != nil
      assert transcript.room_id == room_id
      assert length(transcript.segments) == 1
    end

    test "normalizes segment fields", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      # Use alternative field names that LiveKit might send
      segments = [
        %{
          "identity" => "user-alt",
          "name" => "Bob",
          "text" => "Alternative fields",
          "start_time" => 500,
          "end_time" => 1500,
          "language" => "en"
        }
      ]

      payload = transcription_payload(room_id, segments)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "appended"} = json_response(conn, 200)

      updated = Meetings.get_transcript(transcript.id)
      seg = hd(updated.segments)
      assert seg["participant_identity"] == "user-alt"
      assert seg["speaker_name"] == "Bob"
    end

    test "handles multiple sequential transcription events", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      # First batch
      payload1 =
        transcription_payload(room_id, [
          sample_segment(%{"text" => "Batch 1, seg 1"}),
          sample_segment(%{"text" => "Batch 1, seg 2"})
        ])

      conn1 = post(conn, @livekit_webhook_path, payload1)
      assert %{"segments_appended" => 2} = json_response(conn1, 200)

      # Second batch
      payload2 =
        transcription_payload(room_id, [
          sample_segment(%{"text" => "Batch 2, seg 1"})
        ])

      conn2 = post(conn, @livekit_webhook_path, payload2)
      assert %{"segments_appended" => 1} = json_response(conn2, 200)

      updated = Meetings.get_transcript(transcript.id)
      assert length(updated.segments) == 3
    end

    test "ignores event with empty segments", %{conn: conn} do
      room_id = unique_room_id()
      payload = transcription_payload(room_id, [])

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored"} = json_response(conn, 200)
    end

    test "ignores event with no room identifier", %{conn: conn} do
      payload = %{
        "event" => "transcription",
        "room" => %{},
        "segments" => [sample_segment()]
      }

      conn = post(conn, @livekit_webhook_path, payload)

      # Guard-first: empty room map → unregistered room.
      assert %{"status" => "ignored", "reason" => "unregistered room"} =
               json_response(conn, 200)
    end

    test "ignores transcription for phantom RM_<random> rooms without appending", %{conn: conn} do
      # If a transcription event fires for a phantom LiveKit room, we
      # must NOT auto-create a transcript and MUST NOT append segments.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          payload = %{
            "event" => "transcription",
            "room" => %{"sid" => "RM_xyz789", "name" => "RM_xyz789"},
            "segments" => [sample_segment(%{"text" => "Should never persist"})]
          }

          conn = post(conn, @livekit_webhook_path, payload)

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(conn, 200)
        end)

      assert log =~ "Ignoring transcription for unregistered room"
      assert Meetings.get_transcript_for_room("RM_xyz789") == nil
    end
  end

  # ── Unhandled events ────────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — unhandled events" do
    test "ignores unknown event types", %{conn: conn} do
      payload = %{"event" => "egress_started", "room" => %{"sid" => "room-1"}}

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "unhandled event: egress_started"} =
               json_response(conn, 200)
    end

    test "ignores payloads without event field", %{conn: conn} do
      conn = post(conn, @livekit_webhook_path, %{"foo" => "bar"})

      assert %{"status" => "ignored", "reason" => "no event field"} =
               json_response(conn, 200)
    end
  end

  # ── participant_joined / participant_left tests ──────────────────────────

  describe "POST #{@livekit_webhook_path} — participant_joined" do
    test "upserts a meeting_participants row with a resolvable user_id", %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()

      payload = %{
        "event" => "participant_joined",
        "room" => %{"name" => room.livekit_room_name},
        "participant" => %{"identity" => "user:#{user.id}", "name" => "Ada Lovelace"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert %{"status" => "ok"} = json_response(conn, 200)

      [p] = Meetings.active_participants(room.id)
      assert p.user_id == user.id
      assert p.display_name == "Ada Lovelace"
    end

    test "resolves an agent identity to agent_id", %{conn: conn} do
      %{room: room} = seed_room_and_user()
      agent = seed_agent()

      payload = %{
        "event" => "participant_joined",
        "room" => %{"name" => room.livekit_room_name},
        "participant" => %{"identity" => "agent:#{agent.id}", "name" => "Summarizer"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert %{"status" => "ok"} = json_response(conn, 200)

      [p] = Meetings.active_participants(room.id)
      assert p.agent_id == agent.id
    end

    test "resolves a flattened (no nested participant) payload", %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()

      payload = %{
        "event" => "participant_joined",
        "room" => %{"name" => room.livekit_room_name},
        "identity" => "user:#{user.id}",
        "name" => "Ada Lovelace"
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert %{"status" => "ok"} = json_response(conn, 200)

      [p] = Meetings.active_participants(room.id)
      assert p.user_id == user.id
    end

    test "ignores an unknown room name without creating a row", %{conn: conn} do
      payload = %{
        "event" => "participant_joined",
        "room" => %{"name" => "space-#{Ecto.UUID.generate()}"},
        "participant" => %{"identity" => "user:#{Ecto.UUID.generate()}", "name" => "Nobody"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert %{"status" => "ignored", "reason" => "unknown room"} = json_response(conn, 200)
    end
  end

  describe "POST #{@livekit_webhook_path} — participant_left" do
    test "sets left_at on the matching active row", %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      payload = %{
        "event" => "participant_left",
        "room" => %{"name" => room.livekit_room_name},
        "participant" => %{"identity" => "user:#{user.id}", "name" => "Ada Lovelace"}
      }

      conn = post(conn, @livekit_webhook_path, payload)
      assert %{"status" => "ok"} = json_response(conn, 200)

      assert Meetings.active_participants(room.id) == []
    end

    test "tolerates a leave for a participant that was never recorded", %{conn: conn} do
      %{room: room} = seed_room_and_user()

      payload = %{
        "event" => "participant_left",
        "room" => %{"name" => room.livekit_room_name},
        "participant" => %{"identity" => "user:#{Ecto.UUID.generate()}", "name" => "Ghost"}
      }

      conn = post(conn, @livekit_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "participant not found"} =
               json_response(conn, 200)
    end
  end

  defp seed_room_and_user do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Webhook Test Space",
        slug: "webhook-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, room} = Meetings.ensure_room(space.id)

    n = System.unique_integer([:positive])

    {:ok, user} =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        name: "Ada Lovelace",
        email: "ada-#{n}@example.com",
        oidc_sub: "sub-#{n}"
      })
      |> Platform.Repo.insert()

    %{room: room, user: user}
  end

  defp seed_agent do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "summarizer-#{n}",
        name: "Summarizer",
        status: "active"
      })
      |> Platform.Repo.insert()

    agent
  end
end
