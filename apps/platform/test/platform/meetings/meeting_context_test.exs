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
  alias Platform.Meetings.Meeting
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

    test "persists the intended-time pair to the columns, not just the returned struct" do
      project = create_project()
      start_at = ~U[2026-08-04 15:00:00.000000Z]
      end_at = ~U[2026-08-04 15:30:00.000000Z]

      assert {:ok, meeting} =
               Meetings.create_meeting(%{
                 project_id: project.id,
                 name: "Roadmap",
                 scheduled_start_at: start_at,
                 scheduled_end_at: end_at
               })

      assert meeting.scheduled_start_at == start_at
      assert meeting.scheduled_end_at == end_at

      # Read the row back rather than trusting the struct: `create_meeting/1`
      # builds an explicit whitelist map instead of forwarding `attrs`, so a
      # field missing from that map is dropped before the insert. The returned
      # struct would still carry the value if it were merely echoed, which is
      # exactly the bug this asserts against.
      reloaded = Repo.get(Meeting, meeting.id)
      assert reloaded.scheduled_start_at == start_at
      assert reloaded.scheduled_end_at == end_at
    end

    test "accepts string-keyed intended times" do
      project = create_project()
      start_at = ~U[2026-08-05 09:00:00.000000Z]
      end_at = ~U[2026-08-05 10:00:00.000000Z]

      assert {:ok, meeting} =
               Meetings.create_meeting(%{
                 "project_id" => project.id,
                 "name" => "Planning",
                 "scheduled_start_at" => start_at,
                 "scheduled_end_at" => end_at
               })

      reloaded = Repo.get(Meeting, meeting.id)
      assert reloaded.scheduled_start_at == start_at
      assert reloaded.scheduled_end_at == end_at
    end

    test "an ad-hoc meeting is created with no intended time and still starts" do
      project = create_project()

      assert {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Ad Hoc"})

      assert meeting.scheduled_start_at == nil
      assert meeting.scheduled_end_at == nil
      assert Repo.get(Meeting, meeting.id).scheduled_start_at == nil
      assert Repo.get(Meeting, meeting.id).scheduled_end_at == nil

      # This is the path `MeetingLive.maybe_start_meeting/1` drives on every
      # auto-join. Starting must stamp the actual and leave the intent alone —
      # a meeting can be live without ever having been on anyone's calendar.
      assert {:ok, started} = Meetings.start_meeting(meeting)
      assert started.status == "live"
      assert started.started_at != nil

      reloaded = Repo.get(Meeting, meeting.id)
      assert reloaded.status == "live"
      assert reloaded.started_at != nil
      assert reloaded.scheduled_start_at == nil
      assert reloaded.scheduled_end_at == nil
    end

    test "an inverted intended-time pair errors and rolls back the backing chat space" do
      project = create_project()

      spaces_before = Repo.aggregate(Chat.Space, :count)
      meetings_before = Repo.aggregate(Meeting, :count)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Meetings.create_meeting(%{
                 project_id: project.id,
                 name: "Backwards",
                 scheduled_start_at: ~U[2026-08-06 16:00:00.000000Z],
                 scheduled_end_at: ~U[2026-08-06 15:00:00.000000Z]
               })

      assert {"must be after scheduled_start_at", _} = changeset.errors[:scheduled_end_at]

      # The insert runs inside `Repo.transaction/1`, so a rejected intent must
      # take the already-created chat space down with it rather than leaving an
      # orphan space that no meeting points at.
      assert Repo.aggregate(Chat.Space, :count) == spaces_before
      assert Repo.aggregate(Meeting, :count) == meetings_before
    end

    test "a half-populated intended-time pair errors" do
      project = create_project()
      spaces_before = Repo.aggregate(Chat.Space, :count)

      assert {:error, %Ecto.Changeset{}} =
               Meetings.create_meeting(%{
                 project_id: project.id,
                 name: "Open Ended",
                 scheduled_start_at: ~U[2026-08-07 16:00:00.000000Z]
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

  describe "list_meetings_in_range/3" do
    # Every fixture meeting gets a 30-minute intended window; only
    # `scheduled_start_at` is what the range query places rows by.
    defp scheduled_meeting(project, name, start_at) do
      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: name,
          scheduled_start_at: start_at,
          scheduled_end_at: DateTime.add(start_at, 30 * 60, :second)
        })

      meeting
    end

    defp slugs_in_range(from, to, opts \\ []) do
      from |> Meetings.list_meetings_in_range(to, opts) |> Enum.map(& &1.slug)
    end

    test "returns only the meetings intended inside the window" do
      project = create_project()
      from = ~U[2026-09-07 00:00:00.000000Z]
      to = ~U[2026-09-08 00:00:00.000000Z]

      scheduled_meeting(project, "In Morning", ~U[2026-09-07 09:00:00.000000Z])
      scheduled_meeting(project, "In Evening", ~U[2026-09-07 20:00:00.000000Z])

      # Rows on BOTH sides of the window. Without them a "range" test passes
      # identically against a query carrying no `where` clause at all: the
      # out-of-window rows are what make the filter observable.
      scheduled_meeting(project, "Prior Day", ~U[2026-09-06 09:00:00.000000Z])
      scheduled_meeting(project, "Next Day", ~U[2026-09-09 09:00:00.000000Z])

      assert slugs_in_range(from, to) == ["in-morning", "in-evening"]
    end

    test "the window is half-open: a row exactly at `from` is in, one exactly at `to` is out" do
      project = create_project()
      from = ~U[2026-09-14 00:00:00.000000Z]
      to = ~U[2026-09-15 00:00:00.000000Z]

      scheduled_meeting(project, "At From", from)
      scheduled_meeting(project, "At To", to)

      # A closed-on-both-ends window would return "at-to" here AND again from
      # the next day's call, putting one meeting in two columns of a grid.
      assert slugs_in_range(from, to) == ["at-from"]
    end

    test "orders by intended time, not by creation order" do
      project = create_project()
      from = ~U[2026-09-21 00:00:00.000000Z]
      to = ~U[2026-09-22 00:00:00.000000Z]

      # Creation order is deliberately neither the intended order nor its
      # reverse, so BOTH `asc: inserted_at` and `desc: inserted_at` produce a
      # different list than the assertion below.
      scheduled_meeting(project, "Mid", ~U[2026-09-21 11:00:00.000000Z])
      scheduled_meeting(project, "Late", ~U[2026-09-21 13:00:00.000000Z])
      scheduled_meeting(project, "Early", ~U[2026-09-21 09:00:00.000000Z])

      assert slugs_in_range(from, to) == ["early", "mid", "late"]
    end

    test "falls back to inserted_at only to break a tie at the same intended instant" do
      project = create_project()
      from = ~U[2026-09-28 00:00:00.000000Z]
      to = ~U[2026-09-29 00:00:00.000000Z]
      same_instant = ~U[2026-09-28 10:00:00.000000Z]

      scheduled_meeting(project, "Tie First", same_instant)
      scheduled_meeting(project, "Tie Second", same_instant)

      assert slugs_in_range(from, to) == ["tie-first", "tie-second"]
    end

    test "narrows to :project_id when given and spans projects when it is not" do
      a = create_project()
      b = create_project()
      from = ~U[2026-10-05 00:00:00.000000Z]
      to = ~U[2026-10-06 00:00:00.000000Z]

      scheduled_meeting(a, "Project A Sync", ~U[2026-10-05 09:00:00.000000Z])
      scheduled_meeting(b, "Project B Sync", ~U[2026-10-05 10:00:00.000000Z])

      assert slugs_in_range(from, to, project_id: a.id) == ["project-a-sync"]
      assert slugs_in_range(from, to, project_id: b.id) == ["project-b-sync"]
      assert slugs_in_range(from, to) == ["project-a-sync", "project-b-sync"]
    end

    test "excludes ad-hoc meetings with no intended time, which list_all_meetings/0 still returns" do
      project = create_project()
      from = ~U[2026-10-12 00:00:00.000000Z]
      to = ~U[2026-10-13 00:00:00.000000Z]

      {:ok, ad_hoc} = Meetings.create_meeting(%{project_id: project.id, name: "Ad Hoc"})
      scheduled = scheduled_meeting(project, "Scheduled", ~U[2026-10-12 09:00:00.000000Z])

      assert ad_hoc.scheduled_start_at == nil

      # The presence half of the pair. Asserting only the absence below would
      # also pass if the row had never been inserted at all.
      all_ids = Meetings.list_all_meetings() |> Enum.map(& &1.id)
      assert ad_hoc.id in all_ids
      assert scheduled.id in all_ids

      # The absence half: `scheduled_start_at IS NULL` never satisfies `>=`.
      range_ids = from |> Meetings.list_meetings_in_range(to) |> Enum.map(& &1.id)
      refute ad_hoc.id in range_ids
      assert range_ids == [scheduled.id]
    end
  end

  describe "missed?/2 and list_missed_meetings/1" do
    # A fixed anchor passed as `:now` everywhere below. Nothing here reads
    # the wall clock, so the block cannot go red because the box was slow
    # between inserting a fixture and querying for it.
    @now ~U[2026-11-09 12:00:00.000000Z]
    @an_hour_ago ~U[2026-11-09 11:00:00.000000Z]
    @an_hour_ahead ~U[2026-11-09 13:00:00.000000Z]

    defp missed_slugs(opts) do
      opts |> Meetings.list_missed_meetings() |> Enum.map(& &1.slug)
    end

    test "a meeting intended an hour ago and never started is missed" do
      project = create_project()
      meeting = scheduled_meeting(project, "Standup", @an_hour_ago)

      assert meeting.status == "scheduled"
      assert is_nil(meeting.started_at)

      assert Meetings.missed?(meeting, @now)
      assert missed_slugs(project_id: project.id, now: @now) == ["standup"]
    end

    test "asking the question does not answer it: the row is still `scheduled` afterwards" do
      project = create_project()
      meeting = scheduled_meeting(project, "Standup", @an_hour_ago)

      assert Meetings.missed?(meeting, @now)
      assert missed_slugs(project_id: project.id, now: @now) == ["standup"]

      # Re-read from the database, not from the struct in hand — a predicate
      # that quietly wrote a "missed" status would still leave the original
      # struct saying "scheduled".
      reloaded = Meetings.get_meeting(meeting.id)
      assert reloaded.status == "scheduled"
      assert is_nil(reloaded.started_at)
      assert reloaded.scheduled_start_at == @an_hour_ago
      assert reloaded.status in Meeting.statuses()
    end

    test "starting it clears the miss: started_at is stamped and status is live" do
      project = create_project()
      meeting = scheduled_meeting(project, "Standup", @an_hour_ago)

      assert Meetings.missed?(meeting, @now)
      assert missed_slugs(project_id: project.id, now: @now) == ["standup"]

      assert {:ok, live} = Meetings.start_meeting(meeting)
      assert live.status == "live"
      assert %DateTime{} = live.started_at

      refute Meetings.missed?(live, @now)
      assert missed_slugs(project_id: project.id, now: @now) == []

      # Presence pair for the exclusion above: the row is still there, it is
      # just no longer missed.
      assert live.id in Enum.map(Meetings.list_all_meetings(), & &1.id)
    end

    test "an ad-hoc meeting with no intended time is never missed" do
      project = create_project()
      {:ok, ad_hoc} = Meetings.create_meeting(%{project_id: project.id, name: "Ad Hoc"})
      scheduled_meeting(project, "Standup", @an_hour_ago)

      # Presence half: the row exists and is exactly the shape claimed —
      # scheduled, unstarted, and with no intended time. Only the nil intent
      # separates it from the missed row.
      assert ad_hoc.scheduled_start_at == nil
      assert ad_hoc.status == "scheduled"
      assert is_nil(ad_hoc.started_at)
      assert ad_hoc.id in Enum.map(Meetings.list_all_meetings(), & &1.id)

      # Absence half.
      refute Meetings.missed?(ad_hoc, @now)
      assert missed_slugs(project_id: project.id, now: @now) == ["standup"]
    end

    test "a meeting intended an hour from now is upcoming, not missed" do
      project = create_project()
      future = scheduled_meeting(project, "Retro", @an_hour_ahead)
      scheduled_meeting(project, "Standup", @an_hour_ago)

      # Presence half: the future row is real, scheduled and unstarted. Its
      # ONLY difference from the missed row is which side of `now` its
      # intended time falls on.
      assert future.status == "scheduled"
      assert is_nil(future.started_at)
      assert future.scheduled_start_at == @an_hour_ahead
      assert future.id in Enum.map(Meetings.list_all_meetings(), & &1.id)

      # Absence half.
      refute Meetings.missed?(future, @now)
      assert missed_slugs(project_id: project.id, now: @now) == ["standup"]
    end

    test "a scheduled row that nonetheless carries a started_at is not missed" do
      project = create_project()
      meeting = scheduled_meeting(project, "Half Written", @an_hour_ago)

      # `start_meeting/1` flips the status and stamps `started_at` in ONE
      # update, so no application write produces this row. It is synthesized
      # here on purpose: without it the `is_nil(started_at)` clause of the
      # predicate is fully shadowed by the `status == "scheduled"` clause and
      # could be deleted with the suite staying green.
      {:ok, started} =
        meeting |> change(started_at: @an_hour_ago) |> Repo.update()

      assert started.status == "scheduled"
      assert %DateTime{} = started.started_at
      assert started.id in Enum.map(Meetings.list_all_meetings(), & &1.id)

      refute Meetings.missed?(started, @now)
      assert missed_slugs(project_id: project.id, now: @now) == []
    end

    test "a live row that nonetheless carries no started_at is not missed" do
      project = create_project()
      meeting = scheduled_meeting(project, "In The Room", @an_hour_ago)

      # The mirror image of the test above, and it exists for the same
      # reason. Measured: without it, deleting the `status == "scheduled"`
      # clause from BOTH `missed?/2` and `list_missed_meetings/1` leaves the
      # suite green — every other fixture that is non-scheduled is also
      # started, so `is_nil(started_at)` alone excludes it and clause 1 is
      # shadowed. Only a row that is non-scheduled and unstarted separates
      # them. `start_meeting/1` writes both in one update, so this row has to
      # be synthesized.
      {:ok, live} = meeting |> change(status: "live") |> Repo.update()

      assert live.status == "live"
      assert is_nil(live.started_at)
      assert live.scheduled_start_at == @an_hour_ago
      assert live.id in Enum.map(Meetings.list_all_meetings(), & &1.id)

      refute Meetings.missed?(live, @now)
      assert missed_slugs(project_id: project.id, now: @now) == []
    end

    test "orders by intended time, oldest miss first — not by creation order" do
      project = create_project()

      # Created Mid → Late → Early, so `asc: inserted_at` (["mid", "late",
      # "early"]), `desc: inserted_at` (["early", "late", "mid"]) and
      # `desc: scheduled_start_at` (["late", "mid", "early"]) each produce a
      # DIFFERENT list from the assertion. Two rows would only exclude one of
      # those three wrong answers.
      scheduled_meeting(project, "Mid", ~U[2026-11-09 10:00:00.000000Z])
      scheduled_meeting(project, "Late", ~U[2026-11-09 11:00:00.000000Z])
      scheduled_meeting(project, "Early", ~U[2026-11-09 09:00:00.000000Z])

      assert missed_slugs(project_id: project.id, now: @now) == ["early", "mid", "late"]
    end

    test "narrows to :project_id when given and spans projects when it is not" do
      a = create_project()
      b = create_project()

      scheduled_meeting(a, "Project A Missed", ~U[2026-11-09 09:00:00.000000Z])
      scheduled_meeting(b, "Project B Missed", ~U[2026-11-09 10:00:00.000000Z])

      assert missed_slugs(project_id: a.id, now: @now) == ["project-a-missed"]
      assert missed_slugs(project_id: b.id, now: @now) == ["project-b-missed"]

      unscoped = missed_slugs(now: @now)
      assert "project-a-missed" in unscoped
      assert "project-b-missed" in unscoped
    end

    test ":now defaults to the wall clock when it is not passed" do
      project = create_project()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      meeting = scheduled_meeting(project, "Defaulted", past)

      # The one case that exercises the defaults on both arities. Everything
      # else pins `now` explicitly.
      assert Meetings.missed?(meeting)
      assert meeting.slug in (Meetings.list_missed_meetings() |> Enum.map(& &1.slug))
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
