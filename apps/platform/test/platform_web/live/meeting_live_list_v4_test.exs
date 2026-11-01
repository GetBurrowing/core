defmodule PlatformWeb.MeetingLiveListV4Test do
  @moduledoc """
  The `/meetings` list view rebuilt to prototype 01a178d2 v4 (task 01a18d9f
  stage 4): three sections of meeting cards, the detail pane / pushed phone
  detail, the past-meeting record tabs and the `+ New meeting` modal.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.Repo

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "meetings-v4-#{n}@example.com",
        name: "Meetings viewer",
        oidc_sub: "meetings-v4-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    {:ok, project} =
      %Platform.Tasks.Project{}
      |> Platform.Tasks.Project.changeset(%{
        name: "Meetings v4 #{n}",
        slug: "meetings-v4-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    conn =
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => "Etc/UTC"})

    %{conn: conn, user: user, project: project}
  end

  defp meeting!(project, name, status, start, minutes, people \\ []) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Platform.Chat.create_space(%{name: "design-#{n}", slug: "mt-v4-#{n}", kind: "channel"})

    participants =
      for person <- people do
        {:ok, p} =
          Platform.Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: Ecto.UUID.generate(),
            display_name: person,
            joined_at: DateTime.utc_now()
          })

        p
      end

    id = Platform.Types.UUIDv7.generate()

    %Platform.Meetings.Meeting{id: id}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "mt-v4-#{n}",
      name: name,
      livekit_room_name: "meeting-#{id}",
      status: status,
      scheduled_start_at: start,
      scheduled_end_at: DateTime.add(start, minutes * 60)
    })
    |> Ecto.Changeset.put_change(
      :host_participant_id,
      participants |> List.first() |> then(&(&1 && &1.id))
    )
    |> Repo.insert!()
    |> then(&{&1, space})
  end

  defp at(days, hour) do
    Date.utc_today() |> Date.add(days) |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  test "three sections of v4 meeting cards and the empty-detail copy", %{
    conn: conn,
    project: project
  } do
    {live, space} = meeting!(project, "Design call", "live", at(0, 10), 45, ["Ada", "Grace"])
    {upcoming, _} = meeting!(project, "Standup", "scheduled", at(1, 9), 15)
    {past, _} = meeting!(project, "Retro", "ended", at(-2, 15), 60)

    Repo.insert!(%Platform.Meetings.Transcript{
      room_id: "room-#{past.id}",
      meeting_id: past.id,
      status: "complete",
      summary: "We agreed the next milestone.",
      segments: [%{"speaker_name" => "Ada", "text" => "Let's review progress."}]
    })

    {:ok, view, _} = live(conn, "/meetings")

    for label <- ["Live now", "Upcoming", "Past"],
        do: assert(has_element?(view, ".mt-section-label", label))

    row = "[data-role=workspace-meeting][data-meeting-id='#{live.id}']"
    assert has_element?(view, row <> " .mt-kind", "#" <> space.name)
    assert has_element?(view, row <> " .cal-pill-ok", "Live")
    assert has_element?(view, row <> " strong", "Design call")

    assert has_element?(
             view,
             row,
             Elixir.Calendar.strftime(at(0, 10), "%a %-d %b") <> " · 10:00–10:45"
           )

    assert has_element?(view, row <> " small", "Ada, Grace")
    assert has_element?(view, "[data-meeting-id='#{upcoming.id}']", "Standup")
    assert has_element?(view, "[data-meeting-id='#{past.id}'] small", "Summary · Transcript")
    assert has_element?(view, "[data-role=meetings-detail] h2", "Your meeting spaces")

    assert has_element?(
             view,
             "[data-role=meetings-detail]",
             "Select a live, upcoming, or past meeting."
           )

    assert has_element?(view, "[data-role=list-new-meeting]", "+ New meeting")
    refute has_element?(view, "[data-role=start-meeting-fab]")
  end

  test "a scheduled meeting whose window has closed is listed under Past", %{
    conn: conn,
    project: project
  } do
    {lapsed, _} = meeting!(project, "Missed sync", "scheduled", at(-3, 9), 30)
    {:ok, view, _} = live(conn, "/meetings")
    assert has_element?(view, "[data-section=ended] [data-meeting-id='#{lapsed.id}']")
    refute has_element?(view, "[data-section=upcoming] [data-meeting-id='#{lapsed.id}']")
  end

  test "selecting rows shows the live, upcoming and past details", %{conn: conn, project: project} do
    {live, space} = meeting!(project, "Design call", "live", at(0, 10), 45, ["Ada", "Grace"])
    {upcoming, _} = meeting!(project, "Standup", "scheduled", at(1, 9), 15)
    {past, _} = meeting!(project, "Retro", "ended", at(-2, 15), 60)

    Repo.insert!(%Platform.Meetings.Transcript{
      room_id: "room-#{past.id}",
      meeting_id: past.id,
      status: "complete",
      summary: "We agreed the next milestone.",
      segments: [%{"speaker_name" => "Ada", "text" => "Let's review progress."}]
    })

    {:ok, view, _} = live(conn, "/meetings")
    view |> element("[data-meeting-id='#{live.id}']") |> render_click()
    assert_patch(view, "/meetings?meeting=#{live.id}")
    assert has_element?(view, "[data-meeting-id='#{live.id}'][aria-current=true]")
    detail = "[data-role=meetings-detail]"
    assert has_element?(view, detail <> " .mt-kind", "Live now · #" <> space.name)
    assert has_element?(view, detail <> " h2", "Design call")
    assert has_element?(view, detail, "· Etc/UTC")
    assert has_element?(view, detail <> " .cal-panel", "Ada, Grace")
    assert has_element?(view, detail <> " .cal-panel", "Hosted by Ada")
    assert has_element?(view, detail <> " a[href='/meetings/#{live.slug}']", "Join now")
    assert has_element?(view, detail <> " a", "View in Calendar")
    assert has_element?(view, detail, "Use this room for the conversation.")
    # The phone's pushed detail has its back button.
    assert has_element?(view, "[data-role=meetings-back]", "‹ Meetings")

    {:ok, view, _} = live(conn, "/meetings?meeting=#{upcoming.id}")
    assert has_element?(view, detail <> " .mt-kind", "Upcoming · #")

    assert has_element?(
             view,
             detail <> " a[href='/meetings/#{upcoming.slug}']",
             "Open meeting room"
           )

    {:ok, view, _} = live(conn, "/meetings?meeting=#{past.id}")
    assert has_element?(view, detail <> " .mt-kind", "Past · #")
    refute has_element?(view, detail <> " a", "Join now")
    assert has_element?(view, detail <> " [role=tabpanel]", "We agreed the next milestone.")
    view |> element(detail <> " button[role=tab]", "Recording") |> render_click()

    assert has_element?(
             view,
             detail <> " [role=tabpanel]",
             "No recording was saved for this meeting."
           )

    view |> element(detail <> " button[role=tab]", "Transcript") |> render_click()
    assert has_element?(view, detail <> " [role=tabpanel]", "Let's review progress.")

    view |> element("[data-role=meetings-back]") |> render_click()
    assert_patch(view, "/meetings")
    assert has_element?(view, detail <> " h2", "Your meeting spaces")
  end

  test "a past meeting with no records says so on every tab", %{conn: conn, project: project} do
    {past, _} = meeting!(project, "Quiet retro", "ended", at(-1, 15), 30)
    {:ok, view, _} = live(conn, "/meetings?meeting=#{past.id}")
    panel = "[data-role=meetings-detail] [role=tabpanel]"
    assert has_element?(view, panel, "No summary was saved for this meeting.")
    render_click(view, "meetings_list_tab", %{"tab" => "transcript"})
    assert has_element?(view, panel, "No transcript was saved for this meeting.")
  end

  test "+ New meeting opens the v4 modal and starts a room", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, "/meetings")
    view |> element("[data-role=list-new-meeting]") |> render_click()
    assert has_element?(view, "#meetings-new-room-title", "New meeting")
    assert has_element?(view, "input[name=title][placeholder='Team catch-up']")
    assert has_element?(view, "select[name=project_id] option[value='#{project.id}']")

    assert view |> element("[data-role=meetings-new-room] [data-role=new-room-hint]") |> render() =~
             "Start a room now, or schedule one from Calendar → New → Meeting."

    refute render(view) =~ "Use Calendar to schedule a future meeting."

    view |> form("#meetings-new-room-form", %{title: ""}) |> render_submit()

    assert has_element?(
             view,
             "[data-role=meetings-new-room] .cal-err",
             "Give the meeting a name."
           )

    view |> element("[data-role=meetings-new-room] button", "Cancel") |> render_click()
    refute has_element?(view, "[data-role=meetings-new-room]")

    view |> element("[data-role=list-new-meeting]") |> render_click()

    result =
      view
      |> form("#meetings-new-room-form", %{title: "Team catch-up", project_id: project.id})
      |> render_submit()

    assert match?({:error, {_, %{to: "/meetings/" <> _}}}, result) or is_binary(result)
    assert [%{name: "Team catch-up"}] = Repo.all(Platform.Meetings.Meeting)
  end
end
