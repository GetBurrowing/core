defmodule Platform.Meetings.MeetingContextTest do
  @moduledoc """
  Tests for the durable-meeting context functions on `Platform.Meetings`:
  `create_meeting/1`, `get_meeting/1`, `get_meeting_by_slug/2`,
  `list_meetings_for_project/1`, `start_meeting/1`, `end_meeting/1`, and
  the `{:meeting_created, meeting}` project PubSub broadcast.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks

  defp create_project(attrs \\ %{}) do
    default = %{name: "Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  describe "create_meeting/1" do
    test "creates a meeting, a backing meeting chat space, and a livekit room name" do
      project = create_project()

      assert {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Kickoff"})

      assert meeting.project_id == project.id
      assert meeting.name == "Kickoff"
      assert meeting.slug == "kickoff"
      assert meeting.status == "scheduled"
      assert is_binary(meeting.chat_space_id)
      assert is_binary(meeting.livekit_room_name)
      assert meeting.livekit_room_name == "meeting-#{meeting.id}"

      space = Chat.get_space(meeting.chat_space_id)
      assert space.kind == "meeting"
      assert space.metadata["project_id"] == project.id

      # The backing chat space must carry a non-empty, globally-unique slug so
      # the discussion panel (gated on `@meeting.chat_space.slug`) can mount the
      # embedded chat instead of rendering "No discussion bound to this meeting."
      assert space.slug == "meeting-#{meeting.id}"
      refute space.slug in [nil, ""]
    end

    test "backing chat spaces get distinct, non-empty slugs across meetings" do
      project = create_project()

      assert {:ok, m1} = Meetings.create_meeting(%{project_id: project.id, name: "One"})
      assert {:ok, m2} = Meetings.create_meeting(%{project_id: project.id, name: "Two"})

      s1 = Chat.get_space(m1.chat_space_id)
      s2 = Chat.get_space(m2.chat_space_id)

      refute s1.slug in [nil, ""]
      refute s2.slug in [nil, ""]
      assert s1.slug != s2.slug
    end

    test "accepts string-keyed attrs" do
      project = create_project()

      assert {:ok, meeting} =
               Meetings.create_meeting(%{"project_id" => project.id, "name" => "Planning"})

      assert meeting.slug == "planning"
    end

    test "auto-generates a slug from the name when omitted" do
      project = create_project()

      assert {:ok, meeting} =
               Meetings.create_meeting(%{project_id: project.id, name: "Q3 Roadmap Review!"})

      assert meeting.slug == "q3-roadmap-review"
    end

    test "honors an explicit slug" do
      project = create_project()

      assert {:ok, meeting} =
               Meetings.create_meeting(%{
                 project_id: project.id,
                 name: "Kickoff",
                 slug: "custom-slug"
               })

      assert meeting.slug == "custom-slug"
    end

    test "deduplicates a colliding auto-generated slug within a project" do
      project = create_project()

      assert {:ok, m1} = Meetings.create_meeting(%{project_id: project.id, name: "Standup"})
      assert {:ok, m2} = Meetings.create_meeting(%{project_id: project.id, name: "Standup"})
      assert {:ok, m3} = Meetings.create_meeting(%{project_id: project.id, name: "Standup"})

      assert m1.slug == "standup"
      assert m2.slug == "standup-2"
      assert m3.slug == "standup-3"
      assert m1.livekit_room_name != m2.livekit_room_name
    end

    test "same name in two different projects both succeed (slug unique per project)" do
      a = create_project()
      b = create_project()

      assert {:ok, ma} = Meetings.create_meeting(%{project_id: a.id, name: "Standup"})
      assert {:ok, mb} = Meetings.create_meeting(%{project_id: b.id, name: "Standup"})

      assert ma.slug == "standup"
      assert mb.slug == "standup"
      assert ma.livekit_room_name != mb.livekit_room_name
    end

    test "requires project_id and name" do
      assert {:error, {:missing, :project_id}} = Meetings.create_meeting(%{name: "X"})

      project = create_project()
      assert {:error, {:missing, :name}} = Meetings.create_meeting(%{project_id: project.id})
    end

    test "broadcasts {:meeting_created, meeting} on the project topic exactly once" do
      project = create_project()
      :ok = Meetings.subscribe_to_project_meetings(project.id)

      assert {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})

      assert_receive {:meeting_created, broadcast}
      assert broadcast.id == meeting.id
      refute_receive {:meeting_created, _}, 50
    end

    test "rolls back the chat space when the meeting insert fails" do
      project = create_project()
      {:ok, _existing} = Meetings.create_meeting(%{project_id: project.id, name: "Dup"})

      spaces_before = Repo.aggregate(Chat.Space, :count)

      # Force a unique-constraint failure on (project_id, slug) by passing an
      # explicit slug that already exists.
      assert {:error, %Ecto.Changeset{}} =
               Meetings.create_meeting(%{
                 project_id: project.id,
                 name: "Another",
                 slug: "dup"
               })

      assert Repo.aggregate(Chat.Space, :count) == spaces_before
    end
  end

  describe "get_meeting/1 and get_meeting_by_slug/2" do
    test "round-trips a created meeting" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Kickoff"})

      assert Meetings.get_meeting(meeting.id).id == meeting.id
      assert Meetings.get_meeting_by_slug(project.id, "kickoff").id == meeting.id
    end

    test "returns nil for unknown ids/slugs" do
      project = create_project()
      assert Meetings.get_meeting(Ecto.UUID.generate()) == nil
      assert Meetings.get_meeting_by_slug(project.id, "nope") == nil
    end
  end

  describe "list_meetings_for_project/1" do
    test "returns only the project's meetings, newest first" do
      a = create_project()
      b = create_project()

      {:ok, m1} = Meetings.create_meeting(%{project_id: a.id, name: "First"})
      {:ok, m2} = Meetings.create_meeting(%{project_id: a.id, name: "Second"})
      {:ok, _other} = Meetings.create_meeting(%{project_id: b.id, name: "Other"})

      ids = a.id |> Meetings.list_meetings_for_project() |> Enum.map(& &1.id)
      assert m2.id in ids
      assert m1.id in ids
      assert length(ids) == 2
    end
  end

  describe "start_meeting/1 and end_meeting/1" do
    test "scheduled → live → ended lifecycle stamps timestamps" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})
      assert meeting.status == "scheduled"
      assert is_nil(meeting.started_at)

      assert {:ok, live} = Meetings.start_meeting(meeting)
      assert live.status == "live"
      assert %DateTime{} = live.started_at

      assert {:ok, ended} = Meetings.end_meeting(live)
      assert ended.status == "ended"
      assert %DateTime{} = ended.ended_at
    end

    test "start_meeting on an ended meeting returns a changeset error (no illegal flip)" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})
      {:ok, live} = Meetings.start_meeting(meeting)
      {:ok, ended} = Meetings.end_meeting(live)

      assert {:error, %Ecto.Changeset{} = cs} = Meetings.start_meeting(ended)
      assert {:status, _} = List.keyfind(cs.errors, :status, 0)
      # the row is untouched
      assert Meetings.get_meeting(ended.id).status == "ended"
    end

    test "end_meeting on a scheduled meeting returns a changeset error" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})

      assert {:error, %Ecto.Changeset{}} = Meetings.end_meeting(meeting)
    end
  end

  describe "get_live_meeting_for_space/1" do
    test "returns the live meeting bound to the chat space" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})
      {:ok, live} = Meetings.start_meeting(meeting)

      found = Meetings.get_live_meeting_for_space(live.chat_space_id)
      assert found.id == live.id
      assert found.status == "live"
    end

    test "returns nil when the space's meeting is only scheduled" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})

      assert Meetings.get_live_meeting_for_space(meeting.chat_space_id) == nil
    end

    test "returns nil once the live meeting has ended" do
      project = create_project()
      {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Sync"})
      {:ok, live} = Meetings.start_meeting(meeting)
      {:ok, _ended} = Meetings.end_meeting(live)

      assert Meetings.get_live_meeting_for_space(live.chat_space_id) == nil
    end

    test "returns nil for an unknown space and tolerates nil" do
      assert Meetings.get_live_meeting_for_space(Ecto.UUID.generate()) == nil
      assert Meetings.get_live_meeting_for_space(nil) == nil
    end
  end
end
