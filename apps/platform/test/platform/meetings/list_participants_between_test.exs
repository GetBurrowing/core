defmodule Platform.Meetings.ListParticipantsBetweenTest do
  @moduledoc """
  Task 01a1aa47 stage 3 — `Platform.Meetings.list_participants_between/3`
  and `participants_for_transcript/1`: attendance rows for the HR
  responsibility, windowed on `joined_at` and partitioned by the same
  `:scope` seam as the digest.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.{Meeting, Room, Transcript}
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  @now ~U[2026-10-20 10:00:00.000000Z]
  @ws ~U[2026-10-20 09:00:00.000000Z]
  @we ~U[2026-10-20 11:00:00.000000Z]

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "lpb-#{n}@example.com", name: name, oidc_sub: "lpb-#{n}"})
    |> Repo.insert!()
  end

  defp space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "lpb-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp room!(space) do
    %Room{}
    |> Room.changeset(%{
      space_id: space.id,
      livekit_room_name: "room-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp meeting!(space, name) do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "P #{System.unique_integer([:positive])}",
        org_id: TenancyFixtures.acme_org_id()
      })
      |> Repo.insert!()

    %Meeting{}
    |> Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "m-#{System.unique_integer([:positive])}",
      name: name,
      livekit_room_name: "meeting-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp join!(room, name, joined_at, attrs \\ %{}) do
    {:ok, participant} =
      Meetings.participant_joined(
        room,
        Map.merge(%{display_name: name, joined_at: joined_at}, attrs)
      )

    participant
  end

  test "returns participants joined inside the window with meeting and space" do
    marisol = user!("Marisol Tennebrook")
    space = space!("deploy-review")
    meeting = meeting!(space, "Deploy review")
    room = room!(space)

    join!(room, "Marisol Tennebrook", @now, %{user_id: marisol.id})
    join!(room, "Oskar Vellinghausen", DateTime.add(@now, 60, :second))

    rows = Meetings.list_participants_between(@ws, @we)

    assert [first, second] = rows
    assert first.display_name == "Marisol Tennebrook"
    assert first.user_id == marisol.id
    assert first.space_id == space.id
    assert first.meeting_id == meeting.id
    assert first.meeting_name == "Deploy review"
    assert first.project_id == meeting.project_id
    assert first.joined_at == @now
    assert second.display_name == "Oskar Vellinghausen"
    assert is_nil(second.user_id)
  end

  test "excludes rows outside the window and external-scope spaces" do
    internal = space!("internal")
    room = room!(internal)
    join!(room, "Marisol Tennebrook", @now)
    join!(room, "Too Early", DateTime.add(@ws, -1, :second))
    join!(room, "At The End", @we)
    join!(room, "Too Late", DateTime.add(@we, 60, :second))

    external_user = user!("Fixture Founder")

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: external_user.id,
        org_id: TenancyFixtures.tenant_org_id("globex")
      })

    external = space!("external")

    {:ok, _} =
      Chat.add_participant(external.id, %{
        participant_type: "user",
        participant_id: external_user.id,
        joined_at: @now
      })

    external_room = room!(external)
    join!(external_room, "Fixture Founder", @now, %{user_id: external_user.id})

    names = @ws |> Meetings.list_participants_between(@we) |> Enum.map(& &1.display_name)
    assert names == ["Marisol Tennebrook"]

    external_names =
      @ws
      |> Meetings.list_participants_between(@we, scope: {:external_spaces, [external.id]})
      |> Enum.map(& &1.display_name)

    assert external_names == ["Fixture Founder"]
  end

  test "participants_for_transcript resolves the room by name and falls back to the space" do
    space = space!("by-name")
    room = room!(space)
    join!(room, "Priya Kalloway", @now)

    by_name =
      %Transcript{}
      |> Transcript.changeset(%{
        room_id: room.livekit_room_name,
        status: "complete",
        completed_at: @now
      })
      |> Repo.insert!()

    by_space =
      %Transcript{}
      |> Transcript.changeset(%{room_id: "gone-room", space_id: space.id, status: "complete"})
      |> Repo.insert!()

    space_id = space.id

    assert [%{display_name: "Priya Kalloway", space_id: ^space_id}] =
             Meetings.participants_for_transcript(by_name.id)

    assert [%{display_name: "Priya Kalloway"}] = Meetings.participants_for_transcript(by_space.id)
    assert Meetings.participants_for_transcript("not-a-uuid") == []
    assert Meetings.participants_for_transcript(nil) == []
  end
end
