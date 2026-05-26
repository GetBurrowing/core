defmodule PlatformWeb.LivekitWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Meetings

  @livekit_webhook_path "/api/webhooks/livekit"

  defp unique_room_id, do: Platform.Types.UUIDv7.generate()

  defp room_started_payload(room_id) do
    %{
      "event" => "room_started",
      "room" => %{
        "sid" => room_id,
        "name" => "meeting-#{room_id}"
      }
    }
  end

  defp room_finished_payload(room_id) do
    %{
      "event" => "room_finished",
      "room" => %{
        "sid" => room_id,
        "name" => "meeting-#{room_id}"
      }
    }
  end

  defp transcription_payload(room_id, segments) do
    %{
      "event" => "transcription",
      "room" => %{
        "sid" => room_id,
        "name" => "meeting-#{room_id}"
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

      assert %{"status" => "ignored", "reason" => "no room identifier"} =
               json_response(conn, 200)
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

      assert %{"status" => "ignored"} = json_response(conn, 200)
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
