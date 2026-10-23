defmodule Platform.Meetings.MeetingBriefingsDeliverTest do
  @moduledoc """
  `Platform.Meetings.MeetingBriefings.deliver/1` and its three triggers (task
  01a1694a stage 2): one Inbox row per attendee on conclusion, one push per
  attendee per meeting, and later merges (summary, triage filings) that
  never push again.

  Push is observed through a Recorder double injected via
  `:notifications_module` (the real `fan_out_to_user/3` short-circuits in
  :test env); `async: false` because that is app env.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
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

  # ── Conclusion ────────────────────────────────────────────────────────────

  test "end_meeting/1 with two attendees: one briefing, one Inbox row and one push each" do
    ctx = live_meeting_with_attendees!()
    non_attendee = user!()

    file!(ctx, "Rotate the staging credentials")
    refute_received {:notif, _, _}, "a live meeting must not deliver"

    assert {:ok, %Meeting{status: "ended"} = ended} = Meetings.end_meeting(ctx.meeting)

    assert briefing_count(ended) == 1

    for user <- [ctx.a, ctx.b] do
      assert [%Item{} = row] = rows_for(user)
      assert row.source_type == "meeting_briefing"
      assert row.title == ended.name
      assert row.url == "/inbox/meeting/" <> ended.id
      assert is_nil(row.read_at) and is_nil(row.dismissed_at)

      user_id = user.id
      assert_received {:notif, ^user_id, payload}
      assert payload.kind == "meeting_briefing"
      assert payload.url == "/inbox/meeting/" <> ended.id
      assert payload.body == ended.name <> " · 1 item"
      refute_received {:notif, ^user_id, _}
    end

    # The non-attendee got nothing, asserted alongside the two who did.
    assert rows_for(non_attendee) == []
    non_attendee_id = non_attendee.id
    refute_received {:notif, ^non_attendee_id, _}
  end

  test "re-running deliver/1 writes no extra rows and sends no second push" do
    ctx = live_meeting_with_attendees!()
    {:ok, ended} = Meetings.end_meeting(ctx.meeting)

    a_id = ctx.a.id
    b_id = ctx.b.id
    assert_received {:notif, ^a_id, _}
    assert_received {:notif, ^b_id, _}

    assert {:ok, %{created: 0, updated: 2}} = MeetingBriefings.deliver(ended)
    assert {:ok, %{created: 0, updated: 2}} = MeetingBriefings.deliver(ended)

    refute_received {:notif, _, _}
    assert briefing_count(ended) == 1
    assert length(rows_for(ctx.a)) == 1
    assert length(rows_for(ctx.b)) == 1
  end

  test "a task filed after conclusion re-marks the row unread, with no push" do
    ctx = live_meeting_with_attendees!()
    {:ok, _ended} = Meetings.end_meeting(ctx.meeting)
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}

    [row] = rows_for(ctx.a)
    {:ok, _} = Inbox.mark_dismissed(row.id, ctx.a.id)
    assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, row.id)

    # A refresh that adds nothing leaves the dismissal alone.
    {:ok, %{updated: 2}} = MeetingBriefings.deliver(ctx.meeting)
    assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, row.id)

    # Triage with the meeting named is the third trigger.
    file!(ctx, "Draft the rollback runbook")

    relisted = Repo.get!(Item, row.id)
    assert is_nil(relisted.dismissed_at) and is_nil(relisted.read_at)
    assert rows_for(ctx.a) |> length() == 1
    refute_received {:notif, _, _}
  end

  test "complete_transcript/2 merges the summary with no push" do
    ctx = live_meeting_with_attendees!()

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        room_id: "space-#{ctx.meeting.chat_space_id}",
        space_id: ctx.meeting.chat_space_id,
        status: "processing"
      })
      |> Repo.insert!()

    {:ok, ended} = Meetings.end_meeting(ctx.meeting)
    assert_received {:notif, _, _}
    assert_received {:notif, _, _}

    assert Repo.get_by!(MeetingBriefing, meeting_id: ended.id).summary == nil

    assert {:ok, _} =
             Meetings.complete_transcript(transcript.id, "We agreed on the bucket policy.")

    briefing = Repo.get_by!(MeetingBriefing, meeting_id: ended.id)
    assert briefing.summary == "We agreed on the bucket policy."
    assert briefing.transcript_id == transcript.id
    refute_received {:notif, _, _}
  end

  test "one of two participants leaving creates no briefing" do
    ctx = live_meeting_with_attendees!()

    assert {:ok, %Participant{left_at: %DateTime{}}} = Meetings.participant_left(ctx.room, "A")

    assert briefing_count(ctx.meeting) == 0
    assert rows_for(ctx.a) == [] and rows_for(ctx.b) == []
    refute_received {:notif, _, _}

    # Positive control: conclusion does deliver, to both — A left early but
    # attended.
    {:ok, ended} = Meetings.end_meeting(ctx.meeting)
    assert briefing_count(ended) == 1
    assert length(rows_for(ctx.a)) == 1
  end

  test "a raising deliver/1 still lets end_meeting/1 return {:ok, meeting}" do
    ctx = live_meeting_with_attendees!()

    # A briefing row whose `items` is a JSON array cannot load into the
    # schema's `:map` field, so `build/1` raises when it reads the row.
    Repo.query!(
      """
      INSERT INTO meeting_briefings (id, meeting_id, attendee_user_ids, items, receipts, inserted_at, updated_at)
      VALUES ($1, $2, '{}', '[1]'::jsonb, '{}'::jsonb, now(), now())
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(ctx.meeting.id)]
    )

    assert {:ok, %Meeting{status: "ended"} = ended} = Meetings.end_meeting(ctx.meeting)
    assert Repo.get!(Meeting, ctx.meeting.id).status == "ended"
    assert rows_for(ctx.a) == []

    # Positive control: deliver/1 on this meeting really does raise, so the
    # `{:ok, _}` above is end_meeting/1 surviving it, not a quiet no-op.
    raised =
      try do
        MeetingBriefings.deliver(ended)
        nil
      rescue
        error -> error
      end

    assert is_exception(raised)
  end

  test "deliver/1 on a meeting that is not ended writes nothing" do
    ctx = live_meeting_with_attendees!()

    assert MeetingBriefings.deliver(ctx.meeting) == {:error, :not_concluded}
    assert briefing_count(ctx.meeting) == 0
    refute_received {:notif, _, _}
  end
end
