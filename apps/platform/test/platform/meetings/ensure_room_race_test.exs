defmodule Platform.Meetings.EnsureRoomRaceTest do
  @moduledoc """
  Task 01a18d0a stage 4: two people pressing Join on a scheduled meeting at
  the same instant. `Meetings.ensure_room/1` reads for a room, calls LiveKit's
  CreateRoom, then inserts. Both joins could read "no room", and the second
  insert tripped the `space_id` unique index; that error reached
  `join_for_user/3` and the second Join silently did nothing.

  The race is made deterministic rather than hoped for: the stubbed
  CreateRoom call, which runs between the read and the insert, inserts the
  competing joiner's room row, exactly as the winner would.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])
    {:ok, project} = Platform.Tasks.create_project(%{name: "Race #{n}", org_id: org_id})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Race #{n}"})
    %{meeting: meeting, org_id: org_id}
  end

  defp lose_the_race_to_a_concurrent_join(space_id) do
    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :room_race}))

    Req.Test.stub(:room_race, fn conn ->
      # The other joiner's insert lands while this one is inside CreateRoom.
      unless Repo.get_by(Room, space_id: space_id) do
        %Room{}
        |> Room.changeset(%{
          livekit_room_name: Meetings.room_name_for_space(space_id),
          space_id: space_id
        })
        |> Repo.insert!()
      end

      Req.Test.json(conn, %{})
    end)

    on_exit(&Platform.LivekitStubPlug.restore_default_req_client/0)
  end

  test "ensure_room returns the room a concurrent join inserted, not a unique-index error",
       %{meeting: meeting} do
    space_id = meeting.chat_space_id
    lose_the_race_to_a_concurrent_join(space_id)

    assert {:ok, %Room{space_id: ^space_id} = room} = Meetings.ensure_room(space_id)
    assert [%Room{id: id}] = Repo.all(from(r in Room, where: r.space_id == ^space_id))
    assert id == room.id
  end

  test "the second of two simultaneous joins still gets a token", %{
    meeting: meeting,
    org_id: org_id
  } do
    user =
      Repo.insert!(%User{
        email: "race-#{System.unique_integer([:positive])}@example.com",
        name: "Race Bob",
        oidc_sub: "race-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    lose_the_race_to_a_concurrent_join(meeting.chat_space_id)

    assert {:ok, %{token: token, room: %Room{}}} =
             Meetings.join_for_user(meeting.chat_space_id, user.id, user.name)

    assert is_binary(token)
  end
end
