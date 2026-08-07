defmodule Platform.Meetings.WhiteboardTest do
  @moduledoc """
  Tests for the meeting whiteboard store (task 019fcfcf stage 1):
  `Platform.Meetings.get_whiteboard/1`,
  `Platform.Meetings.upsert_whiteboard_scene/4`, the `scene_version`
  compare-and-set, the `on_delete: :delete_all` cascade, and the
  `{:whiteboard_scene_saved, _}` broadcast.

  ## What is NOT tested here, stated plainly

  The compare-and-set is implemented inside a `Repo.transaction` with
  `SELECT ... FOR UPDATE` so two concurrent savers cannot both read
  version N and both write N+1. **These tests do not prove that.** Every
  case below is sequential, and the Ecto SQL sandbox hands the whole
  test one checked-out connection — two processes allowed onto that
  connection serialise through it, so a "concurrent" test written here
  would pass whether or not the row lock existed and would be evidence
  of nothing. What IS covered is the decision the lock protects: a save
  carrying a version that does not equal the stored one is rejected and
  writes nothing.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Whiteboard
  alias Platform.Repo
  alias Platform.Tasks

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Project #{n}"})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Space #{n}",
        slug: "meeting-space-#{n}",
        kind: "meeting"
      })

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "standup-#{n}",
      name: "Standup",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "drawer-#{n}@example.com",
      name: "Drawer #{n}",
      oidc_sub: "oidc-drawer-#{n}"
    })
    |> Repo.insert!()
  end

  defp scene(label) do
    %{
      "type" => "excalidraw",
      "version" => 2,
      "elements" => [%{"id" => label, "type" => "rectangle", "width" => 10, "height" => 10}],
      "appState" => %{"viewBackgroundColor" => "#ffffff"},
      "files" => %{}
    }
  end

  describe "upsert_whiteboard_scene/4" do
    test "creates the row on first save with scene_version 1" do
      meeting = meeting!()
      user = user!()

      assert is_nil(Meetings.get_whiteboard(meeting.id))

      assert {:ok, %Whiteboard{} = wb} =
               Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)

      assert wb.scene_version == 1
      assert wb.meeting_id == meeting.id
      assert wb.last_edited_by_user_id == user.id
      assert wb.scene == scene("a")

      reloaded = Meetings.get_whiteboard(meeting.id)
      assert reloaded.id == wb.id
      assert reloaded.scene == scene("a")
      assert reloaded.scene_version == 1
    end

    test "a second save with the correct expected_version succeeds and increments" do
      meeting = meeting!()
      user = user!()

      {:ok, first} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)
      assert first.scene_version == 1

      assert {:ok, second} =
               Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("b"), 1)

      assert second.scene_version == 2
      assert second.id == first.id, "a second save must update the one row, not insert another"

      assert Meetings.get_whiteboard(meeting.id).scene == scene("b")
      assert Repo.aggregate(Whiteboard, :count) >= 1
    end

    test "a stale expected_version is rejected and leaves the stored scene byte-identical" do
      meeting = meeting!()
      user = user!()

      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)
      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("b"), 1)

      before = Meetings.get_whiteboard(meeting.id)
      assert before.scene_version == 2

      # Version 1 is behind: this client drew on top of a scene someone
      # else has already replaced.
      assert {:error, :stale_version, current} =
               Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("loser"), 1)

      assert current.scene_version == 2

      # The rejection must also not have WRITTEN. An error tuple alone
      # is satisfied by an implementation that clobbers and then
      # complains, so re-read and compare the encoded bytes.
      unchanged = Meetings.get_whiteboard(meeting.id)
      assert unchanged.scene_version == 2
      assert Jason.encode!(unchanged.scene) == Jason.encode!(before.scene)
      assert unchanged.scene == scene("b")
      assert unchanged.updated_at == before.updated_at
    end

    test "an expected_version ahead of the stored one is rejected too" do
      meeting = meeting!()
      user = user!()

      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)

      assert {:error, :stale_version, current} =
               Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("future"), 7)

      assert current.scene_version == 1
      assert Meetings.get_whiteboard(meeting.id).scene == scene("a")
    end

    test "a nil user_id is allowed and stored as nil" do
      meeting = meeting!()

      assert {:ok, wb} = Meetings.upsert_whiteboard_scene(meeting.id, nil, scene("a"), 0)
      assert is_nil(wb.last_edited_by_user_id)
    end
  end

  describe "cascade" do
    test "deleting the meeting deletes its whiteboard row" do
      meeting = meeting!()
      user = user!()

      {:ok, wb} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)

      # Positive control: "it is gone afterwards" is trivially true of a
      # row that never existed, so assert it exists first.
      assert %Whiteboard{} = Repo.get(Whiteboard, wb.id)

      Repo.delete!(meeting)

      refute Repo.get(Whiteboard, wb.id)
      assert is_nil(Meetings.get_whiteboard(meeting.id))
    end
  end

  describe "broadcast" do
    test "a successful save broadcasts the version and carries no scene payload" do
      meeting = meeting!()
      user = user!()

      :ok = MeetingsPubSub.subscribe_meeting(meeting.id)

      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)

      assert_receive {:whiteboard_scene_saved, payload}

      # Exact equality, not a `refute Map.has_key?(payload, :scene)`:
      # that refute passes on a message that never arrived and on a
      # payload that smuggles the bytes under another key.
      assert payload == %{
               meeting_id: meeting.id,
               scene_version: 1,
               by_user_id: user.id
             }

      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("b"), 1)

      assert_receive {:whiteboard_scene_saved, second}

      assert second == %{
               meeting_id: meeting.id,
               scene_version: 2,
               by_user_id: user.id
             }
    end

    test "a rejected save broadcasts nothing" do
      meeting = meeting!()
      user = user!()

      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("a"), 0)

      :ok = MeetingsPubSub.subscribe_meeting(meeting.id)

      assert {:error, :stale_version, _} =
               Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("loser"), 0)

      refute_receive {:whiteboard_scene_saved, _}, 100

      # Paired positive control: the subscription IS live, so the refute
      # above is about the rejection and not about a dead topic.
      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, user.id, scene("c"), 1)
      assert_receive {:whiteboard_scene_saved, %{scene_version: 2}}
    end
  end

  describe "get_whiteboard/1" do
    test "returns nil for a meeting with no board and for a malformed id" do
      meeting = meeting!()

      assert is_nil(Meetings.get_whiteboard(meeting.id))
      assert is_nil(Meetings.get_whiteboard("not-a-uuid"))
      assert is_nil(Meetings.get_whiteboard(Ecto.UUID.generate()))

      # Paired positive: the same function DOES find a board once saved,
      # so the nils above are absence and not a broken read path.
      {:ok, _} = Meetings.upsert_whiteboard_scene(meeting.id, nil, scene("a"), 0)
      assert %Whiteboard{} = Meetings.get_whiteboard(meeting.id)
    end
  end
end
