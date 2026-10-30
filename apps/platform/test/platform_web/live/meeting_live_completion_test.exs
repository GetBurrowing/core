defmodule PlatformWeb.MeetingLiveCompletionTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Federation, Meetings, Repo, Roles, Tasks}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Meetings.{Completion, CompletionRun, Meeting, Transcript}
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.acme_org_id()
    user = user!("viewer-#{n}")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    {:ok, project} = Tasks.create_project(%{name: "Completion view #{n}", org_id: org_id})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Past call #{n}"})

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      meeting: meeting,
      scribe: role_agent!("meeting_scribe", n),
      triage: role_agent!("triage_officer", n)
    }
  end

  test "normal connected views and repeated auto-join preserve a genuinely filed run", ctx do
    {meeting, filed} = file_completion!(ctx)
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{meeting.slug}")
    assert_preserved!(meeting, filed)
    assert has_element?(view, ~s([data-role="meeting-join"]))

    # Exercise the handler independently of the mount scheduler guard.
    send(view.pid, :auto_join)
    send(view.pid, :auto_join)
    render(view)
    assert_preserved!(meeting, filed)

    # A new connected navigation models reconnect/remount without no_autojoin.
    GenServer.stop(view.pid)
    {:ok, reconnected, _} = live(ctx.conn, ~p"/meetings/#{meeting.slug}")
    render(reconnected)
    assert has_element?(reconnected, ~s([data-role="meeting-join"]))
    assert_preserved!(meeting, filed)

    # Even the next room-finished notification cannot re-dispatch this run.
    Completion.capture_finished_for_space(meeting.chat_space_id)
    persisted = Repo.get!(CompletionRun, filed.id)
    assert persisted.status == "filed"
    assert persisted.generation == filed.generation
    assert persisted.snapshot_hash == filed.snapshot_hash

    refute_receive %Phoenix.Socket.Broadcast{
                     payload: %{signal: %{reason: "meeting_scribe_completion"}}
                   },
                   100
  end

  test "explicit Join still resumes an ended meeting and joins its call", ctx do
    {meeting, filed} = file_completion!(ctx)
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{meeting.slug}")
    assert Repo.get!(Meeting, meeting.id).status == "ended"

    view |> element(~s([data-role="meeting-join"])) |> render_click()

    assert_push_event(view, "join-meeting", %{token: token, url: "wss://livekit.test"})
    assert is_binary(token)
    assert Repo.get!(Meeting, meeting.id).status == "live"
    # Joining a room without capture input must not invalidate completed work.
    assert Repo.get!(CompletionRun, filed.id) == filed
  end

  test "scheduled meetings still auto-join on the normal connected URL", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    render(view)
    assert Repo.get!(Meeting, ctx.meeting.id).status == "live"
    assert_push_event(view, "join-meeting", %{token: token, url: "wss://livekit.test"})
    assert is_binary(token)
  end

  defp assert_preserved!(meeting, filed) do
    assert Repo.get!(Meeting, meeting.id).status == "ended"
    persisted = Repo.get!(CompletionRun, filed.id)
    assert persisted.status == "filed"
    assert persisted.generation == filed.generation
    assert persisted.snapshot_hash == filed.snapshot_hash
    assert persisted.capture_finished_at == filed.capture_finished_at
  end

  defp file_completion!(ctx) do
    live =
      ctx.meeting
      |> Ecto.Changeset.change(status: "live", started_at: DateTime.add(DateTime.utc_now(), -60))
      |> Repo.update!()

    transcript =
      Repo.insert!(%Transcript{
        space_id: live.chat_space_id,
        room_id: live.livekit_room_name,
        started_at: DateTime.add(DateTime.utc_now(), -30),
        status: "processing",
        segments: [
          %{"id" => Ecto.UUID.generate(), "text" => "We agreed to follow up.", "start_time" => 1}
        ]
      })

    {:ok, ended} = Meetings.end_meeting(live)
    Completion.capture_finished_for_space(live.chat_space_id)

    {:ok, _} =
      Meetings.complete_transcript(
        transcript.id,
        "Follow up agreed",
        Transcript.summary_fingerprint(transcript)
      )

    assert_receive %Phoenix.Socket.Broadcast{
      payload: %{signal: %{reason: "meeting_scribe_completion"}}
    }

    run = Repo.get_by!(CompletionRun, meeting_id: live.id)
    {:ok, participant} = Chat.add_agent_participant(live.chat_space_id, ctx.scribe.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => live.chat_space_id,
        "created_by" => participant.id,
        "title" => "Completed call"
      })

    args = %{
      "meeting_id" => live.id,
      "run_id" => run.id,
      "transcript_id" => run.transcript_id,
      "snapshot_hash" => run.snapshot_hash,
      "canvas_id" => canvas.id
    }

    assert {:ok, %{status: "triage_dispatched"}} = Completion.scribe_complete(ctx.scribe.id, args)

    assert {:ok, %{status: "filed"}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", []))

    filed = Repo.get!(CompletionRun, run.id)
    assert is_binary(filed.snapshot_hash)
    assert %DateTime{} = filed.capture_finished_at
    {ended, filed}
  end

  defp role_agent!(role, n) do
    agent = Repo.insert!(%Agent{slug: "view-#{role}-#{n}", name: role, status: "active"})
    owner = user!("#{role}-#{n}")
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "view-#{role}-#{n}"})
    {:ok, _} = Federation.link_agent(runtime, agent)
    :ok = Roles.unassign_role(role)
    {:ok, _} = Roles.assign_role(role, agent.id)
    PlatformWeb.Endpoint.subscribe("runtime:view-#{role}-#{n}")
    agent
  end

  defp user!(suffix) do
    Repo.insert!(%User{
      email: "completion-view-#{suffix}@example.com",
      name: "Completion Viewer",
      oidc_sub: "completion-view-#{suffix}"
    })
  end
end
