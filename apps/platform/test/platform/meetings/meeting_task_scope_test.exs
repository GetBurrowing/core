defmodule Platform.Meetings.MeetingTaskScopeTest do
  @moduledoc """
  `Platform.Meetings.meeting_task_scope/0` is the ONE rule for "which tasks
  belong to this meeting" (task 01a1694a stage 1). Three readers compose it:
  `Platform.Meetings.MeetingBriefings.build/1` (through
  `meeting_tasks_query/1`), `Platform.Meetings.Archive`'s action-item chip,
  and the archive's action-item search vector.

  Two kinds of test here:

    * **the earlier-meeting test** — a triage task filed during an earlier
      meeting E in a chat space that a later meeting L shares. The canvas
      arm's `started_at` lower bound is what keeps it off L. Asserted on the
      briefing AND the archive chip in one pass, with the positive control
      (present for E) in the same pass, and with deliberately asymmetric
      totals: E=1, L=1, where a pooled implementation shows 2 for each.
    * **the parity test** — for a fixture set that covers both arms, a
      soft-deleted task, a pre-start triage task, a never-started meeting
      and a task with no provenance, the query, the chip count and the
      search all agree, meeting by meeting and task by task.

  Every task is filed through the production filer
  (`Candidates.graduate/2` for the live arm,
  `Triage.file_tasks_from_canvas/2` for the canvas arm), so a change to
  what either path stamps reddens these tests rather than sliding past a
  fixture that froze the old shape.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp viewer_in_acme! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "task-scope-#{n}@example.com",
        name: "Task Scope Reader #{n}",
        oidc_sub: "oidc-task-scope-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp meeting_fixture!(name) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Task Scope Project #{n}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    %{meeting: meeting, project: project, canvas: canvas!(meeting)}
  end

  defp canvas!(%Meeting{} = meeting) do
    n = System.unique_integer([:positive])

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Scribe",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => meeting.chat_space_id,
        "created_by" => participant.id,
        "title" => "Action items #{n}"
      })

    canvas
  end

  # Two meetings in one chat space: only fixtures produce this today
  # (`Meetings.create_meeting/1` makes a new space per meeting), which is
  # exactly why it is the case the bound has to be proved on.
  defp share_space!(%Meeting{} = meeting, %Meeting{} = with_meeting) do
    meeting
    |> Ecto.Changeset.change(chat_space_id: with_meeting.chat_space_id)
    |> Repo.update!()
  end

  defp run_meeting!(%Meeting{} = meeting, started_at, ended_at) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: started_at}) |> Repo.update()

    {:ok, ended} =
      live |> Meeting.status_changeset("ended", %{ended_at: ended_at}) |> Repo.update()

    ended
  end

  # Historical live-minted task fixture; live code must no longer create it.
  defp graduate!(meeting, quote) do
    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: meeting.project_id,
        title: quote,
        metadata: %{
          "source" => "meetings.candidate",
          "meeting_id" => meeting.id,
          "candidate_id" => Ecto.UUID.generate()
        }
      })

    task
  end

  defp file!(canvas, project, title) do
    {:ok, %{filed: [%TaskRecord{} = task]}} =
      Triage.file_tasks_from_canvas(canvas,
        project_id: project.id,
        action_items: [%{title: title}]
      )

    task
  end

  # `inserted_at` is the axis the canvas arm's bound turns on, and the
  # filer stamps `now`; the tests move it to the instant they need.
  defp inserted_at!(%TaskRecord{id: id} = task, at) do
    {1, _} = Repo.update_all(from(t in TaskRecord, where: t.id == ^id), set: [inserted_at: at])
    %{task | inserted_at: at}
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp chip_count(artifacts, %Meeting{id: id}) do
    artifacts
    |> Map.fetch!(id)
    |> Map.fetch!(:chips)
    |> Enum.find(&(&1.type == :action_items))
    |> case do
      nil -> 0
      chip -> chip.count
    end
  end

  defp query_ids(%Meeting{} = meeting) do
    meeting
    |> Meetings.meeting_tasks_query()
    |> select([task: t], t.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp briefing_task_refs(%Meeting{} = meeting) do
    {:ok, briefing, _delta} = MeetingBriefings.build(meeting)

    briefing.items
    |> Map.delete(MeetingBriefings.content_key())
    |> Map.values()
    |> Enum.filter(&(&1["kind"] == "task"))
    |> MapSet.new(& &1["ref"])
  end

  # ── The earlier-meeting test ──────────────────────────────────────────────

  describe "a triage task filed during an earlier meeting in a shared space" do
    # One fixture, two tests: the briefing and the archive are asserted in
    # SEPARATE tests so that a regression in the shared rule reddens both,
    # each on its own, rather than the first failed assertion hiding the
    # second reader's verdict.
    #
    # E ran 180..120 minutes ago and L 60..30 minutes ago, in ONE chat space.
    # The triage task was filed during E, before L started. L also has one
    # live-path task of its own.
    setup do
      %{meeting: earlier, project: project, canvas: canvas} = meeting_fixture!("Earlier sync")
      %{meeting: later} = meeting_fixture!("Later sync")
      later = share_space!(later, earlier)
      assert later.chat_space_id == earlier.chat_space_id

      triaged =
        canvas |> file!(project, "Rotate the staging credentials") |> inserted_at!(ago(150))

      live_on_later = graduate!(later, "somebody should renew the wildcard certificate")

      %{
        earlier: run_meeting!(earlier, ago(180), ago(120)),
        later: run_meeting!(later, ago(60), ago(30)),
        triaged: triaged,
        live_on_later: live_on_later
      }
    end

    test "the briefing credits it to the earlier meeting only", ctx do
      earlier_refs = briefing_task_refs(ctx.earlier)
      later_refs = briefing_task_refs(ctx.later)

      # Positive control, same pass: the task IS reachable by this reader.
      assert ("task:" <> ctx.triaged.id) in earlier_refs

      refute ("task:" <> ctx.triaged.id) in later_refs,
             "the briefing credited a later meeting with a task filed before it started"

      # Asymmetric totals: E has only the triage task, L only its live task.
      # A pooled implementation reports both tasks for each.
      assert earlier_refs == MapSet.new(["task:" <> ctx.triaged.id])
      assert later_refs == MapSet.new(["task:" <> ctx.live_on_later.id])
    end

    test "the archive chip credits it to the earlier meeting only", ctx do
      artifacts = Archive.artifacts_for(viewer_in_acme!(), [ctx.earlier, ctx.later])

      # E=1 is the positive control; a pooled implementation shows 2 and 2.
      assert {chip_count(artifacts, ctx.earlier), chip_count(artifacts, ctx.later)} == {1, 1},
             "the archive chip credited a later meeting with a task filed before it started"
    end
  end

  # ── Parity ────────────────────────────────────────────────────────────────

  describe "the query, the archive chip and the archive search agree" do
    test "meeting by meeting and task by task" do
      viewer = viewer_in_acme!()

      %{meeting: m1, project: p1, canvas: c1} = meeting_fixture!("Parity one")
      %{meeting: m2} = meeting_fixture!("Parity two")
      %{meeting: m3, project: p3, canvas: c3} = meeting_fixture!("Parity three")

      live_m1 = graduate!(m1, "somebody should decommission the zeppelin fleet")
      deleted_m1 = graduate!(m1, "somebody should repaint the narwhal mural")
      triage_m1 = file!(c1, p1, "Audit the axolotl tank")

      # Filed in M1's space before M1 started.
      pre_start_m1 = c1 |> file!(p1, "Feed the pangolin colony") |> inserted_at!(ago(300))

      live_m2 = graduate!(m2, "we should migrate the quokka database")

      # M3 never starts: it is cancelled, so its triage task has no window.
      never_started_m3 = file!(c3, p3, "Groom the capybara herd")

      {:ok, no_provenance} =
        Tasks.create_task(%{
          project_id: p1.id,
          title: "Polish the wombat badge",
          status: "backlog"
        })

      deleted_m1
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      m1 = run_meeting!(m1, ago(120), ago(60))
      m2 = run_meeting!(m2, ago(120), ago(60))

      {:ok, m3} =
        m3
        |> Meeting.status_changeset("cancelled", %{cancelled_at: DateTime.utc_now()})
        |> Repo.update()

      meetings = [m1, m2, m3]
      by_meeting = Map.new(meetings, &{&1.id, query_ids(&1)})

      # The rule's verdicts, stated outright so parity cannot hold vacuously
      # on an empty fixture.
      assert by_meeting[m1.id] == MapSet.new([live_m1.id, triage_m1.id])
      assert by_meeting[m2.id] == MapSet.new([live_m2.id])
      assert by_meeting[m3.id] == MapSet.new()

      artifacts = Archive.artifacts_for(viewer, meetings)

      for meeting <- meetings do
        assert chip_count(artifacts, meeting) == MapSet.size(by_meeting[meeting.id]),
               "chip count disagrees with meeting_tasks_query/1 for #{meeting.name}"
      end

      meeting_ids = MapSet.new(meetings, & &1.id)

      for {task, term} <- [
            {live_m1, "zeppelin"},
            {deleted_m1, "narwhal"},
            {triage_m1, "axolotl"},
            {pre_start_m1, "pangolin"},
            {live_m2, "quokka"},
            {never_started_m3, "capybara"},
            {no_provenance, "wombat"}
          ] do
        attributed =
          for {id, ids} <- by_meeting, MapSet.member?(ids, task.id), into: MapSet.new(), do: id

        matched =
          viewer
          |> Archive.search(query: term, types: [:action_items])
          |> Map.fetch!(:matches)
          |> MapSet.new(& &1.id)
          |> MapSet.intersection(meeting_ids)

        assert matched == attributed,
               "search for #{inspect(term)} matched #{inspect(MapSet.to_list(matched))}, " <>
                 "the query attributes it to #{inspect(MapSet.to_list(attributed))}"
      end
    end
  end
end
