defmodule PlatformWeb.LivekitWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Meetings

  @livekit_webhook_path "/api/webhooks/livekit"

  # Legit LiveKit room name — `space-<uuid>` of a real chat_space.
  # Task 019f3312 stage 1 tightened `Meetings.legit_room?/1` from
  # regex-only to regex + chat_spaces existence check, so this fixture
  # materialises a real `chat_spaces` row and returns the matching
  # room name. It also doubles as the persisted `room_id`: stage 1
  # flipped `room_id` precedence to `name || sid`.
  defp unique_room_id, do: app_room_name()

  # Opaque LiveKit-side sid. Under the flipped precedence, `sid` is
  # only used as a fallback for `room_id` when `name` is missing —
  # legitimate payloads always carry `name`, so the sid mostly shows
  # up in logs.
  defp unique_sid, do: "RM_#{System.unique_integer([:positive])}"

  # Materialise a real chat_space and return its LiveKit room name.
  # Single source of truth for the guard-passing fixture.
  defp app_room_name do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Webhook Space #{System.unique_integer([:positive])}",
        slug: "webhook-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    "space-#{space.id}"
  end

  # Payload helpers now take `name` first (since it's both the room
  # identifier AND the guard input) and default `sid` to a synthetic
  # `RM_<n>`. The old `(room_id, room_name \\ nil)` shape assumed
  # `sid || name` precedence — flipped now.
  defp room_started_payload(name, sid \\ nil) do
    %{
      "event" => "room_started",
      "room" => %{
        "sid" => sid || unique_sid(),
        "name" => name
      }
    }
  end

  defp room_finished_payload(name, sid \\ nil) do
    %{
      "event" => "room_finished",
      "room" => %{
        "sid" => sid || unique_sid(),
        "name" => name
      }
    }
  end

  defp transcription_payload(name, segments, sid \\ nil) do
    %{
      "event" => "transcription",
      "room" => %{
        "sid" => sid || unique_sid(),
        "name" => name
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

    # ── task 019ff6f3 stage 3 ──
    test "a populated row still broadcasts meeting_finished", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-1",
          "text" => "We shipped it.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      :ok = Meetings.PubSub.subscribe_meeting_finished(room_id)

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))
      assert %{"status" => "finalized"} = json_response(conn, 200)

      # The suppression guard must not swallow the normal case. Without
      # this control, a guard that suppressed EVERY broadcast would pass
      # the selection test below unnoticed.
      assert_receive {:meeting_finished, %{transcript_id: _}}, 1_000
    end

    test "a room holding content elsewhere hands the POPULATED row to the summary path", %{
      conn: conn
    } do
      # The empty row is inserted MOST RECENTLY — the shape that a
      # `desc: inserted_at` lookup gets wrong. Stage 2's selector is what
      # keeps the empty row away from the summary dispatch here; the
      # controller's own zero-segment guard is belt-and-braces behind it
      # and does not fire on this path.
      room_id = unique_room_id()
      {:ok, populated} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(populated.id, %{
          "participant_identity" => "user-1",
          "text" => "Real conversation.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      {:ok, empty} = Meetings.create_transcript(%{room_id: room_id, segments: []})

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))

      populated_id = populated.id

      assert %{"transcript_id" => ^populated_id, "segment_count" => 1} =
               json_response(conn, 200),
             "the newest row (#{empty.id}) is empty and the room holds content on " <>
               "#{populated.id} — dispatching the empty row publishes a claim about the " <>
               "whole room that the populated row contradicts"

      # And the empty row was left alone — no invented summary.
      assert is_nil(Meetings.get_transcript(empty.id).summary)
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

    test "persists room_id off name (not sid) — task 019f3312 precedence flip",
         %{conn: conn} do
      # Locks in stage 1's `name || sid` precedence change. Prior to
      # this stage the persisted `room_id` was `sid || name`, so
      # transcripts keyed off the ephemeral LiveKit sid instead of the
      # stable app-controlled name. The flip means `get_transcript_for_room/1`
      # lookups work against the room name, matching the rest of the
      # codebase (Meetings.get_room_by_name etc.).
      name = unique_room_id()
      sid = "RM_side_channel_#{System.unique_integer([:positive])}"

      conn = post(conn, @livekit_webhook_path, room_started_payload(name, sid))

      assert %{"status" => "created", "transcript_id" => transcript_id} =
               json_response(conn, 201)

      transcript = Meetings.get_transcript(transcript_id)
      # room_id is the NAME, not the sid.
      assert transcript.room_id == name
      refute transcript.room_id == sid
    end

    test "rejects a well-formed name whose chat_space does not exist (bug 2 fix)",
         %{conn: conn} do
      # The regex-only guard accepted these — the attacker's phantom
      # flood was hitting the webhook with well-formed `space-<uuid>`
      # names that satisfied the regex but pointed at UUIDs no Suite
      # space had ever registered. The tightened `legit_room?/1` guard
      # requires the space to actually exist.
      fake_uuid = Ecto.UUID.generate()
      fake_name = "space-#{fake_uuid}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          payload = %{
            "event" => "room_started",
            "room" => %{"sid" => "RM_attacker", "name" => fake_name}
          }

          conn = post(conn, @livekit_webhook_path, payload)

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(conn, 200)
        end)

      assert log =~ "Ignoring room_started for unregistered room"

      # No transcript was created — the guard fired before any DB write.
      assert Meetings.get_transcript_for_room(fake_name) == nil
      assert Meetings.get_transcript_for_room("RM_attacker") == nil
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

      # Task 019ff6f3 stage 2: the room-wide lookup DOES return a row in
      # `processing`, so the absorb happens on status rather than on the
      # lookup coming back nil — same outcome (no re-finalize, no second
      # summary dispatch), different reason string.
      assert %{"status" => "ignored", "reason" => "transcript already finalized"} =
               json_response(conn, 200)
    end

    # ── task 019ff6f3 stage 3 ──
    test "a populated row still broadcasts meeting_finished", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-1",
          "text" => "We shipped it.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      :ok = Meetings.PubSub.subscribe_meeting_finished(room_id)

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))
      assert %{"status" => "finalized"} = json_response(conn, 200)

      # The suppression guard must not swallow the normal case. Without
      # this control, a guard that suppressed EVERY broadcast would pass
      # the selection test below unnoticed.
      assert_receive {:meeting_finished, %{transcript_id: _}}, 1_000
    end

    test "a room holding content elsewhere hands the POPULATED row to the summary path", %{
      conn: conn
    } do
      # The empty row is inserted MOST RECENTLY — the shape that a
      # `desc: inserted_at` lookup gets wrong. Stage 2's selector is what
      # keeps the empty row away from the summary dispatch here; the
      # controller's own zero-segment guard is belt-and-braces behind it
      # and does not fire on this path.
      room_id = unique_room_id()
      {:ok, populated} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(populated.id, %{
          "participant_identity" => "user-1",
          "text" => "Real conversation.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      {:ok, empty} = Meetings.create_transcript(%{room_id: room_id, segments: []})

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))

      populated_id = populated.id

      assert %{"transcript_id" => ^populated_id, "segment_count" => 1} =
               json_response(conn, 200),
             "the newest row (#{empty.id}) is empty and the room holds content on " <>
               "#{populated.id} — dispatching the empty row publishes a claim about the " <>
               "whole room that the populated row contradicts"

      # And the empty row was left alone — no invented summary.
      assert is_nil(Meetings.get_transcript(empty.id).summary)
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

    # Task 01a1694a stage 2: conclusion delivers the meeting briefing — ONE
    # briefing row and ONE Inbox row per attendee — and a replayed
    # room_finished (LiveKit retries webhooks) adds nothing.
    test "room_finished defers briefing until deadline, and replay adds nothing", %{conn: conn} do
      import Ecto.Query, only: [from: 2]

      {:ok, project} = Platform.Tasks.create_project(%{name: "Webhook Brief #{unique_room_id()}"})

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Brief Me #{unique_room_id()}"})

      {:ok, live} = Meetings.start_meeting(meeting)

      live =
        live
        |> Ecto.Changeset.change(started_at: DateTime.add(DateTime.utc_now(), -3600))
        |> Platform.Repo.update!()

      n = System.unique_integer([:positive])

      attendee =
        Platform.Repo.insert!(%Platform.Accounts.User{
          name: "Webhook Attendee #{n}",
          email: "webhook-attendee-#{n}@example.com",
          oidc_sub: "oidc-webhook-attendee-#{n}"
        })

      room =
        Platform.Repo.insert!(%Meetings.Room{
          space_id: live.chat_space_id,
          livekit_room_name: "space-#{live.chat_space_id}"
        })

      Platform.Repo.insert!(%Meetings.Participant{
        room_id: room.id,
        user_id: attendee.id,
        display_name: "Attendee",
        joined_at: DateTime.add(live.started_at, 60, :second)
      })

      payload = %{
        "event" => "room_finished",
        "room" => %{"sid" => unique_sid(), "name" => "space-#{live.chat_space_id}"}
      }

      assert json_response(post(conn, @livekit_webhook_path, payload), 200)
      assert json_response(post(build_conn(), @livekit_webhook_path, payload), 200)

      ended = Meetings.get_meeting(live.id)
      assert ended.status == "ended"

      assert Platform.Repo.all(
               from(b in Platform.Meetings.MeetingBriefing, where: b.meeting_id == ^live.id)
             ) == []

      assert Platform.Repo.all(
               from(i in Platform.Inbox.Item,
                 where: i.user_id == ^attendee.id and i.kind == "meeting_briefing"
               )
             ) == []

      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Platform.Repo.update!()

      Meetings.Completion.sweep()
      assert json_response(post(build_conn(), @livekit_webhook_path, payload), 200)
      Meetings.Completion.sweep()

      briefings =
        Platform.Repo.all(
          from(b in Platform.Meetings.MeetingBriefing, where: b.meeting_id == ^live.id)
        )

      assert [%{attendee_user_ids: [attendee_id]} = briefing] = briefings
      assert attendee_id == attendee.id

      assert [_one] =
               Platform.Repo.all(
                 from(i in Platform.Inbox.Item,
                   where:
                     i.user_id == ^attendee.id and i.kind == "meeting_briefing" and
                       i.source_id == ^briefing.id
                 )
               )
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
      # Simulate a historical phantom transcript created before this
      # task landed — a row keyed off the RM_<random> name because the
      # old `sid || name` precedence stored the sid (which was itself
      # RM_<random> for these phantoms). The tightened guard blocks
      # new ones; the sweep here cleans up the historical row.
      phantom_name = "RM_phantom_abc123"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: phantom_name})
      transcript_id = transcript.id

      payload = room_finished_payload(phantom_name)
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
      room_name = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_name})
      transcript_id = transcript.id

      # `unique_room_id/0` emits `space-<uuid>` backed by a real
      # chat_space — passes the tightened `legit_room?/1` guard.
      payload = room_finished_payload(room_name)
      conn = post(conn, @livekit_webhook_path, payload)

      assert %{
               "status" => "finalized",
               "transcript_status" => "complete",
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
      # the transcription guard drops segments for unregistered rooms,
      # so this branch is only reachable if something bypassed the
      # guard OR the sweep runs against a historical row. Finalize
      # instead of delete — segments are user data.
      phantom_name = "RM_leaked_xyz789"
      {:ok, transcript} = Meetings.create_transcript(%{room_id: phantom_name})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-legacy",
          "text" => "leaked segment",
          "start_time" => 1000,
          "end_time" => 2000
        })

      payload = room_finished_payload(phantom_name)
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
      # `room_id` under the flipped `name || sid` precedence is the
      # room `name`. `unique_room_id/0` returns a legit `space-<uuid>`
      # backed by a real chat_space, so the guard passes.
      room_name = unique_room_id()
      sid = unique_sid()

      first_conn = post(conn, @livekit_webhook_path, room_started_payload(room_name, sid))

      assert %{"status" => "created", "transcript_id" => first_id} =
               json_response(first_conn, 201)

      second_conn = post(conn, @livekit_webhook_path, room_started_payload(room_name, sid))

      assert %{"status" => "created", "transcript_id" => second_id} =
               json_response(second_conn, 201)

      # ensure_transcript returns the existing row on the second call.
      assert first_id == second_id
      assert count_transcripts_for_room(room_name) == 1
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
      # A second `room_finished` finds the row via the room-wide lookup
      # (task 019ff6f3 stage 2) and absorbs it on its terminal status,
      # without touching the completed row or crashing.
      room_name = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_name})
      transcript_id = transcript.id

      first_conn = post(conn, @livekit_webhook_path, room_finished_payload(room_name))

      assert %{
               "status" => "finalized",
               "transcript_id" => ^transcript_id,
               "segment_count" => 0
             } = json_response(first_conn, 200)

      after_first = Meetings.get_transcript(transcript_id)
      assert after_first.status == "complete"

      second_conn = post(conn, @livekit_webhook_path, room_finished_payload(room_name))

      assert %{"status" => "ignored", "reason" => "transcript already finalized"} =
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
    test "source segment IDs survive normalization so delivery replay does not append twice", %{
      conn: conn
    } do
      room_name = app_room_name()
      input = sample_segment(%{"id" => "source-segment-one"})
      payload = transcription_payload(room_name, [input])
      response = conn |> post(@livekit_webhook_path, payload) |> json_response(200)
      transcript_id = response["transcript_id"]
      assert [%{"id" => "source-segment-one"}] = Meetings.get_transcript(transcript_id).segments
      conn |> recycle() |> post(@livekit_webhook_path, payload) |> json_response(200)
      assert length(Meetings.get_transcript(transcript_id).segments) == 1

      conn
      |> recycle()
      |> post(
        @livekit_webhook_path,
        transcription_payload(room_name, [Map.put(input, "text", "Final corrected speech")])
      )
      |> json_response(200)

      assert [%{"id" => "source-segment-one", "text" => "Final corrected speech"}] =
               Meetings.get_transcript(transcript_id).segments

      conn
      |> recycle()
      |> post(
        @livekit_webhook_path,
        transcription_payload(room_name, [Map.put(input, "id", "source-segment-two")])
      )
      |> json_response(200)

      assert length(Meetings.get_transcript(transcript_id).segments) == 2
    end

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

    # ── task 019ff6f3 stage 3 ──
    test "a populated row still broadcasts meeting_finished", %{conn: conn} do
      room_id = unique_room_id()
      {:ok, transcript} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(transcript.id, %{
          "participant_identity" => "user-1",
          "text" => "We shipped it.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      :ok = Meetings.PubSub.subscribe_meeting_finished(room_id)

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))
      assert %{"status" => "finalized"} = json_response(conn, 200)

      # The suppression guard must not swallow the normal case. Without
      # this control, a guard that suppressed EVERY broadcast would pass
      # the selection test below unnoticed.
      assert_receive {:meeting_finished, %{transcript_id: _}}, 1_000
    end

    test "a room holding content elsewhere hands the POPULATED row to the summary path", %{
      conn: conn
    } do
      # The empty row is inserted MOST RECENTLY — the shape that a
      # `desc: inserted_at` lookup gets wrong. Stage 2's selector is what
      # keeps the empty row away from the summary dispatch here; the
      # controller's own zero-segment guard is belt-and-braces behind it
      # and does not fire on this path.
      room_id = unique_room_id()
      {:ok, populated} = Meetings.create_transcript(%{room_id: room_id})

      {:ok, _} =
        Meetings.append_segment(populated.id, %{
          "participant_identity" => "user-1",
          "text" => "Real conversation.",
          "start_time" => 1000,
          "end_time" => 2000
        })

      {:ok, empty} = Meetings.create_transcript(%{room_id: room_id, segments: []})

      conn = post(conn, @livekit_webhook_path, room_finished_payload(room_id))

      populated_id = populated.id

      assert %{"transcript_id" => ^populated_id, "segment_count" => 1} =
               json_response(conn, 200),
             "the newest row (#{empty.id}) is empty and the room holds content on " <>
               "#{populated.id} — dispatching the empty row publishes a claim about the " <>
               "whole room that the populated row contradicts"

      # And the empty row was left alone — no invented summary.
      assert is_nil(Meetings.get_transcript(empty.id).summary)
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

  # ── companion connections (task 01a13ca2 stage 1) ───────────────────────
  #
  # The iOS app's video-only second connection joins as `video:user:<uuid>`.
  # Its join and leave must write nothing and broadcast nothing; every join
  # side effect (attendance, agent-visible roster, `{:participant_joined, _}`)
  # sits downstream of the roster row, so no row means none of them fire.

  defp participant_payload(event, room, identity, name) do
    %{
      "event" => event,
      "room" => %{"name" => room.livekit_room_name},
      "participant" => %{"identity" => identity, "name" => name, "sid" => "PA_companion"}
    }
  end

  defp row_count, do: Platform.Repo.aggregate(Platform.Meetings.Participant, :count)

  describe "POST #{@livekit_webhook_path} — companion participant" do
    test "a companion join and leave are ignored; the same user: join DOES create a row",
         %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()
      :ok = Platform.Meetings.PubSub.subscribe_room(room.id)
      before = row_count()

      for event <- ["participant_joined", "participant_left"] do
        resp =
          conn
          |> post(
            @livekit_webhook_path,
            participant_payload(event, room, "video:user:#{user.id}", "Ada Lovelace")
          )
          |> json_response(200)

        assert resp == %{"status" => "ignored", "reason" => "companion"}
        assert row_count() == before
      end

      assert Meetings.active_participants(room.id) == []
      refute_receive {:participant_joined, _}, 100
      refute_receive {:participant_left, _}, 50

      # Positive control: the identical payload for the person's own
      # connection creates the row and broadcasts, so the rig can see both.
      resp =
        conn
        |> post(
          @livekit_webhook_path,
          participant_payload("participant_joined", room, "user:#{user.id}", "Ada Lovelace")
        )
        |> json_response(200)

      assert %{"status" => "ok"} = resp
      assert row_count() == before + 1
      assert_receive {:participant_joined, %{user_id: user_id}}, 500
      assert user_id == user.id
    end

    test "a companion leaving keeps the person's active row active", %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()

      {:ok, row} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      resp =
        conn
        |> post(
          @livekit_webhook_path,
          participant_payload("participant_left", room, "video:user:#{user.id}", "Ada Lovelace")
        )
        |> json_response(200)

      assert resp == %{"status" => "ignored", "reason" => "companion"}
      assert Platform.Repo.get!(Platform.Meetings.Participant, row.id).left_at == nil
    end

    test "the roster read paths list the person once while a companion has joined",
         %{conn: conn} do
      %{room: room, user: user} = seed_room_and_user()
      {:ok, room} = Meetings.activate_room(room)

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      conn
      |> post(
        @livekit_webhook_path,
        participant_payload("participant_joined", room, "video:user:#{user.id}", "Ada Lovelace")
      )
      |> json_response(200)

      # `active_participants/1` is what IntentContext and IntentClassifier
      # read for the addressee gate; `active_participants_for_space/1` is
      # attendance, the notifier and the MCP seat guard.
      assert [%{user_id: uid}] = Meetings.active_participants(room.id)
      assert uid == user.id
      assert [%{user_id: ^uid}] = Meetings.active_participants_for_space(room.space_id)
    end

    test "the context writers refuse a companion identity themselves" do
      %{room: room, user: user} = seed_room_and_user()

      {:ok, row} =
        Meetings.upsert_live_participant(room, %{
          identity: "user:#{user.id}",
          name: "Ada Lovelace"
        })

      before = row_count()

      assert {:error, :companion_identity} =
               Meetings.upsert_live_participant(room, %{
                 identity: "video:user:#{user.id}",
                 name: "Ada Lovelace"
               })

      # Without the refusal the leave would match the person's row by
      # display name and end it.
      assert {:error, :companion_identity} =
               Meetings.mark_live_participant_left(room, %{
                 identity: "video:user:#{user.id}",
                 name: "Ada Lovelace"
               })

      assert row_count() == before
      assert Platform.Repo.get!(Platform.Meetings.Participant, row.id).left_at == nil
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

  # ── shadow-row selection + rejoin reattachment (task 019ff6f3 stage 2) ──

  describe "POST #{@livekit_webhook_path} — shadowed room (populated + empty row)" do
    test "room_finished finalizes the POPULATED row when the EMPTY row is newest",
         %{conn: conn} do
      # The load-bearing fixture. Under the old `desc: inserted_at` +
      # `status == "recording"` lookup, the newest (empty) row is what
      # got finalized and summarised — which is how a meeting with a full
      # transcript produced prose saying no transcript arrived.
      {room_name, populated, empty} = shadowed_room()
      populated_id = populated.id

      assert %{
               "status" => "finalized",
               "transcript_id" => ^populated_id,
               "segment_count" => 5
             } =
               conn
               |> post(@livekit_webhook_path, room_finished_payload(room_name))
               |> json_response(200)

      selected = Meetings.get_transcript(populated_id)

      assert selected.status in ["processing", "complete", "failed"],
             "populated row #{populated_id} never left recording (status=#{selected.status})"

      # The shadow row is neither finalized nor summarised.
      shadow = Meetings.get_transcript(empty.id)
      assert shadow.status == "recording"
      assert shadow.summary == nil
      assert shadow.segments == []
      assert count_transcripts_for_room(room_name) == 2
    end

    test "direction control: same populated row is selected when it is NEWEST",
         %{conn: conn} do
      # If this passed and the test above failed, the selection is keyed on
      # recency rather than content and the pair cannot detect the bug.
      room_name = app_room_name()
      base = ~U[2026-02-02 09:00:00.000000Z]

      empty = transcript_at(room_name, 0, base)
      populated = transcript_at(room_name, 5, DateTime.add(base, 600, :second))
      populated_id = populated.id

      assert %{"status" => "finalized", "transcript_id" => ^populated_id, "segment_count" => 5} =
               conn
               |> post(@livekit_webhook_path, room_finished_payload(room_name))
               |> json_response(200)

      assert Meetings.get_transcript(empty.id).status == "recording"
      assert Meetings.get_transcript(empty.id).summary == nil
    end

    test "room_started reattaches to a populated row without reopening capture or creating a shadow",
         %{conn: conn} do
      # Room activation alone is not new capture. Keep the reusable row's
      # terminal state; actual transcription below still reopens it.
      room_name = app_room_name()
      existing = transcript_at(room_name, 4, ~U[2026-02-02 09:00:00.000000Z], "failed")
      existing_id = existing.id

      assert %{"status" => "created", "transcript_id" => ^existing_id} =
               conn
               |> post(@livekit_webhook_path, room_started_payload(room_name))
               |> json_response(201)

      assert length(Meetings.list_transcripts_for_room(room_name)) == 1
      assert Meetings.get_transcript(existing_id).status == "failed"
      assert Meetings.get_transcript(existing_id).summary_epoch == existing.summary_epoch
    end

    test "transcription after a rejoin appends to the existing row, not a shadow",
         %{conn: conn} do
      room_name = app_room_name()
      existing = transcript_at(room_name, 4, ~U[2026-02-02 09:00:00.000000Z], "failed")

      conn
      |> post(
        @livekit_webhook_path,
        transcription_payload(room_name, [sample_segment(%{"text" => "Rejoined and speaking."})])
      )
      |> json_response(200)

      assert length(Meetings.list_transcripts_for_room(room_name)) == 1
      assert length(Meetings.get_transcript(existing.id).segments) == 5
    end

    # Task 01a0de8f. Pins ROUTING only: a `failed` populated row is NOT
    # absorbed by room_finished, so the real entry point reaches
    # `Meetings.finalize_transcript/1` (where the failure_reason clear lives).
    # It deliberately asserts nothing about `failure_reason`: the async
    # summarizer started by `maybe_trigger_summary/1` can rewrite that column
    # and race any assertion. The clear itself is pinned in
    # `Platform.MeetingsTest` against `finalize_transcript/1` directly.
    test "room_finished re-runs a FAILED populated row through finalize (task 01a0de8f)",
         %{conn: conn} do
      room_name = app_room_name()
      existing = transcript_at(room_name, 4, ~U[2026-02-02 09:00:00.000000Z])

      {:ok, failed} =
        Meetings.fail_transcript(existing.id, nil, {:llm_failed, :planted_01a0de8f})

      assert failed.status == "failed"
      existing_id = existing.id

      assert %{"status" => "finalized", "transcript_id" => ^existing_id, "segment_count" => 4} =
               conn
               |> post(@livekit_webhook_path, room_finished_payload(room_name))
               |> json_response(200)

      assert length(Meetings.list_transcripts_for_room(room_name)) == 1
    end
  end

  # Two rows for one room: populated first, EMPTY row inserted strictly
  # later, with explicit timestamps rather than clock resolution.
  defp shadowed_room do
    room_name = app_room_name()
    base = ~U[2026-02-02 09:00:00.000000Z]

    populated = transcript_at(room_name, 5, base)
    empty = transcript_at(room_name, 0, DateTime.add(base, 600, :second))

    {room_name, populated, empty}
  end

  defp transcript_at(room_id, segment_count, inserted_at, status \\ "recording") do
    import Ecto.Query, only: [from: 2]

    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: room_id,
        status: status,
        segments: invented_segments(segment_count)
      })

    {1, nil} =
      Platform.Repo.update_all(
        from(t in Platform.Meetings.Transcript, where: t.id == ^transcript.id),
        set: [inserted_at: inserted_at]
      )

    Meetings.get_transcript(transcript.id)
  end

  defp invented_segments(0), do: []

  defp invented_segments(n) do
    for i <- 1..n do
      %{
        "participant_identity" => "user-#{i}",
        "speaker_name" => "Speaker #{i}",
        "text" => "Invented line #{i} of an invented meeting.",
        "start_time" => i * 1000,
        "end_time" => i * 1000 + 500,
        "language" => "en",
        "final" => true
      }
    end
  end
end
