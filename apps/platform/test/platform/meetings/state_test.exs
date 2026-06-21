defmodule Platform.Meetings.StateTest do
  @moduledoc """
  Tests for `Platform.Meetings.State` — per-user meeting state cache +
  PubSub broadcaster (task 019ee06b stage 1).

  Covers:
    * `get_for_user/1` for missing + present users
    * `broadcast_joined/5` writes ETS *and* broadcasts full payload
      (including `:space_slug`, `:meeting_slug`, `:started_at`)
    * `broadcast_left/1` deletes ETS *before* broadcasting
    * Concurrent readers don't deadlock against a churning writer

  Async-false because the module owns a single named ETS table that's
  started under `Platform.Application`'s supervision tree.
  """

  use ExUnit.Case, async: false

  alias Platform.Meetings.State, as: MeetingState

  setup do
    # The GenServer is booted by Platform.Application; just clear any rows
    # that earlier tests left lying around for the user_ids we use here.
    on_exit(fn ->
      for uid <- ["test-user-1", "test-user-2", "test-user-concurrent"] do
        MeetingState.broadcast_left(uid)
      end
    end)

    :ok
  end

  describe "get_for_user/1" do
    test "returns nil when no entry exists" do
      assert MeetingState.get_for_user("test-user-1") == nil
    end

    test "returns nil for non-binary input" do
      assert MeetingState.get_for_user(nil) == nil
      assert MeetingState.get_for_user(123) == nil
    end

    test "returns the stored map after broadcast_joined/5" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-123",
          "Engineering",
          "engineering",
          "standup-2026-06-19"
        )

      # Drain the broadcast so it doesn't poison later assert_receive calls.
      assert_receive {:meeting_joined, _}

      assert %{
               space_id: "space-123",
               space_name: "Engineering",
               space_slug: "engineering",
               meeting_slug: "standup-2026-06-19",
               started_at: %DateTime{}
             } = MeetingState.get_for_user("test-user-1")
    end

    test "returns nil after broadcast_left/1" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-123",
          "Engineering",
          "engineering",
          "standup"
        )

      assert_receive {:meeting_joined, _}
      assert MeetingState.get_for_user("test-user-1") != nil

      :ok = MeetingState.broadcast_left("test-user-1")
      assert_receive {:meeting_left, _}

      assert MeetingState.get_for_user("test-user-1") == nil
    end
  end

  describe "broadcast_joined/5" do
    test "broadcast payload contains all six fields" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-abc",
          "Design",
          "design",
          "design-sync-q3"
        )

      assert_receive {:meeting_joined, payload}

      assert %{
               user_id: "test-user-1",
               space_id: "space-abc",
               space_name: "Design",
               space_slug: "design",
               meeting_slug: "design-sync-q3",
               started_at: %DateTime{}
             } = payload
    end

    test "writes ETS before broadcasting so reactive reads see fresh state" do
      # Subscribe from a separate process so we can inspect what ETS holds
      # the moment the broadcast lands, simulating a handle_info handler
      # that immediately reads via get_for_user/1.
      test_pid = self()

      reader =
        spawn_link(fn ->
          :ok = MeetingState.subscribe("test-user-1")
          send(test_pid, :ready)

          receive do
            {:meeting_joined, _} ->
              snapshot = MeetingState.get_for_user("test-user-1")
              send(test_pid, {:snapshot, snapshot})
          after
            1_000 ->
              send(test_pid, {:snapshot, :timeout})
          end
        end)

      assert_receive :ready

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-z",
          "Z Space",
          "z-space",
          "z-meeting"
        )

      assert_receive {:snapshot, snapshot}
      assert is_map(snapshot)
      assert snapshot.space_id == "space-z"
      assert snapshot.meeting_slug == "z-meeting"

      # Tidy: stop the reader.
      Process.exit(reader, :normal)
    end

    test "accepts nil meeting_slug (race: room exists but no Meeting row yet)" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-x",
          "X Space",
          "x-space",
          nil
        )

      assert_receive {:meeting_joined, %{meeting_slug: nil}}
      assert %{meeting_slug: nil} = MeetingState.get_for_user("test-user-1")
    end
  end

  describe "broadcast_left/1" do
    test "deletes ETS row before broadcasting" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_joined(
          "test-user-1",
          "space-1",
          "One",
          "one",
          "m1"
        )

      assert_receive {:meeting_joined, _}

      # Same pattern as the broadcast_joined order check, inverted: a
      # handler that reads on `:meeting_left` must see nil.
      test_pid = self()

      reader =
        spawn_link(fn ->
          :ok = MeetingState.subscribe("test-user-1")
          send(test_pid, :ready)

          receive do
            {:meeting_left, _} ->
              send(test_pid, {:snapshot, MeetingState.get_for_user("test-user-1")})
          after
            1_000 ->
              send(test_pid, {:snapshot, :timeout})
          end
        end)

      assert_receive :ready
      :ok = MeetingState.broadcast_left("test-user-1")

      assert_receive {:snapshot, nil}

      Process.exit(reader, :normal)
    end

    test "is a no-op for a user that was never joined" do
      :ok = MeetingState.subscribe("test-user-2")
      assert :ok = MeetingState.broadcast_left("test-user-2")
      assert_receive {:meeting_left, %{user_id: "test-user-2"}}
      assert MeetingState.get_for_user("test-user-2") == nil
    end
  end

  describe "broadcast_media_state/2" do
    test "subscribers receive the tagged event with the full media pair" do
      :ok = MeetingState.subscribe("test-user-1")

      assert :ok =
               MeetingState.broadcast_media_state("test-user-1", %{
                 mic_enabled: false,
                 camera_enabled: true
               })

      assert_receive {:meeting_media_state,
                      %{
                        user_id: "test-user-1",
                        mic_enabled: false,
                        camera_enabled: true
                      }},
                     200
    end

    test "always carries both flags (no partial-update event shape)" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_media_state("test-user-1", %{
          mic_enabled: true,
          camera_enabled: false
        })

      assert_receive {:meeting_media_state, payload}, 200
      assert Map.has_key?(payload, :mic_enabled)
      assert Map.has_key?(payload, :camera_enabled)
      assert Map.has_key?(payload, :user_id)
    end

    test "is per-user — subscribing to A does not receive B's event" do
      :ok = MeetingState.subscribe("test-user-1")

      :ok =
        MeetingState.broadcast_media_state("test-user-2", %{
          mic_enabled: false,
          camera_enabled: false
        })

      refute_receive {:meeting_media_state, _}, 100
    end

    test "does NOT mutate the ETS-cached lifecycle state" do
      # No prior join → no cached state.
      assert MeetingState.get_for_user("test-user-1") == nil

      :ok =
        MeetingState.broadcast_media_state("test-user-1", %{
          mic_enabled: false,
          camera_enabled: true
        })

      # Media-state events are transient; they must not populate the cache
      # used by fresh shell mounts to hydrate the persistent mini-bar.
      assert MeetingState.get_for_user("test-user-1") == nil
    end

    test "rejects non-boolean media flags via guard" do
      assert_raise FunctionClauseError, fn ->
        MeetingState.broadcast_media_state("test-user-1", %{
          mic_enabled: "yes",
          camera_enabled: true
        })
      end

      assert_raise FunctionClauseError, fn ->
        MeetingState.broadcast_media_state("test-user-1", %{
          mic_enabled: true,
          camera_enabled: nil
        })
      end
    end
  end

  describe "concurrent access" do
    test "50 readers don't deadlock against a churning writer" do
      uid = "test-user-concurrent"

      writer =
        Task.async(fn ->
          for i <- 1..200 do
            MeetingState.broadcast_joined(uid, "space-#{i}", "S#{i}", "s-#{i}", "m-#{i}")

            if rem(i, 5) == 0 do
              MeetingState.broadcast_left(uid)
            end
          end
        end)

      readers =
        for _ <- 1..50 do
          Task.async(fn ->
            for _ <- 1..200 do
              # Either map or nil — both are valid mid-churn observations.
              case MeetingState.get_for_user(uid) do
                nil -> :ok
                %{space_id: _} -> :ok
              end
            end

            :done
          end)
        end

      assert :ok == Task.await(writer, 5_000) |> then(fn _ -> :ok end)
      assert Enum.all?(Task.await_many(readers, 5_000), &(&1 == :done))
    end
  end
end
