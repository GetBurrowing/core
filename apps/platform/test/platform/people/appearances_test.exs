defmodule Platform.People.AppearancesTest do
  @moduledoc """
  Task 01a1aa47 stage 3 — `Platform.People.Appearances.collect/3` gathers
  sightings from chat authors, `@[Name]` mentions, meeting participants and
  task people, each with a citation, and never carries transcript text.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias Platform.Meetings
  alias Platform.Meetings.{Meeting, Room, Transcript}
  alias Platform.People.Appearances
  alias Platform.Repo
  alias Platform.Tasks.{Project, Task}
  alias Platform.TenancyFixtures

  @now ~U[2026-10-20 10:00:00.000000Z]
  @ws ~U[2026-10-20 09:00:00.000000Z]
  @we ~U[2026-10-20 11:00:00.000000Z]
  @spoken "I think Marisol is slow playing us"

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "app-#{n}@example.com", name: name, oidc_sub: "app-#{n}"})
    |> Repo.insert!()
  end

  defp space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "app-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp participant!(space, user, name) do
    %Participant{}
    |> Participant.changeset(%{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      display_name: name,
      joined_at: @now
    })
    |> Repo.insert!()
  end

  defp message!(space, participant, user, name, content, at \\ @now, extra \\ %{}) do
    %Message{}
    |> Message.changeset(
      Map.merge(
        %{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: content,
          author_display_name: name,
          author_user_id: user && user.id,
          author_participant_type: "user"
        },
        extra
      )
    )
    |> Ecto.Changeset.put_change(:inserted_at, at)
    |> Repo.insert!()
  end

  defp project! do
    %Project{}
    |> Project.changeset(%{
      name: "P #{System.unique_integer([:positive])}",
      org_id: TenancyFixtures.acme_org_id()
    })
    |> Repo.insert!()
  end

  defp meeting_with_room!(space, project) do
    meeting =
      %Meeting{}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "m-#{System.unique_integer([:positive])}",
        name: "Deploy review",
        livekit_room_name: "meeting-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    room =
      %Room{}
      |> Room.changeset(%{space_id: space.id, livekit_room_name: meeting.livekit_room_name})
      |> Repo.insert!()

    {meeting, room}
  end

  defp task!(project, attrs) do
    %Task{}
    |> Task.changeset(
      Map.merge(%{project_id: project.id, title: "Task", status: "in_progress"}, attrs)
    )
    |> Ecto.Changeset.put_change(:inserted_at, @now)
    |> Ecto.Changeset.put_change(:updated_at, @now)
    |> Repo.insert!()
  end

  test "collects chat authors, mentions, meeting participants and task people with citations" do
    marisol = user!("Marisol Tennebrook")
    oskar = user!("Oskar Vellinghausen")
    priya = user!("Priya Kalloway")
    space = space!("eng")
    author = participant!(space, marisol, "Marisol Tennebrook")

    message =
      message!(
        space,
        author,
        marisol,
        "Marisol Tennebrook",
        "ping @[Oskar Vellinghausen] about the deploy"
      )

    agent_participant =
      %Participant{}
      |> Participant.changeset(%{
        space_id: space.id,
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Scribe",
        joined_at: @now
      })
      |> Repo.insert!()

    agent_message =
      message!(space, agent_participant, nil, "Scribe", "noted", @now, %{
        author_participant_type: "agent",
        author_agent_id: agent_participant.participant_id
      })

    project = project!()
    {meeting, room} = meeting_with_room!(space, project)

    {:ok, _} =
      Meetings.participant_joined(room, %{
        display_name: "Priya Kalloway",
        joined_at: @now,
        user_id: priya.id
      })

    task =
      task!(project, %{sponsor_user_id: oskar.id, assignee_type: "user", assignee_id: priya.id})

    _agent_task = task!(project, %{assignee_type: "agent", assignee_id: Ecto.UUID.generate()})

    appearances = Appearances.collect(@ws, @we)
    by_source = Enum.group_by(appearances, & &1.source)

    assert [
             %{
               raw_name: "Marisol Tennebrook",
               kind: :human,
               user_id: marisol_id,
               citation: chat_cite
             },
             scribe
           ] =
             Enum.sort_by(by_source[:chat_author], & &1.raw_name)

    assert marisol_id == marisol.id
    assert chat_cite == "chat:#{space.id}:#{message.id}"
    assert %{raw_name: "Scribe", kind: :agent, agent_id: agent_id, citation: scribe_cite} = scribe
    assert agent_id == agent_participant.participant_id
    assert scribe_cite == "chat:#{space.id}:#{agent_message.id}"

    assert [%{raw_name: "Oskar Vellinghausen", source: :chat_mention, citation: mention_cite}] =
             by_source[:chat_mention]

    assert mention_cite == "chat:#{space.id}:#{message.id}"

    assert [
             %{
               raw_name: "Priya Kalloway",
               kind: :human,
               user_id: priya_id,
               meeting_id: meeting_id,
               project_id: pid,
               citation: m_cite
             }
           ] =
             by_source[:meeting_participant]

    assert {priya_id, meeting_id, pid} == {priya.id, meeting.id, project.id}
    assert m_cite == "meeting:#{meeting.id}"

    task_people =
      by_source[:task_assignee]
      |> Enum.map(&{&1.raw_name, &1.task_id, &1.citation})
      |> Enum.sort()

    assert task_people == [
             {"Oskar Vellinghausen", task.id, "task:#{task.id}"},
             {"Priya Kalloway", task.id, "task:#{task.id}"}
           ]

    assert Enum.all?(appearances, &match?(%DateTime{}, &1.at))
  end

  test "never carries transcript text" do
    space = space!("call")
    project = project!()
    {_meeting, room} = meeting_with_room!(space, project)

    {:ok, _} =
      Meetings.participant_joined(room, %{display_name: "Fixture Founder", joined_at: @now})

    %Transcript{}
    |> Transcript.changeset(%{
      room_id: room.livekit_room_name,
      space_id: space.id,
      status: "complete",
      completed_at: @now,
      summary: "Fixture Founder said " <> @spoken,
      segments: [%{"id" => "s1", "speaker_name" => "Fixture Founder", "text" => @spoken}]
    })
    |> Repo.insert!()

    appearances = Appearances.collect(@ws, @we)

    assert [%{raw_name: "Fixture Founder", source: :meeting_participant}] = appearances
    refute inspect(appearances) =~ "slow playing"
    refute inspect(appearances) =~ "summary"
  end

  test "respects the window and the scope" do
    marisol = user!("Marisol Tennebrook")
    space = space!("eng")
    author = participant!(space, marisol, "Marisol Tennebrook")

    message!(
      space,
      author,
      marisol,
      "Marisol Tennebrook",
      "early",
      DateTime.add(@ws, -1, :second)
    )

    message!(space, author, marisol, "Marisol Tennebrook", "late", @we)

    assert Appearances.collect(@ws, @we) == []
  end
end
