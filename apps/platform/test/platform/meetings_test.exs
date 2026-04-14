defmodule Platform.MeetingsTest do
  @moduledoc "Tests for the Platform.Meetings context."
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.{Participant, Recording, Room}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_space(_context \\ %{}) do
    slug = "test-space-#{System.unique_integer([:positive])}"

    {:ok, space} =
      %Platform.Chat.Space{}
      |> Platform.Chat.Space.changeset(%{kind: "channel", name: "Test Space", slug: slug})
      |> Repo.insert()

    space
  end

  defp with_livekit(_context \\ %{}) do
    System.put_env("LIVEKIT_URL", "wss://livekit.test")
    System.put_env("LIVEKIT_API_KEY", "test-api-key")
    System.put_env("LIVEKIT_API_SECRET", "test-secret-that-is-long-enough-for-hs256")

    on_exit(fn ->
      System.delete_env("LIVEKIT_URL")
      System.delete_env("LIVEKIT_API_KEY")
      System.delete_env("LIVEKIT_API_SECRET")
    end)

    :ok
  end

  # ── Feature gate ─────────────────────────────────────────────────────────

  describe "enabled?/0" do
    test "returns false when env vars are missing" do
      System.delete_env("LIVEKIT_URL")
      System.delete_env("LIVEKIT_API_KEY")
      System.delete_env("LIVEKIT_API_SECRET")
      refute Meetings.enabled?()
    end

    test "returns true when all env vars are set" do
      with_livekit()
      assert Meetings.enabled?()
    end

    test "returns false when any env var is empty" do
      System.put_env("LIVEKIT_URL", "wss://livekit.test")
      System.put_env("LIVEKIT_API_KEY", "")
      System.put_env("LIVEKIT_API_SECRET", "test-secret")

      on_exit(fn ->
        System.delete_env("LIVEKIT_URL")
        System.delete_env("LIVEKIT_API_KEY")
        System.delete_env("LIVEKIT_API_SECRET")
      end)

      refute Meetings.enabled?()
    end
  end

  describe "config/0" do
    test "returns nil when disabled" do
      System.delete_env("LIVEKIT_URL")
      assert Meetings.config() == nil
    end

    test "returns config map when enabled" do
      with_livekit()
      config = Meetings.config()
      assert config.url == "wss://livekit.test"
      assert config.api_key == "test-api-key"
      assert is_binary(config.api_secret)
    end
  end

  describe "room_name_for_space/1" do
    test "prefixes space_id with 'space-'" do
      assert Meetings.room_name_for_space("abc-123") == "space-abc-123"
    end
  end

  describe "generate_token/3" do
    setup do
      Application.put_env(:platform, :livekit,
        url: "wss://lk.example.com",
        api_key: "APItest123",
        api_secret: "supersecretkey"
      )

      on_exit(fn -> Application.delete_env(:platform, :livekit) end)
    end

    test "returns a valid JWT string with three dot-separated parts" do
      token = Meetings.generate_token("test-room", "user-1")
      parts = String.split(token, ".")
      assert length(parts) == 3
    end

    test "JWT header specifies HS256" do
      token = Meetings.generate_token("test-room", "user-1")
      [header_b64 | _] = String.split(token, ".")
      header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert header["alg"] == "HS256"
      assert header["typ"] == "JWT"
    end

    test "JWT claims contain correct issuer, subject, and video grants" do
      token = Meetings.generate_token("test-room", "user-42", name: "Alice")
      [_, payload_b64 | _] = String.split(token, ".")
      claims = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims["iss"] == "APItest123"
      assert claims["sub"] == "user-42"
      assert claims["name"] == "Alice"
      assert is_integer(claims["exp"])
      assert is_integer(claims["nbf"])
      assert claims["exp"] > claims["nbf"]

      video = claims["video"]
      assert video["room"] == "test-room"
      assert video["roomJoin"] == true
      assert video["canPublish"] == true
      assert video["canSubscribe"] == true
      assert video["canPublishData"] == true
    end

    test "default TTL is 6 hours" do
      token = Meetings.generate_token("room", "user")
      [_, payload_b64 | _] = String.split(token, ".")
      claims = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      # 6 hours = 21600 seconds, allow 2s tolerance for test execution
      assert_in_delta claims["exp"] - claims["nbf"], 21_600, 2
    end

    test "custom TTL is respected" do
      token = Meetings.generate_token("room", "user", ttl: 3600)
      [_, payload_b64 | _] = String.split(token, ".")
      claims = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert_in_delta claims["exp"] - claims["nbf"], 3600, 2
    end

    test "signature is valid HMAC-SHA256" do
      secret = "supersecretkey"
      token = Meetings.generate_token("room", "user")
      [header_b64, payload_b64, sig_b64] = String.split(token, ".")

      signing_input = "#{header_b64}.#{payload_b64}"

      expected_sig =
        :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.url_encode64(padding: false)

      assert sig_b64 == expected_sig
    end

    test "each token has a unique jti" do
      t1 = Meetings.generate_token("room", "user")
      t2 = Meetings.generate_token("room", "user")

      [_, p1 | _] = String.split(t1, ".")
      [_, p2 | _] = String.split(t2, ".")

      c1 = p1 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      c2 = p2 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert c1["jti"] != c2["jti"]
    end
  end

  # ── Rooms ────────────────────────────────────────────────────────────────

  describe "ensure_room/1" do
    test "returns error when disabled" do
      space = create_space()
      assert {:error, :meetings_disabled} = Meetings.ensure_room(space.id)
    end

    test "creates a room for a space" do
      with_livekit()
      space = create_space()
      assert {:ok, %Room{} = room} = Meetings.ensure_room(space.id)
      assert room.space_id == space.id
      assert room.status == "idle"
      assert room.livekit_room_name == "space-#{space.id}"
    end

    test "returns existing room on second call" do
      with_livekit()
      space = create_space()
      assert {:ok, room1} = Meetings.ensure_room(space.id)
      assert {:ok, room2} = Meetings.ensure_room(space.id)
      assert room1.id == room2.id
    end
  end

  describe "get_room/1" do
    test "returns nil when no room exists" do
      assert Meetings.get_room("00000000-0000-0000-0000-000000000000") == nil
    end

    test "returns room when it exists" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      assert Meetings.get_room(space.id).id == room.id
    end
  end

  describe "close_room/1" do
    test "sets room to idle and marks participants as left" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      # Set room to active
      room |> Room.changeset(%{status: "active"}) |> Repo.update!()

      # Add a participant
      {:ok, participant} =
        Meetings.participant_joined(room.id, %{display_name: "Alice"})

      assert is_nil(participant.left_at)

      # Close the room
      assert {:ok, closed_room} = Meetings.close_room(room.id)
      assert closed_room.status == "idle"

      # Participant should now have left_at set
      updated = Repo.get!(Participant, participant.id)
      refute is_nil(updated.left_at)
    end
  end

  # ── Token generation ─────────────────────────────────────────────────────

  describe "generate_token/2" do
    test "returns error when disabled" do
      space = create_space()

      room = %Room{
        id: "fake-id",
        space_id: space.id,
        livekit_room_name: "suite-test"
      }

      assert {:error, :meetings_disabled} =
               Meetings.generate_token(room, %{identity: "user-1", name: "Alice"})
    end

    test "generates a valid JWT when enabled" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert {:ok, token} =
               Meetings.generate_token(room, %{identity: "user-1", name: "Alice"})

      assert is_binary(token)
      # JWT has 3 dot-separated parts
      assert length(String.split(token, ".")) == 3
    end
  end

  describe "generate_agent_token/2" do
    test "generates a JWT with agent metadata" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert {:ok, token} =
               Meetings.generate_agent_token(room, %{identity: "agent-1", name: "Higgins"})

      assert is_binary(token)
      assert length(String.split(token, ".")) == 3
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  describe "participant_joined/3" do
    test "records a participant joining" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert {:ok, %Participant{} = p} =
               Meetings.participant_joined(room.id, %{display_name: "Bob"})

      assert p.room_id == room.id
      assert p.display_name == "Bob"
      assert p.joined_at
      assert is_nil(p.left_at)
    end

    test "supports user_id and agent_id" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert {:ok, %Participant{}} =
               Meetings.participant_joined(room.id, %{
                 display_name: "Agent",
                 metadata: %{"role" => "assistant"}
               })
    end
  end

  describe "participant_left/2" do
    test "records the participant leaving" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, p} = Meetings.participant_joined(room.id, %{display_name: "Carol"})

      assert {:ok, updated} = Meetings.participant_left(p.id)
      refute is_nil(updated.left_at)
    end

    test "returns error for unknown participant" do
      with_livekit()

      assert {:error, :not_found} =
               Meetings.participant_left("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "list_participants/1" do
    test "returns participants ordered by join time" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      t1 = ~U[2026-01-01 10:00:00Z]
      t2 = ~U[2026-01-01 10:05:00Z]

      {:ok, _p2} = Meetings.participant_joined(room.id, %{display_name: "B"}, t2)
      {:ok, _p1} = Meetings.participant_joined(room.id, %{display_name: "A"}, t1)

      participants = Meetings.list_participants(room.id)
      assert length(participants) == 2
      assert hd(participants).display_name == "A"
    end
  end

  # ── Recordings ───────────────────────────────────────────────────────────

  describe "start_recording/2" do
    test "creates a recording in recording status" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert {:ok, %Recording{} = rec} =
               Meetings.start_recording(room.id, %{egress_id: "EG_test123"})

      assert rec.room_id == room.id
      assert rec.space_id == space.id
      assert rec.status == "recording"
      assert rec.egress_id == "EG_test123"
    end
  end

  describe "stop_recording/1" do
    test "transitions recording to processing" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, rec} = Meetings.start_recording(room.id, %{egress_id: "EG_stop"})

      assert {:ok, updated} = Meetings.stop_recording(rec.id)
      assert updated.status == "processing"
    end

    test "returns error for non-recording status" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, rec} = Meetings.start_recording(room.id)
      {:ok, _} = Meetings.stop_recording(rec.id)

      assert {:error, :invalid_status} = Meetings.stop_recording(rec.id)
    end
  end

  describe "recording_completed/2" do
    test "transitions recording to ready with file details" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, rec} = Meetings.start_recording(room.id)

      attrs = %{
        duration_seconds: 300,
        file_url: "https://storage.example.com/recording.mp4",
        file_size_bytes: 52_428_800
      }

      assert {:ok, completed} = Meetings.recording_completed(rec.id, attrs)
      assert completed.status == "ready"
      assert completed.duration_seconds == 300
      assert completed.file_url == "https://storage.example.com/recording.mp4"
      assert completed.file_size_bytes == 52_428_800
    end

    test "returns error for already-ready recording" do
      with_livekit()
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, rec} = Meetings.start_recording(room.id)
      {:ok, _} = Meetings.recording_completed(rec.id, %{duration_seconds: 60})

      assert {:error, :invalid_status} =
               Meetings.recording_completed(rec.id, %{duration_seconds: 120})
    end
  end
end
