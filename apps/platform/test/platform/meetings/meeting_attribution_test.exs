defmodule Platform.Meetings.MeetingAttributionTest do
  @moduledoc """
  Task 01a04e9e — a transcript inheriting a meeting that was already over.

  ## What was measured on prod, 2026-08-29

  Space `01a04e11-…` had exactly one `meetings` row, ended 15:12:13Z. A
  transcript started at 22:34:49Z. `meeting_id_for_space/1` preferred a
  `live` row and then fell back to the most recently started one — so the
  new transcript was attributed to a meeting that had been over for two
  and a half hours, and four `brief_worthy` intents were dispatched
  carrying *"the meeting is waiting on you"* about a dead call.

  ## Why the fallback is NOT simply deleted

  It is load-bearing. A chunk can legitimately arrive after its meeting
  is marked ended, because the transcript is still draining, and that
  chunk belongs to the meeting that just finished. Removing the fallback
  would fix the misattribution by throwing away the last minute of every
  meeting.

  So the discriminator is *"did it end before this transcript began"*,
  not *"is it ended"* — and these tests are written so a fix that
  collapses the two fails. Every assertion below is paired: the drain
  case must still resolve, and the stale case must not.
  """
  use Platform.DataCase, async: true

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project

  defp project! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Attribution #{n}",
        slug: "attribution-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    project
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Attribution Space #{n}",
        slug: "attribution-space-#{n}",
        kind: "channel"
      })

    space
  end

  # A meeting bound to `space`, with an explicit lifecycle stamped
  # directly — `create_meeting/1` mints its own space, and these tests are
  # about a meeting sharing a space with a channel.
  defp meeting!(space, project, attrs) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      Map.merge(
        %Meeting{
          project_id: project.id,
          chat_space_id: space.id,
          slug: "attribution-meeting-#{n}",
          name: "Attribution Meeting #{n}",
          status: "ended",
          livekit_room_name: "meeting-attribution-#{n}"
        },
        attrs
      )
    )
  end

  describe "meeting_id_for_space/2" do
    # THE LOAD-BEARING PAIR. Same space, same ended meeting, two
    # transcripts — one that started while it was live, one that started
    # after it finished. A fix keyed on "is ended" gives the same answer
    # to both, and one of those answers is the prod incident.
    test "the drain case still resolves; the stale case does not" do
      space = space!()
      project = project!()

      started = ~U[2026-08-29 15:09:03.000000Z]
      ended = ~U[2026-08-29 15:12:13.000000Z]

      meeting = meeting!(space, project, %{status: "ended", started_at: started, ended_at: ended})

      # Draining: the transcript was already running when the meeting
      # ended, so this chunk belongs to it.
      mid_meeting = ~U[2026-08-29 15:10:00.000000Z]
      assert Meetings.meeting_id_for_space(space.id, mid_meeting) == meeting.id

      # Stale: the prod case, to the minute. The transcript did not exist
      # when this meeting was over.
      hours_later = ~U[2026-08-29 22:34:49.000000Z]
      assert Meetings.meeting_id_for_space(space.id, hours_later) == nil
    end

    # A live meeting has a NULL `ended_at`, and `NULL >= x` is neither
    # true nor false in SQL. A bound written without the is_nil branch
    # silently drops every live meeting — the opposite bug, and a worse
    # one.
    test "a live meeting is never filtered out by the bound" do
      space = space!()
      project = project!()

      live =
        meeting!(space, project, %{
          status: "live",
          started_at: ~U[2026-08-29 22:00:00.000000Z],
          ended_at: nil
        })

      assert Meetings.meeting_id_for_space(space.id, ~U[2026-08-29 22:34:49.000000Z]) == live.id
      assert Meetings.meeting_id_for_space(space.id, nil) == live.id
    end

    # The live row still wins over an ended one that also passes the
    # bound, so bounding did not disturb the ordering it sits on top of.
    test "a live meeting still beats an ended one that also qualifies" do
      space = space!()
      project = project!()

      _ended =
        meeting!(space, project, %{
          status: "ended",
          started_at: ~U[2026-08-29 22:10:00.000000Z],
          ended_at: ~U[2026-08-29 22:20:00.000000Z]
        })

      live =
        meeting!(space, project, %{
          status: "live",
          started_at: ~U[2026-08-29 22:05:00.000000Z],
          ended_at: nil
        })

      assert Meetings.meeting_id_for_space(space.id, ~U[2026-08-29 22:15:00.000000Z]) == live.id
    end

    # Omitting the bound must be byte-for-byte the old behaviour, so no
    # existing caller is silently tightened.
    test "with no bound, the unbounded fallback is unchanged" do
      space = space!()
      project = project!()

      stale =
        meeting!(space, project, %{
          status: "ended",
          started_at: ~U[2026-08-29 15:09:03.000000Z],
          ended_at: ~U[2026-08-29 15:12:13.000000Z]
        })

      assert Meetings.meeting_id_for_space(space.id) == stale.id
      assert Meetings.meeting_id_for_space(space.id, nil) == stale.id
    end

    # Task 01a1265f stage 2: THE REJOIN PAIR, beside #902's pair above.
    # Someone rejoins an ended meeting from its own page after it ended, so
    # the new transcript starts after `ended_at`. Resumed, the meeting is
    # live again and must be what that transcript is about. Not resumed
    # (any other way into the room), #902's bound must still refuse it.
    test "a resumed meeting owns a transcript that started after its original end" do
      space = space!()
      project = project!()

      started = ~U[2026-10-10 09:00:00.000000Z]
      ended = ~U[2026-10-10 09:30:00.000000Z]
      rejoined = ~U[2026-10-10 10:15:00.000000Z]

      meeting = meeting!(space, project, %{status: "ended", started_at: started, ended_at: ended})

      assert {:ok, resumed} = Meetings.resume_meeting(meeting)

      # The attribution first, so a resume that leaves `ended_at` set fails
      # HERE, on the property this task is about, not on the field check.
      assert Meetings.meeting_id_for_space(space.id, rejoined) == meeting.id

      assert resumed.status == "live"
      assert resumed.ended_at == nil
      assert resumed.started_at == started
    end

    test "control: the same rejoin WITHOUT a resume still resolves nil (#902)" do
      space = space!()
      project = project!()

      started = ~U[2026-10-10 09:00:00.000000Z]
      ended = ~U[2026-10-10 09:30:00.000000Z]
      rejoined = ~U[2026-10-10 10:15:00.000000Z]

      meeting = meeting!(space, project, %{status: "ended", started_at: started, ended_at: ended})

      assert Meetings.meeting_id_for_space(space.id, rejoined) == nil

      # And `start_meeting/2` is still not a way round it.
      assert {:error, %Ecto.Changeset{}} = Meetings.start_meeting(meeting)
      assert Repo.get!(Meeting, meeting.id).status == "ended"
      assert Meetings.meeting_id_for_space(space.id, rejoined) == nil
    end

    test "a space with no meeting answers nil either way" do
      space = space!()

      assert Meetings.meeting_id_for_space(space.id) == nil
      assert Meetings.meeting_id_for_space(space.id, DateTime.utc_now()) == nil
    end
  end
end
