defmodule PlatformWeb.MeetingPresenceEventsTest do
  @moduledoc """
  Task 01a1e82a stage 2: the server half of the in-call toasts and the
  full-load guard. The shell pushes `meeting_presence:toast` for a join, a
  leave (naming who is still in the room) and a host-ended meeting, answers
  the guard's explicit leave with the same leave the bar's Leave runs, and
  renders the call state plus the authenticated route list on
  `#meeting-presence`. Real space, live meeting, active room and participant
  rows throughout.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @event "meeting_presence:toast"

  setup %{conn: conn} do
    _ = start_supervised(MeetingState)

    user =
      Repo.insert!(%User{
        email: "presence_#{System.unique_integer([:positive])}@example.com",
        name: "Pat Example",
        oidc_sub: "oidc-presence-#{System.unique_integer([:positive])}",
        preferences: %{"first_run_goal" => "existing"}
      })

    acme = Tenancy.get_org_by_slug!("acme")
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: acme.id, role: "admin"})
    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Presence Project #{System.unique_integer([:positive])}",
        slug: "presence-project-#{System.unique_integer([:positive])}",
        org_id: acme.id
      })
      |> Repo.insert()

    {:ok, space} =
      Chat.create_space(%{
        name: "Weekly sync",
        slug: "presence-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, host_row} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Pat Example",
        joined_at: DateTime.utc_now()
      })

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        host_participant_id: host_row.id,
        slug: "weekly-sync-#{System.unique_integer([:positive])}",
        name: "Weekly sync",
        status: "live",
        started_at: DateTime.utc_now(),
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {:ok, me} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{user.id}", name: "Pat Example"})

    other = other_user!("Sam Example")

    {:ok, _} =
      Meetings.upsert_live_participant(room, %{identity: "user:#{other.id}", name: "Sam Example"})

    on_exit(fn -> MeetingState.broadcast_left(user.id) end)

    %{conn: conn, user: user, space: space, meeting: meeting, room: room, me: me}
  end

  defp other_user!(name) do
    Repo.insert!(%User{
      email: "presence_other_#{System.unique_integer([:positive])}@example.com",
      name: name,
      oidc_sub: "oidc-presence-other-#{System.unique_integer([:positive])}"
    })
  end

  defp join!(%{user: user, space: space, meeting: meeting}) do
    :ok = MeetingState.broadcast_joined(user.id, space.id, space.name, space.slug, meeting.slug)
  end

  defp left_at(participant), do: Repo.get!(Participant, participant.id).left_at

  test "a join pushes \"You joined\"; the restore-on-reconnect re-broadcast does not", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/tasks")

    join!(ctx)
    _ = render(view)

    assert_push_event(view, @event, %{
      kind: "joined",
      name: "Weekly sync",
      meeting_id: meeting_id,
      mic: true,
      camera: false
    })

    assert meeting_id == ctx.meeting.id

    join!(ctx)
    _ = render(view)
    refute_push_event(view, @event, %{kind: "joined"})
  end

  test "#meeting-presence carries the call state and the authenticated routes", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/tasks")

    assert has_element?(
             view,
             ~s(#meeting-presence[phx-hook="MeetingPresence"][data-call-active="false"])
           )

    join!(ctx)
    _ = render(view)

    assert has_element?(
             view,
             ~s(#meeting-presence[data-call-active="true"][data-meeting-id="#{ctx.meeting.id}"][data-meeting-name="Weekly sync"])
           )

    assert has_element?(
             view,
             ~s(#meeting-presence[data-return-path="/meetings/#{ctx.meeting.slug}"][data-call-room="false"])
           )

    assert has_element?(view, ~s(#meeting-presence[data-others-count="1"][data-can-end="true"]))

    [routes_json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#meeting-presence")
      |> LazyHTML.attribute("data-auth-routes")

    routes = Jason.decode!(routes_json)
    assert "/chat/:space_slug" in routes
    assert "/calendar" in routes
    assert "/meetings/:slug" in routes
    refute "/admin" in routes
    refute "/canvases/:id" in routes
    assert routes == PlatformWeb.MeetingPresenceEvents.auth_route_patterns()
  end

  test "the bar's Leave stamps left_at and pushes \"You left\" naming who is still in", ctx do
    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/calendar")
    _ = render(view)

    send(view.pid, :meeting_bar_leave)
    _ = render(view)

    refute is_nil(left_at(ctx.me))

    assert_push_event(view, @event, %{
      kind: "left",
      name: "Weekly sync",
      names: ["Sam Example"],
      count: 1,
      return_path: return_path
    })

    assert return_path == "/meetings/#{ctx.meeting.slug}"
    refute has_element?(view, "#meeting-top-bar")

    # Its own `:meeting_left` broadcast loops back; that is not a second leave.
    _ = render(view)
    refute_push_event(view, @event, %{kind: "left"})
  end

  test "a leave from another surface still says \"You left\"", ctx do
    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/inbox")
    _ = render(view)

    :ok = Meetings.leave_for_user(ctx.space.id, ctx.user.id)
    :ok = MeetingState.broadcast_left(ctx.user.id)
    _ = render(view)

    assert_push_event(view, @event, %{kind: "left", names: ["Sam Example"], count: 1})
  end

  test "the guard's explicit leave replies with the left payload and pushes nothing", ctx do
    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/calendar")
    _ = render(view)

    view |> element("#meeting-presence") |> render_hook("meeting_presence_leave", %{})

    assert_reply(view, %{
      left: %{kind: "left", name: "Weekly sync", names: ["Sam Example"], count: 1}
    })

    refute is_nil(left_at(ctx.me))
    assert is_nil(MeetingState.get_for_user(ctx.user.id))
    refute has_element?(view, "#meeting-top-bar")
    refute_push_event(view, @event, %{kind: "left"})
  end

  test "a host-ended meeting pushes \"<host> ended <name>\", leaves, and drops the bar", ctx do
    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
    _ = render(view)
    assert has_element?(view, "#meeting-top-bar")

    {:ok, _ended} = Meetings.end_meeting(ctx.meeting)
    _ = render(view)

    assert_push_event(view, @event, %{kind: "ended", host: "Pat Example", name: "Weekly sync"})
    refute_push_event(view, @event, %{kind: "left"})
    refute has_element?(view, "#meeting-top-bar")
    refute is_nil(left_at(ctx.me))
  end

  test "End for everyone ends the meeting for its host", ctx do
    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
    _ = render(view)

    view |> element("#meeting-presence") |> render_hook("meeting_presence_end", %{})
    _ = render(view)

    assert Repo.get!(Meeting, ctx.meeting.id).status == "ended"
    assert_push_event(view, @event, %{kind: "ended", name: "Weekly sync"})
  end

  test "End for everyone is refused for someone who is not the host", ctx do
    {:ok, _} =
      ctx.meeting
      |> Ecto.Changeset.change(host_participant_id: nil)
      |> Repo.update()

    join!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/tasks")
    _ = render(view)
    assert has_element?(view, ~s(#meeting-presence[data-can-end="false"]))

    view |> element("#meeting-presence") |> render_hook("meeting_presence_end", %{})
    _ = render(view)

    assert Repo.get!(Meeting, ctx.meeting.id).status == "live"
  end

  # CalendarLive takes the project topic itself; a second shell subscription
  # would hand it every lifecycle event twice.
  test "takes the project topic once, and never doubles a host's own", ctx do
    join!(ctx)
    topic = Meetings.project_meetings_topic(ctx.meeting.project_id)

    {:ok, tasks, _html} = live(ctx.conn, ~p"/tasks")
    _ = render(tasks)
    assert Platform.PubSub |> Registry.keys(tasks.pid) |> Enum.count(&(&1 == topic)) == 1

    {:ok, cal, _html} = live(ctx.conn, ~p"/calendar")
    _ = render(cal)
    assert Platform.PubSub |> Registry.keys(cal.pid) |> Enum.count(&(&1 == topic)) == 1
  end
end
