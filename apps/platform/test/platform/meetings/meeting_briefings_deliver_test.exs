defmodule Platform.Meetings.MeetingBriefingsDeliverTest do
  @moduledoc """
  Durable readiness and bounded fallback delivery: no Inbox row on conclusion,
  one row and push after committed summary/full filing (or deadline), and no
  repeated push from callbacks, concurrent retries, or recovery sweeps.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox.Item
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Meetings.Transcript
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership

  defmodule Recorder do
    @moduledoc "Records `fan_out_to_user/3` as `{:notif, user_id, payload}`."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, user_id, payload})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      :persistent_term.erase({Recorder, :owner})
    end)

    :ok
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "deliver-#{n}@example.com",
        name: "Deliver #{n}",
        oidc_sub: "oidc-deliver-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  # A live meeting with a room, a canvas, and two attendees A and B present.
  defp live_meeting_with_attendees! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Deliver Project #{n}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Deliver #{n}"})

    {:ok, live} =
      meeting
      |> Meeting.status_changeset("live", %{
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Repo.update()

    room =
      %Room{}
      |> Room.changeset(%{
        space_id: live.chat_space_id,
        livekit_room_name: "space-#{live.chat_space_id}"
      })
      |> Repo.insert!()

    a = user!()
    b = user!()

    for {user, name} <- [{a, "A"}, {b, "B"}] do
      %Participant{}
      |> Participant.changeset(%{
        room_id: room.id,
        user_id: user.id,
        display_name: name,
        joined_at: DateTime.add(DateTime.utc_now(), -3000, :second)
      })
      |> Repo.insert!()
    end

    {:ok, chat_participant} =
      Chat.add_participant(live.chat_space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Scribe",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => live.chat_space_id,
        "created_by" => chat_participant.id,
        "title" => "Action items #{n}"
      })

    %{meeting: live, project: project, room: room, canvas: canvas, a: a, b: b}
  end

  defp rows_for(%User{id: user_id}) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id and i.kind == "meeting_briefing"))
  end

  defp briefing_count(%Meeting{id: id}) do
    Repo.aggregate(from(b in MeetingBriefing, where: b.meeting_id == ^id), :count)
  end

  defp file!(ctx, title) do
    {:ok, %{filed: [_]}} =
      Triage.file_tasks_from_canvas(ctx.canvas,
        project_id: ctx.project.id,
        meeting_id: ctx.meeting.id,
        action_items: [%{title: title}]
      )
  end

  defp ended!(ctx) do
    {:ok, ended} = Meetings.end_meeting(ctx.meeting)
    ended
  end

  defp ready!(meeting, attrs \\ []) do
    transcript =
      Repo.insert!(%Transcript{
        meeting_id: meeting.id,
        space_id: meeting.chat_space_id,
        room_id: meeting.livekit_room_name,
        status: "complete",
        summary: "Accepted summary",
        started_at: DateTime.add(meeting.ended_at, -10),
        completed_at: DateTime.utc_now(),
        segments: [%{"id" => Ecto.UUID.generate(), "text" => "Agreed work"}]
      })

    transcript =
      transcript
      |> Ecto.Changeset.change(summary_input_hash: Transcript.summary_fingerprint(transcript))
      |> Repo.update!()

    {:ok, snapshot, _} = Platform.Meetings.Completion.snapshot(meeting)
    run = Repo.get_by!(Platform.Meetings.CompletionRun, meeting_id: meeting.id)
    hash = Platform.Meetings.Completion.snapshot_hash(run, snapshot)

    run =
      run
      |> Ecto.Changeset.change(
        Keyword.merge(
          [
            capture_finished_at: DateTime.utc_now(),
            snapshot: snapshot,
            snapshot_hash: hash,
            transcript_id: transcript.id,
            status: "filed"
          ],
          attrs
        )
      )
      |> Repo.update!()

    {run, transcript}
  end

  test "end alone and a partial filing pass create no briefing, Inbox row or push" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    assert briefing_count(ended) == 0
    assert rows_for(ctx.a) == []
    refute_received {:notif, _, _}
    ready!(ended, status: "triage_pending", item_results: %{"one" => %{"status" => "processed"}})
    assert {:ok, :pending} = MeetingBriefings.deliver(ended)
    assert briefing_count(ended) == 0
    refute_received {:notif, _, _}
  end

  test "summary and full filed ledger deliver once to attendees only; retries never push" do
    ctx = live_meeting_with_attendees!()
    outsider = user!()
    file!(ctx, "Rotate the staging credentials")
    ended = ended!(ctx)
    ready!(ended)
    assert {:ok, %{created: 2, updated: 0}} = MeetingBriefings.deliver(ended)

    for user <- [ctx.a, ctx.b] do
      id = user.id
      assert [%Item{source_type: "meeting_briefing"}] = rows_for(user)
      assert_received {:notif, ^id, payload}
      assert payload.body == ended.name <> " · 1 item"
    end

    assert rows_for(outsider) == []
    assert {:ok, %{created: 0, updated: 2}} = MeetingBriefings.deliver(ended)
    refute_received {:notif, _, _}
    assert Repo.get_by!(MeetingBriefing, meeting_id: ended.id).summary == "Accepted summary"
  end

  test "filed run without summary stays pending until the summary is committed" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    {_run, transcript} = ready!(ended)
    transcript |> Ecto.Changeset.change(summary: nil) |> Repo.update!()
    assert {:ok, :pending} = MeetingBriefings.deliver(ended)
    assert rows_for(ctx.a) == []

    {:ok, _} =
      Meetings.complete_transcript(
        transcript.id,
        "Final summary",
        Transcript.summary_fingerprint(transcript)
      )

    assert length(rows_for(ctx.a)) == 1
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}
    MeetingBriefings.refresh_for_transcript(transcript)
    refute_received {:notif, _, _}
  end

  test "deadline sweeper recovers ended meetings without runs and filed runs missing summary" do
    for mode <- [:no_run, :filed] do
      ctx = live_meeting_with_attendees!()
      ended = ended!(ctx)

      if mode == :no_run do
        Repo.delete_all(
          from(r in Platform.Meetings.CompletionRun, where: r.meeting_id == ^ended.id)
        )
      else
        {_run, transcript} = ready!(ended)
        transcript |> Ecto.Changeset.change(summary: nil) |> Repo.update!()
      end

      before = DateTime.add(DateTime.utc_now(), -1190)
      ended = ended |> Ecto.Changeset.change(ended_at: before) |> Repo.update!()
      assert {:ok, :pending} = MeetingBriefings.deliver(ended)

      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

      Platform.Meetings.Completion.sweep()
      assert length(rows_for(ctx.a)) == 1
      assert_received {:notif, _, _}
      assert_received {:notif, _, _}
      Platform.Meetings.Completion.sweep()
      refute_received {:notif, _, _}
    end
  end

  test "late summary after timeout merges complete content without another row or push" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    {_run, transcript} = ready!(ended)
    transcript |> Ecto.Changeset.change(summary: nil) |> Repo.update!()

    ended =
      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

    assert {:ok, %{created: 2}} = MeetingBriefings.deliver(ended)
    [original] = rows_for(ctx.a)
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}

    assert {:ok, _} =
             Meetings.complete_transcript(
               transcript.id,
               "Late final summary",
               Transcript.summary_fingerprint(transcript)
             )

    assert [current] = rows_for(ctx.a)
    assert current.id == original.id
    assert Repo.get_by!(MeetingBriefing, meeting_id: ended.id).summary == "Late final summary"
    refute_received {:notif, _, _}
  end

  test "synthesis prerequisite survives reload and rejects callbacks from prior snapshot or reopen" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    {run, transcript} = ready!(ended)

    assert :ok =
             Platform.Meetings.Completion.synthesis_changed(
               ended.id,
               run.id,
               run.snapshot_hash,
               "pending"
             )

    assert {:ok, :pending} = MeetingBriefings.deliver(Repo.get!(Meeting, ended.id))
    assert rows_for(ctx.a) == []

    assert {:error, :stale_snapshot} =
             Platform.Meetings.Completion.synthesis_changed(ended.id, run.id, "old", "complete")

    assert :ok =
             Platform.Meetings.Completion.synthesis_changed(
               ended.id,
               run.id,
               run.snapshot_hash,
               "complete"
             )

    assert length(rows_for(ctx.a)) == 1
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}

    transcript
    |> Ecto.Changeset.change(
      segments: transcript.segments ++ [%{"id" => Ecto.UUID.generate(), "text" => "Late"}]
    )
    |> Repo.update!()

    assert {:error, :stale_snapshot} =
             Platform.Meetings.Completion.synthesis_changed(
               ended.id,
               run.id,
               run.snapshot_hash,
               "complete"
             )

    ended |> Ecto.Changeset.change(status: "live") |> Repo.update!()
    Platform.Meetings.Completion.reopened(ended.id)

    assert {:error, :stale_snapshot} =
             Platform.Meetings.Completion.synthesis_changed(
               ended.id,
               run.id,
               run.snapshot_hash,
               "complete"
             )

    refute_received {:notif, _, _}
  end

  test "shared-space transcript cannot refresh another meeting or supply its summary" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    ready!(ended)
    {:ok, other} = Meetings.create_meeting(%{project_id: ctx.project.id, name: "Other"})

    foreign =
      Repo.insert!(%Transcript{
        meeting_id: other.id,
        space_id: ended.chat_space_id,
        room_id: ended.livekit_room_name,
        status: "complete",
        summary: "FOREIGN",
        completed_at: DateTime.utc_now()
      })

    MeetingBriefings.refresh_for_transcript(foreign)
    assert rows_for(ctx.a) == []
    MeetingBriefings.deliver(ended)
    assert Repo.get_by!(MeetingBriefing, meeting_id: ended.id).summary == "Accepted summary"
  end

  test "concurrent ready callbacks and sweeps arbitrate a single row and push per attendee" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    ready!(ended)

    1..4
    |> Task.async_stream(fn _ -> MeetingBriefings.deliver(ended) end, ordered: false)
    |> Enum.each(fn {:ok, {:ok, counts}} -> assert counts.created in [0, 2] end)

    for user <- [ctx.a, ctx.b] do
      id = user.id
      assert length(rows_for(user)) == 1
      assert_received {:notif, ^id, _}
      refute_received {:notif, ^id, _}
    end
  end

  test "a ready delivery called inside a filing transaction waits until commit" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    ready!(ended)

    Repo.transaction(fn ->
      assert {:ok, :pending} = MeetingBriefings.deliver(ended)
      assert rows_for(ctx.a) == []
      refute_received {:notif, _, _}
    end)

    assert {:ok, %{created: 2}} = MeetingBriefings.deliver(ended)
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}
  end

  test "historical summaries without producer provenance wait for bounded fallback" do
    ctx = live_meeting_with_attendees!()
    ended = ended!(ctx)
    {_run, transcript} = ready!(ended)
    transcript |> Ecto.Changeset.change(summary_input_hash: nil) |> Repo.update!()
    assert {:ok, :pending} = MeetingBriefings.deliver(ended)
    assert "summary" in MeetingBriefings.readiness(ended).missing

    ended =
      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

    assert {:ok, %{created: 2}} = MeetingBriefings.deliver(ended)
  end

  test "live meetings never deliver" do
    assert MeetingBriefings.refresh_for_transcript(%Transcript{}) == :ok
    ctx = live_meeting_with_attendees!()
    assert MeetingBriefings.deliver(ctx.meeting) == {:error, :not_concluded}
    assert briefing_count(ctx.meeting) == 0
    refute_received {:notif, _, _}
  end
end
