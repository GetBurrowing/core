defmodule PlatformWeb.MeetingLiveCompletionTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.{Chat, Federation, Meetings, Repo, Roles, Tasks}
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Meetings.{Completion, CompletionRun, Meeting, Participant, Room, Transcript}
  alias Platform.Meetings.State, as: MeetingState
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
    # `Meetings.State` is a node-wide ETS table; a joined row must not
    # outlive the test that wrote it.
    on_exit(fn -> MeetingState.broadcast_left(user.id) end)

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    {:ok, project} = Tasks.create_project(%{name: "Completion view #{n}", org_id: org_id})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Past call #{n}"})

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
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
    refute_push_event(view, "join-meeting", %{}, 50)

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

  # ── Explicit Join on ordinary visits (task 01a18d0a stage 2) ──────────
  #
  # The task: "An open meeting you navigate into also needs an explicit Join,
  # unless you arrived via an invite link or a ring that you accepted." The
  # normal connected URL is an ordinary visit for a scheduled meeting and for
  # a live one alike. These tests replace "scheduled meetings still auto-join
  # on the normal connected URL", which pinned the opposite.

  test "an ordinary visit to a scheduled meeting shows Join and connects nothing", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    assert_unjoined_visit!(view, ctx, "scheduled")

    # A bare `:auto_join` carries no intent of its own: stale, duplicate or
    # forged, it cannot join an ordinary visit.
    send(view.pid, :auto_join)
    send(view.pid, :auto_join)
    render(view)
    assert_unjoined_visit!(view, ctx, "scheduled")

    # Nor does a remount, nor an arbitrary query flag.
    GenServer.stop(view.pid)
    {:ok, remounted, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}?join=true&auto_join=1")
    assert_unjoined_visit!(remounted, ctx, "scheduled")
  end

  test "an ordinary visit to a live meeting shows Join and connects nothing", ctx do
    started_at = DateTime.add(DateTime.utc_now(), -60)

    ctx.meeting
    |> Ecto.Changeset.change(status: "live", started_at: started_at)
    |> Repo.update!()

    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    assert_unjoined_visit!(view, ctx, "live")

    send(view.pid, :auto_join)
    render(view)
    assert_unjoined_visit!(view, ctx, "live")
    assert Repo.get!(Meeting, ctx.meeting.id).started_at == started_at
  end

  test "Join connects once; duplicates add nothing and a remount restores the joined call",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    assert_unjoined_visit!(view, ctx, "scheduled")

    view |> element(~s([data-role="meeting-join"])) |> render_click()

    assert_push_event(view, "join-meeting", %{token: token, url: "wss://livekit.test"})
    assert is_binary(token)
    assert Repo.get!(Meeting, ctx.meeting.id).status == "live"
    assert :sys.get_state(view.pid).socket.assigns.in_meeting
    assert [%Participant{}] = active_participants(ctx)
    refute has_element?(view, ~s([data-role="meeting-join"]))

    # A queued restore on a joined socket pushes nothing more.
    send(view.pid, :auto_join)
    render(view)
    refute_push_event(view, "join-meeting", %{}, 50)

    # A duplicate Join event (a double tap that beat the re-render) re-pushes
    # the same room, which the client adopts; it writes no second room and
    # no second live participant row.
    render_click(view, "meeting_join", %{})
    assert_push_event(view, "join-meeting", %{room_name: room_name})

    assert [%Room{livekit_room_name: ^room_name}] =
             Repo.all(from(r in Room, where: r.space_id == ^ctx.meeting.chat_space_id))

    assert [%Participant{}] = active_participants(ctx)

    # A reconnect is a new LiveView process. The viewer joined and never
    # left, so the page re-adopts the call instead of asking again.
    GenServer.stop(view.pid)
    {:ok, reconnected, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    render(reconnected)

    assert_push_event(reconnected, "join-meeting", %{token: restored})
    assert is_binary(restored)
    assert :sys.get_state(reconnected.pid).socket.assigns.in_meeting
    refute_push_event(reconnected, "join-meeting", %{}, 50)
    assert [%Participant{}] = active_participants(ctx)
  end

  test "a restore queued before the viewer left does not rejoin them", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    view |> element(~s([data-role="meeting-join"])) |> render_click()
    assert_push_event(view, "join-meeting", %{})

    render_click(view, "meeting_leave", %{})
    refute :sys.get_state(view.pid).socket.assigns.in_meeting
    assert MeetingState.get_for_user(ctx.user.id) == nil

    send(view.pid, :auto_join)
    render(view)
    refute_push_event(view, "join-meeting", %{}, 50)
    refute :sys.get_state(view.pid).socket.assigns.in_meeting
    assert has_element?(view, ~s([data-role="meeting-join"]))

    # After a leave, the next visit is ordinary again.
    GenServer.stop(view.pid)
    {:ok, revisit, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    refute_push_event(revisit, "join-meeting", %{}, 50)
    assert has_element?(revisit, ~s([data-role="meeting-join"]))
  end

  # Task 01a18d0a stage 4 (review case 01a18d0d-ce1b-700c). The State row
  # alone is not proof of a call in progress: a browser closed without Leave
  # keeps it, while the LiveKit `participant_left` webhook retires the
  # participant row. A later bare visit must then show Join, not reconnect.
  test "a browser closed without Leave, then retired by the webhook, does not auto-join on revisit",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    view |> element(~s([data-role="meeting-join"])) |> render_click()
    assert_push_event(view, "join-meeting", %{room_name: room_name})
    assert [%Participant{}] = active_participants(ctx)

    # The tab closes: the LiveView dies with no `meeting_leave`/`meeting_left`,
    # so the State row survives.
    GenServer.stop(view.pid)
    space_id = ctx.meeting.chat_space_id
    assert %{space_id: ^space_id} = MeetingState.get_for_user(ctx.user.id)

    # ~30 s later LiveKit drops the participant and its webhook stamps
    # `left_at`, through the same call the webhook controller makes.
    room = Repo.get_by!(Room, livekit_room_name: room_name)

    assert {:ok, %Participant{left_at: %DateTime{}}} =
             Meetings.mark_live_participant_left(room, %{
               identity: "user:" <> ctx.user.id,
               name: "Completion Viewer",
               sid: "PA_closed_tab"
             })

    # A fresh context opens the bare URL with no click.
    {:ok, revisit, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    render(revisit)

    refute_push_event(revisit, "join-meeting", %{}, 50)
    refute :sys.get_state(revisit.pid).socket.assigns.in_meeting
    assert has_element?(revisit, ~s([data-role="meeting-join"]))
    assert active_participants(ctx) == []
    assert Repo.aggregate(from(p in Participant, where: p.room_id == ^room.id), :count) == 1
  end

  test "a reload while still in the call (participant row active) restores it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    view |> element(~s([data-role="meeting-join"])) |> render_click()
    assert_push_event(view, "join-meeting", %{})

    # The positive control for the test above: same State row, but the
    # participant row is still active (no webhook has retired it).
    GenServer.stop(view.pid)
    assert [%Participant{left_at: nil}] = active_participants(ctx)

    {:ok, reloaded, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    render(reloaded)

    assert_push_event(reloaded, "join-meeting", %{token: token})
    assert is_binary(token)
    assert :sys.get_state(reloaded.pid).socket.assigns.in_meeting
    assert [%Participant{}] = active_participants(ctx)
  end

  # Task 01a18d0a stage 4, round 2. A `?tab=` live patch re-enters
  # handle_params on the same pid. It used to re-run the whole room setup,
  # crash on `MeetingHooks.attach/2`'s already-attached hook, reload the
  # page and drop the viewer's LiveKit connection: a tab patch left the call.
  test "a ?tab= live patch while joined keeps the call on the same view", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    view |> element(~s([data-role="meeting-join"])) |> render_click()
    assert_push_event(view, "join-meeting", %{})

    # Baselines taken on the joined view. The join itself holds presence
    # too, so the count is whatever it is here; a patch must not add to it.
    space_id = ctx.meeting.chat_space_id
    presence = Platform.Meetings.PubSub.presence_topic(space_id)
    intents = Platform.Meetings.PubSub.intents_topic(ctx.meeting.id)
    presence_before = registrations(presence, view.pid)
    assert presence_before >= 1
    assert registrations(intents, view.pid) == 1

    html = render_patch(view, ~p"/meetings/#{ctx.meeting.slug}?tab=transcript")
    assert html =~ ~s(data-role="meeting-leave")

    assert Process.alive?(view.pid)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.in_meeting
    assert assigns.active_meeting_tab == "transcript"
    assert [%Participant{left_at: nil}] = active_participants(ctx)
    refute_push_event(view, "join-meeting", %{}, 50)

    # No extra registration on the raw PubSub topics the setup subscribes,
    # so a message broadcast after the patch reaches this view no more often
    # than before it.
    assert registrations(presence, view.pid) == presence_before
    assert registrations(intents, view.pid) == 1

    # A second patch is no different.
    render_patch(view, ~p"/meetings/#{ctx.meeting.slug}?tab=people")
    assert Process.alive?(view.pid)
    assert :sys.get_state(view.pid).socket.assigns.in_meeting
    assert registrations(presence, view.pid) == presence_before
    assert registrations(intents, view.pid) == 1
  end

  defp registrations(topic, pid) do
    Platform.PubSub |> Registry.lookup(topic) |> Enum.count(fn {p, _} -> p == pid end)
  end

  test "a call held in ANOTHER meeting does not join this one", ctx do
    {:ok, other} =
      Meetings.create_meeting(%{project_id: ctx.meeting.project_id, name: "Other call"})

    MeetingState.broadcast_joined(ctx.user.id, other.chat_space_id, "Other", nil, other.slug)

    {:ok, view, _} = live(ctx.conn, ~p"/meetings/#{ctx.meeting.slug}")
    assert_unjoined_visit!(view, ctx, "scheduled")
  end

  defp assert_unjoined_visit!(view, ctx, status) do
    render(view)
    assert has_element?(view, ~s([data-role="meeting-join"]))
    refute_push_event(view, "join-meeting", %{}, 50)
    refute :sys.get_state(view.pid).socket.assigns.in_meeting
    assert Repo.get!(Meeting, ctx.meeting.id).status == status
    assert Repo.get_by(Room, space_id: ctx.meeting.chat_space_id) == nil
    assert active_participants(ctx) == []
    assert Repo.all(from(r in CompletionRun, where: r.meeting_id == ^ctx.meeting.id)) == []

    assert Repo.all(from(t in Transcript, where: t.space_id == ^ctx.meeting.chat_space_id)) ==
             []

    space_id = ctx.meeting.chat_space_id
    refute match?(%{space_id: ^space_id}, MeetingState.get_for_user(ctx.user.id))
  end

  defp active_participants(ctx) do
    Repo.all(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.room_id,
        where:
          r.space_id == ^ctx.meeting.chat_space_id and p.user_id == ^ctx.user.id and
            is_nil(p.left_at)
      )
    )
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
