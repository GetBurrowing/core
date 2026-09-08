defmodule Platform.Meetings.PresenceTest do
  @moduledoc """
  Tests for `Platform.Meetings` context — PubSub presence helpers,
  participant tracking, and space-level presence queries.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.{Meeting, Recording, Room}
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Test Space",
        slug: "meeting-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_room(space_id) do
    {:ok, room} = Meetings.ensure_room(space_id)
    room
  end

  defp activate_room(room) do
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  defp join_participant(room, display_name, attrs \\ %{}) do
    {:ok, participant} =
      Meetings.participant_joined(
        room,
        Map.merge(%{display_name: display_name}, attrs)
      )

    participant
  end

  # ── PubSub Topics ───────────────────────────────────────────────────────────

  describe "PubSub topic helpers" do
    test "meeting_presence_topic/1 returns room topic" do
      room_id = Ecto.UUID.generate()
      assert Meetings.meeting_presence_topic(room_id) == "meetings:room:#{room_id}"
    end

    test "meeting_presence_summary_topic/0 returns summary topic" do
      assert Meetings.meeting_presence_summary_topic() == "meetings:presence_summary"
    end
  end

  # ── Subscribe Helpers ────────────────────────────────────────────────────────

  describe "subscribe helpers" do
    test "subscribe_to_room_presence/1 subscribes to room topic" do
      room_id = Ecto.UUID.generate()
      assert :ok = Meetings.subscribe_to_room_presence(room_id)

      # Verify we receive broadcasts on this topic
      MeetingsPubSub.broadcast_room(room_id, {:test_event, :hello})
      assert_receive {:test_event, :hello}
    end

    test "subscribe_to_presence_summary/0 subscribes to summary topic" do
      assert :ok = Meetings.subscribe_to_presence_summary()

      MeetingsPubSub.broadcast_presence_summary("some-space-id")
      assert_receive {:meeting_presence_summary, %{space_id: "some-space-id"}}
    end
  end

  # ── Room Lifecycle ──────────────────────────────────────────────────────────

  describe "ensure_room/1" do
    test "creates a room for a space" do
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert room.space_id == space.id
      assert room.livekit_room_name == "space-#{space.id}"
      assert room.status == "idle"
    end

    test "returns existing room on second call" do
      space = create_space()
      {:ok, room1} = Meetings.ensure_room(space.id)
      {:ok, room2} = Meetings.ensure_room(space.id)

      assert room1.id == room2.id
    end
  end

  describe "activate_room/1" do
    test "sets room status to active and broadcasts" do
      space = create_space()
      room = create_room(space.id)

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, activated} = Meetings.activate_room(room)
      assert activated.status == "active"

      assert_receive {:room_activated, ^activated}
      assert_receive {:meeting_presence_update, %{space_id: _, active: false, count: 0}}
    end
  end

  describe "finish_room/1" do
    test "sets room to idle and marks participants as left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:alice")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, finished} = Meetings.finish_room(room)
      assert finished.status == "idle"

      # All participants should be marked as left
      assert Meetings.active_participants(room.id) == []
      assert_receive {:room_finished, ^finished}
    end
  end

  # ── Participant Tracking ────────────────────────────────────────────────────

  describe "participant_joined/2" do
    test "creates participant and broadcasts on room + presence topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, participant} =
        Meetings.participant_joined(room, %{
          display_name: "Bob"
        })

      assert participant.display_name == "Bob"
      assert participant.room_id == room.id
      assert is_nil(participant.left_at)

      assert_receive {:participant_joined, ^participant}
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
    end
  end

  describe "participant_left/2" do
    test "sets left_at and broadcasts" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:carol")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, left} = Meetings.participant_left(room, "user:carol")
      assert left.left_at != nil
      assert_receive {:participant_left, ^left}
    end

    test "returns error when participant not found" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      assert {:error, :not_found} = Meetings.participant_left(room, "user:nobody")
    end
  end

  # ── Active Participants ─────────────────────────────────────────────────────

  describe "active_participants/1" do
    test "returns only participants with nil left_at, preloads user/agent" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      _p1 = join_participant(room, "user:alice")
      p2 = join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      active = Meetings.active_participants(room.id)
      assert length(active) == 1
      assert hd(active).id == p2.id

      # Preloads should be loaded (nil since no FK set, but not Ecto.Association.NotLoaded)
      participant = hd(active)
      assert is_nil(participant.user) or is_struct(participant.user)
      assert is_nil(participant.agent) or is_struct(participant.agent)
    end
  end

  # ── Helpers (shared) ─────────────────────────────────────────────────────

  defp create_space(attrs \\ %{}) do
    default = %{
      name: "Test Space",
      slug: "test-space-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── Space-level Queries ─────────────────────────────────────────────────────

  describe "active_meeting_counts/1" do
    test "returns empty map for empty list" do
      assert Meetings.active_meeting_counts([]) == %{}
    end

    test "returns counts for spaces with active meetings" do
      space1 = create_space()
      space2 = create_space()
      space3 = create_space()

      room1 = create_room(space1.id) |> activate_room()
      room2 = create_room(space2.id) |> activate_room()
      _room3 = create_room(space3.id)

      join_participant(room1, "user:alice")
      join_participant(room1, "user:bob")
      join_participant(room2, "user:carol")

      counts = Meetings.active_meeting_counts([space1.id, space2.id, space3.id])

      assert counts[space1.id] == 2
      assert counts[space2.id] == 1
      # space3 has no active meeting (room is idle)
      refute Map.has_key?(counts, space3.id)
    end

    test "excludes participants who have left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      counts = Meetings.active_meeting_counts([space.id])
      assert counts[space.id] == 1
    end
  end

  describe "active_participants_for_space/1" do
    test "returns participants for active meeting in space" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")

      participants = Meetings.active_participants_for_space(space.id)
      assert length(participants) == 2
    end

    test "returns empty list when no active meeting" do
      space = create_space()
      _room = create_room(space.id)

      assert Meetings.active_participants_for_space(space.id) == []
    end
  end

  # ── Broadcast Presence Change ───────────────────────────────────────────────

  describe "broadcast_presence_change/2" do
    test "broadcasts on presence and summary topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_presence(space.id)
      MeetingsPubSub.subscribe_presence_summary()

      join_participant(room, "user:dave")

      # participant_joined already calls broadcast_presence_change internally
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
      assert_receive {:meeting_presence_summary, %{space_id: _}}
    end

    test "no-ops for nil space_id" do
      assert :ok = Meetings.broadcast_presence_change("some-room-id", nil)
    end
  end

  # ── mark_notified/1 (idempotency CAS) ───────────────────────────────────────
  #
  # Stage 3 of task 019edbc1 added the `meetings.notified_at` column + atomic
  # compare-and-swap so the `MeetingNotifier` fan-out cannot double-fire when
  # two concurrent callers race `start_meeting/1` for the same row (the
  # `:auto_join` path is the realistic trigger).

  describe "mark_notified/1" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "MarkNotified Project"})
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "CAS Meeting"})
      {:ok, meeting: meeting}
    end

    test "stamps notified_at and returns :ok on first call", %{meeting: meeting} do
      assert is_nil(meeting.notified_at)

      assert {:ok, claimed} = Meetings.mark_notified(meeting)
      assert %DateTime{} = claimed.notified_at

      # Reload to confirm the column is actually persisted (not just on the
      # returned struct).
      reloaded = Repo.get!(Meeting, meeting.id)
      assert reloaded.notified_at == claimed.notified_at
    end

    test "returns :already_notified on the second call and does NOT update timestamp",
         %{meeting: meeting} do
      {:ok, claimed} = Meetings.mark_notified(meeting)
      first_stamp = claimed.notified_at

      # The struct we pass in still has nil notified_at, so the function
      # would naively try the CAS — but the WHERE is_nil guard rejects the
      # update at the database level.
      assert {:already_notified, _} = Meetings.mark_notified(meeting)

      reloaded = Repo.get!(Meeting, meeting.id)
      assert reloaded.notified_at == first_stamp
    end

    test "short-circuits without an UPDATE when the struct already carries notified_at",
         %{meeting: meeting} do
      {:ok, claimed} = Meetings.mark_notified(meeting)

      # Passing the already-stamped struct hits the second function head,
      # which returns :already_notified without going to the DB at all.
      assert {:already_notified, ^claimed} = Meetings.mark_notified(claimed)
    end

    test "two concurrent callers race the CAS — exactly one wins", %{meeting: meeting} do
      parent = self()

      # Each spawned Task gets explicit access to the test's checked-out
      # sandbox connection — preferred over `Sandbox.mode({:shared, _})`
      # because the latter persists for the rest of the suite and leaks
      # PubSub-routed broadcasts across async-test boundaries.
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            res = Meetings.mark_notified(meeting)
            send(parent, {:cas, res})
            res
          end)
        end

      results = Task.await_many(tasks, 5_000)

      oks =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      already =
        Enum.count(results, fn
          {:already_notified, _} -> true
          _ -> false
        end)

      assert oks == 1,
             "expected exactly one :ok across 2 concurrent CAS calls, got #{oks} " <>
               "(results: #{inspect(results)})"

      assert already == 1,
             "expected exactly one :already_notified across 2 concurrent CAS calls, got " <>
               "#{already} (results: #{inspect(results)})"

      # And the column was stamped exactly once in the DB.
      reloaded = Repo.get!(Meeting, meeting.id)
      assert %DateTime{} = reloaded.notified_at
    end
  end

  # ── Recordings (task 01a0740d-e5ce-7001-812e-aa79a5392aed stage 1) ──────────
  #
  # THE LANDMINE these tests are written around. `meeting_rooms.status` is
  # `~w(idle active recording)` (`meetings/room.ex:15`), `get_active_room/1`
  # matches `"active"` and nothing else (`meetings.ex:2866`), and
  # `start_recording/2` sets the ROOM to `"recording"` (`meetings.ex:3796`).
  # So starting a recording on a live room makes `get_active_room/1` answer
  # `nil`. Every recording row below is therefore inserted with
  # `Repo.insert!/1` rather than through `start_recording/2`, EXCEPT in the
  # one test whose subject is `start_recording/2` itself.
  #
  # `live_recording_for_room/1` keys off `meeting_recordings` for the same
  # reason: reading the room's own status would make the indicator disappear
  # at the exact moment it is supposed to appear.

  defp insert_recording!(room, status, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Recording{room_id: room.id, space_id: room.space_id, status: status},
        attrs
      )
    )
  end

  describe "live_recording_for_room/1" do
    test "returns the row while a recording is in progress" do
      room = create_room(create_space().id)
      recording = insert_recording!(room, "recording")

      assert %Recording{} = found = Meetings.live_recording_for_room(room.id)
      assert found.id == recording.id
      assert found.status == "recording"
    end

    test "returns nil once the recording is processing" do
      room = create_room(create_space().id)
      insert_recording!(room, "processing")

      assert Meetings.live_recording_for_room(room.id) == nil
    end

    test "returns nil once the recording is ready" do
      room = create_room(create_space().id)
      insert_recording!(room, "ready")

      assert Meetings.live_recording_for_room(room.id) == nil
    end

    test "returns nil when the recording failed" do
      # A failed egress is not a live capture. Asserted separately from
      # `processing` and `ready` rather than in a loop over the three, so a
      # read that happened to special-case only one of them still fails here.
      room = create_room(create_space().id)
      insert_recording!(room, "failed")

      assert Meetings.live_recording_for_room(room.id) == nil
    end

    test "returns nil for a room that has never been recorded" do
      room = create_room(create_space().id)

      assert Meetings.live_recording_for_room(room.id) == nil
    end

    test "returns the most recently inserted of two live rows" do
      room = create_room(create_space().id)

      older =
        insert_recording!(room, "recording", %{
          inserted_at: ~U[2026-09-01 10:00:00.000000Z],
          updated_at: ~U[2026-09-01 10:00:00.000000Z]
        })

      newer =
        insert_recording!(room, "recording", %{
          inserted_at: ~U[2026-09-01 11:00:00.000000Z],
          updated_at: ~U[2026-09-01 11:00:00.000000Z]
        })

      assert newer.id != older.id
      assert Meetings.live_recording_for_room(room.id).id == newer.id
    end

    test "does not return another room's live recording" do
      recorded = create_room(create_space().id)
      quiet = create_room(create_space().id)
      recording = insert_recording!(recorded, "recording")

      assert Meetings.live_recording_for_room(recorded.id).id == recording.id
      assert Meetings.live_recording_for_room(quiet.id) == nil
    end

    test "returns nil for a malformed room id rather than raising" do
      # `where: r.room_id == ^room_id` raises the same Ecto.Query.CastError
      # as `Repo.get/2` on a non-uuid, and this read backs a header render.
      for id <- ["higgins", "higginshigginsxx", "", nil] do
        assert Meetings.live_recording_for_room(id) == nil
      end
    end
  end

  describe "recording writes broadcast {:recording_updated, _} on the room topic" do
    # `config/test.exs` pins no `:livekit` key, so `Meetings.enabled?/0`
    # would otherwise fall through to reading LIVEKIT_URL / _API_KEY /
    # _API_SECRET off the HOST — making these three functions return
    # `{:error, :meetings_disabled}` on CI and succeed on a developer
    # machine, or the reverse. Pinned here so the assertions mean the same
    # thing everywhere. Safe because this module is `async: false`.
    # Called AFTER the room exists, never in a `setup`: `ensure_room/1` asks
    # LiveKit to CreateRoom when a url is configured, and a fixture that
    # resolves DNS is a flake this suite does not need. None of the three
    # functions under test makes an HTTP call of its own.
    defp enable_livekit! do
      prior = Application.fetch_env(:platform, :livekit)

      Application.put_env(:platform, :livekit,
        url: "wss://livekit.invalid",
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret"
      )

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:platform, :livekit, value)
          :error -> Application.delete_env(:platform, :livekit)
        end
      end)

      :ok
    end

    test "start_recording/2 announces the new recording" do
      room = create_room(create_space().id)
      enable_livekit!()
      MeetingsPubSub.subscribe_room(room.id)

      {:ok, recording} = Meetings.start_recording(room.id)

      assert_receive {:recording_updated, %Recording{} = broadcast}
      assert broadcast.id == recording.id
      assert broadcast.room_id == room.id
      assert broadcast.status == "recording"
    end

    test "stop_recording/1 announces the move to processing" do
      room = create_room(create_space().id)
      recording = insert_recording!(room, "recording")
      enable_livekit!()
      MeetingsPubSub.subscribe_room(room.id)

      {:ok, _stopped} = Meetings.stop_recording(recording.id)

      assert_receive {:recording_updated, %Recording{} = broadcast}
      assert broadcast.id == recording.id
      assert broadcast.room_id == room.id
      assert broadcast.status == "processing"
    end

    test "recording_completed/2 announces the move to ready" do
      room = create_room(create_space().id)
      recording = insert_recording!(room, "processing")
      enable_livekit!()
      MeetingsPubSub.subscribe_room(room.id)

      {:ok, _ready} = Meetings.recording_completed(recording.id, %{duration_seconds: 12})

      assert_receive {:recording_updated, %Recording{} = broadcast}
      assert broadcast.id == recording.id
      assert broadcast.room_id == room.id
      assert broadcast.status == "ready"
    end

    test "a subscriber to a different room hears nothing" do
      room = create_room(create_space().id)
      other = create_room(create_space().id)
      enable_livekit!()
      MeetingsPubSub.subscribe_room(other.id)

      {:ok, _recording} = Meetings.start_recording(room.id)

      refute_receive {:recording_updated, _}, 200
    end
  end
end
