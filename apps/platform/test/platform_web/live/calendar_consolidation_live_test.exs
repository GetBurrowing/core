defmodule PlatformWeb.CalendarConsolidationLiveTest do
  @moduledoc """
  Task 01a1b8a5 stage 4 through the LiveViews:

    * old `/meetings` listing and schedule links land in Calendar with only
      safe context; direct room links, the guest and feed routes do not;
    * Calendar opens a call record's own event (`?meeting=<id>`) through the
      viewer scope, and its details offer Join now / Open call room — to the
      owner of the native event too — and say so when the call is off;
    * a call room's way back is that same event;
    * the call toggle is refused in the room, not only hidden;
    * cancelling from the surviving Meetings listing cancels the owner's
      native event;
    * Past events: populated, empty, unavailable, paged, and each row opens
      its event, whose "After the call" panel lists only readable records.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Access.Scope
  alias Platform.Calendar.{Authoring, Event}
  alias Platform.Meetings
  alias Platform.Meetings.{CalendarLink, Meeting, Transcript}
  alias Platform.Repo

  @zone "America/Chicago"
  @details "[data-role=calendar-details]"
  @join "[data-role=calendar-detail-join]"

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup do
    keys = [:meetings_enabled, :inbox_module, :notifications_module]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}
    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :inbox_module, Quiet)
    Application.put_env(:platform, :notifications_module, Quiet)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Consolidation #{n}",
        slug: "consolidation-#{n}",
        org_id: org_id
      })

    %{
      org_id: org_id,
      project: project,
      owner: member!(org_id, "Owner"),
      invitee: member!(org_id, "Invitee"),
      stranger: member!(Platform.TenancyFixtures.tenant_org_id("globex"), "Stranger")
    }
  end

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "consolidation-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "consolidation-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    user
  end

  defp conn_for(user) do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => @zone})
  end

  # Two days out at 15:00 local, so the event sits mid-week in the zone.
  defp linked!(ctx, extra \\ %{}) do
    day = DateTime.utc_now() |> DateTime.shift_zone!(@zone) |> DateTime.to_date() |> Date.add(2)
    start = DateTime.new!(day, ~T[15:00:00], @zone)
    scope = Scope.for_user(ctx.owner)

    attrs =
      Map.merge(
        %{
          "title" => "Design review",
          "starts_at" => DateTime.to_iso8601(start),
          "ends_at" => DateTime.to_iso8601(DateTime.add(start, 3600)),
          "time_zone" => @zone,
          "project_id" => ctx.project.id,
          "add_invitees" => [%{"kind" => "user", "user_id" => ctx.invitee.id}]
        },
        extra
      )

    {:ok, %{event: event, meeting: meeting}} =
      Authoring.save(scope, Authoring.new_draft(scope), attrs)

    %{event: event, meeting: meeting}
  end

  defp calendar(user, query \\ "") do
    {:ok, view, _} = live(conn_for(user), "/calendar" <> query)
    view
  end

  # ── old listing links vs direct room links ─────────────────────────────

  describe "/meetings on the app host" do
    test "the bare listing, a selection, the archive and the schedule sheet land in Calendar",
         ctx do
      id = Ecto.UUID.generate()
      conn = conn_for(ctx.owner)

      assert {:error, {:live_redirect, %{to: "/calendar"}}} = live(conn, "/meetings")

      to = "/calendar?meeting=#{id}"
      assert {:error, {:live_redirect, %{to: ^to}}} = live(conn, "/meetings?meeting=#{id}")

      assert {:error, {:live_redirect, %{to: "/calendar?past=1"}}} =
               live(conn, "/meetings?view=archive&q=secret")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 conn,
                 "/meetings?schedule=true&from=calendar&date=2026-11-13&start_time=2:00 PM"
               )

      assert URI.decode_query(URI.parse(to).query) == %{
               "new" => "1",
               "date" => "2026-11-13",
               "start" => "2:00 PM"
             }
    end

    test "the dead render is a plain 302, so a bookmark never draws the old list", ctx do
      conn = get(conn_for(ctx.owner), "/meetings?view=archive")
      assert redirected_to(conn, 302) == "/calendar?past=1"
    end

    test "an old schedule link opens Calendar's one editor, with the viewer's own project",
         ctx do
      for i <- 1..2 do
        Repo.insert!(%Platform.Tasks.Project{
          name: "Second #{i} #{System.unique_integer([:positive])}",
          slug: "second-#{i}-#{System.unique_integer([:positive])}",
          org_id: ctx.org_id
        })
      end

      projects = Platform.Tasks.list_projects_for_user(ctx.owner)
      [default | _] = projects
      # A project that is NOT the editor's default, so a dropped parameter
      # cannot pass by coincidence.
      chosen = projects |> Enum.reject(&(&1.id == default.id)) |> List.last()
      assert chosen

      selected = fn view ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#calendar-editor option[selected]")
        |> LazyHTML.attribute("value")
      end

      view = calendar(ctx.owner, "?new=1&date=2026-11-13&start=2:00 PM&project=#{chosen.id}")
      assert has_element?(view, "#calendar-editor")
      refute has_element?(view, "[data-role=start-meeting-sheet]")
      assert chosen.id in selected.(view)

      # A project the viewer does not have (here: no such project) is ignored.
      view = calendar(ctx.owner, "?new=1&project=#{Ecto.UUID.generate()}")
      assert has_element?(view, "#calendar-editor")
      assert default.id in selected.(view)
      refute chosen.id in selected.(view)
    end

    test "a direct room link is the room, never Calendar", ctx do
      %{meeting: meeting} = linked!(ctx)

      assert {:ok, view, _} = live(conn_for(ctx.owner), "/meetings/#{meeting.slug}")
      assert view.module == PlatformWeb.MeetingLive
      refute has_element?(view, "[data-page=calendar]")
    end

    test "an unauthorized room link keeps its own not-found answer", ctx do
      %{meeting: meeting} = linked!(ctx)

      assert {:error,
              {:live_redirect, %{to: "/meetings", flash: %{"error" => "Meeting not found."}}}} =
               live(conn_for(ctx.stranger), "/meetings/#{meeting.slug}")
    end

    test "invite.ics and the guest short link are not redirected to Calendar", ctx do
      %{meeting: meeting} = linked!(ctx)

      ics =
        get(
          build_conn(),
          "/meetings/#{meeting.id}/invite.ics?token=#{CalendarLink.sign(meeting.id)}"
        )

      assert ics.status == 200
      assert ics.resp_body =~ "BEGIN:VCALENDAR"

      g = get(build_conn(), "/g/nosuchcode")
      refute g.status in [301, 302] and redirected_to(g) =~ "/calendar"
    end
  end

  # ── Calendar opens the call's event ─────────────────────────────────────

  describe "?meeting=<id> and the details' call controls" do
    test "the owner lands on their own native event, with Open call room", ctx do
      %{event: event, meeting: meeting} = linked!(ctx)
      view = calendar(ctx.owner, "?meeting=#{meeting.id}")

      assert has_element?(view, "#{@details}[data-kind=native]", "Design review")

      assert has_element?(
               view,
               "#{@details} #{@join}[href='/meetings/#{meeting.slug}']",
               "Open call room"
             )

      assert has_element?(view, "#{@details} button", "Edit")
      assert event.meeting_id == meeting.id
    end

    test "while the call is live the owner sees Join now", ctx do
      %{meeting: meeting} = linked!(ctx)
      {:ok, _} = Meetings.start_meeting(meeting)

      view = calendar(ctx.owner, "?meeting=#{meeting.id}")
      assert has_element?(view, "#{@details} #{@join}", "Join now")
      assert has_element?(view, "[data-role=calendar-detail-call-live]")
    end

    test "an invitee lands on the call record itself, with no View in Meetings", ctx do
      %{meeting: meeting} = linked!(ctx)
      view = calendar(ctx.invitee, "?meeting=#{meeting.id}")

      assert has_element?(view, "#{@details}[data-kind=meeting]", "Design review")
      assert has_element?(view, "#{@details} #{@join}", "Open call room")
      refute has_element?(view, @details, "View in Meetings")
    end

    test "someone who cannot see the meeting gets plain Calendar and no details", ctx do
      %{meeting: meeting} = linked!(ctx)
      view = calendar(ctx.stranger, "?meeting=#{meeting.id}")

      assert has_element?(view, "[data-page=calendar]")
      refute has_element?(view, @details)
      refute render(view) =~ "Design review"
    end

    # M21: the id alone must not move the grid. A meeting five weeks out
    # (so it cannot share today's week) that the viewer cannot see leaves
    # them on today's week, with no details and no title; the invitee, as a
    # positive control, is taken to that week. The two-days-out fixture
    # above cannot tell a moved week from an unmoved one.
    test "a meeting the viewer cannot see never moves the week", ctx do
      today = DateTime.utc_now() |> DateTime.shift_zone!(@zone) |> DateTime.to_date()
      far = Date.add(today, 35)
      start = DateTime.new!(far, ~T[15:00:00], @zone)
      scope = Scope.for_user(ctx.owner)

      {:ok, %{meeting: meeting}} =
        Authoring.save(scope, Authoring.new_draft(scope), %{
          "title" => "Hidden offsite",
          "starts_at" => DateTime.to_iso8601(start),
          "ends_at" => DateTime.to_iso8601(DateTime.add(start, 3600)),
          "time_zone" => @zone,
          "project_id" => ctx.project.id,
          "add_invitees" => [%{"kind" => "user", "user_id" => ctx.invitee.id}]
        })

      far_cell = "[data-date='#{Date.to_iso8601(far)}']"
      today_cell = "[data-date='#{Date.to_iso8601(today)}']"

      view = calendar(ctx.stranger, "?meeting=#{meeting.id}")
      refute has_element?(view, @details)
      refute has_element?(view, far_cell)
      assert has_element?(view, today_cell)
      refute render(view) =~ "Hidden offsite"

      # The invitee, who does see it, is taken to that week.
      view = calendar(ctx.invitee, "?meeting=#{meeting.id}")
      assert has_element?(view, far_cell)
      assert has_element?(view, @details, "Hidden offsite")
    end

    test "a call that is off says so and offers no room, to the owner and the invitee", ctx do
      %{meeting: meeting} = linked!(ctx, %{"call_enabled" => "false"})
      refute meeting.call_enabled

      for user <- [ctx.owner, ctx.invitee] do
        view = calendar(user, "?meeting=#{meeting.id}")
        assert has_element?(view, @details, "Design review")
        assert has_element?(view, "[data-role=calendar-detail-call-off]", "No Burrow call")
        refute has_element?(view, @join)
      end
    end

    test "the room's breadcrumb returns to the same event", ctx do
      %{meeting: meeting} = linked!(ctx)
      {:ok, _view, html} = live(conn_for(ctx.owner), "/meetings/#{meeting.slug}?no_autojoin=true")
      assert html =~ ~s(href="/calendar?meeting=#{meeting.id}")
    end
  end

  # ── the call toggle in the room ─────────────────────────────────────────

  describe "a call-off room" do
    test "draws no Join, and a forged join is refused with a reason", ctx do
      %{meeting: meeting} = linked!(ctx, %{"call_enabled" => "false"})
      {:ok, view, _} = live(conn_for(ctx.invitee), "/meetings/#{meeting.slug}?no_autojoin=true")

      assert has_element?(view, "[data-role=meeting-call-off]", "No call for this event")
      refute has_element?(view, "[data-role=meeting-join]")

      html = render_click(view, "meeting_join", %{})
      assert html =~ "The organizer turned the Burrow call off for this event."
      refute_push_event(view, "join-meeting", %{}, 100)
      assert Repo.get!(Meeting, meeting.id).status == "scheduled"
    end

    test "a call-on room still draws Join (positive control)", ctx do
      %{meeting: meeting} = linked!(ctx)
      {:ok, view, _} = live(conn_for(ctx.invitee), "/meetings/#{meeting.slug}?no_autojoin=true")

      assert has_element?(view, "[data-role=meeting-join]")
      refute has_element?(view, "[data-role=meeting-call-off]")
    end
  end

  # ── cancel from the Meetings UI ─────────────────────────────────────────

  describe "cancelling from the surviving Meetings listing" do
    test "cancels the owner's native event too, and the owner's Calendar shows it cancelled",
         ctx do
      %{event: event, meeting: meeting} = linked!(ctx)
      conn = %{conn_for(ctx.owner) | host: "meet.example.com"}
      {:ok, view, _} = live(conn, "/meetings?meeting=#{meeting.id}")

      view
      |> element("[data-role=meetings-detail] [data-role=meeting-cancel-row]")
      |> render_click()

      render_click(view, "cancel_meeting_confirm", %{})
      render_async(view)

      assert Repo.get!(Meeting, meeting.id).status == "cancelled"
      assert %DateTime{} = Repo.get!(Event, event.id).cancelled_at

      cal = calendar(ctx.owner, "?meeting=#{meeting.id}")
      assert has_element?(cal, "#{@details}[data-kind=meeting]")
      refute has_element?(cal, "#{@details}[data-kind=native]")
      refute has_element?(cal, @join)
    end
  end

  # ── Past events ─────────────────────────────────────────────────────────

  defp ended!(ctx, name, minutes_ago) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: ctx.project.id,
        name: name,
        created_by_user_id: ctx.owner.id
      })

    ended_at = DateTime.add(DateTime.utc_now(), -minutes_ago * 60)
    started = DateTime.add(ended_at, -1800)

    Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
      set: [
        status: "ended",
        started_at: started,
        ended_at: ended_at,
        scheduled_start_at: started,
        scheduled_end_at: ended_at
      ]
    )

    Repo.get!(Meeting, meeting.id)
  end

  defp transcript!(meeting, attrs) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{
          room_id: "space-#{meeting.chat_space_id}",
          space_id: meeting.chat_space_id,
          meeting_id: meeting.id,
          started_at: DateTime.utc_now(),
          status: "complete"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "Past events" do
    test "is reachable from the list pane and the phone section tabs", ctx do
      view = calendar(ctx.owner)

      assert has_element?(
               view,
               "[data-role=calendar-list-pane] a[data-past-events]",
               "Past events"
             )

      assert has_element?(
               view,
               "[data-role=calendar-section-tabs] a[data-past-events]",
               "Past events"
             )

      refute has_element?(view, "[data-role=past-events]")
    end

    test "populated: rows carry their records; a row opens its event's After the call", ctx do
      Repo.delete_all(Meeting)
      kept = ended!(ctx, "Kept call", 90)
      bare = ended!(ctx, "Bare call", 120)
      t = transcript!(kept, %{summary: "We shipped it.", segments: [%{"text" => "hi"}]})

      view = calendar(ctx.owner, "?past=1")
      assert has_element?(view, "[data-role=past-events][data-state=ok]")

      assert has_element?(
               view,
               "[data-role=past-event-row][data-meeting-id='#{kept.id}'] [data-record=summary]"
             )

      assert has_element?(
               view,
               "[data-role=past-event-row][data-meeting-id='#{kept.id}'] [data-record=transcript]"
             )

      assert has_element?(
               view,
               "[data-role=past-event-row][data-meeting-id='#{kept.id}'] [data-record=recording-none]"
             )

      assert has_element?(
               view,
               "[data-role=past-event-row][data-meeting-id='#{bare.id}'] [data-record=summary-none]"
             )

      view
      |> element("[data-role=past-event-row][data-meeting-id='#{kept.id}']")
      |> render_click()

      assert_patched(view, "/calendar?meeting=#{kept.id}")
      refute has_element?(view, "[data-role=past-events]")
      assert has_element?(view, "[data-role=calendar-detail-recap]", "We shipped it.")

      assert has_element?(
               view,
               "[data-role=calendar-detail-recap] a[href='/api/transcripts/#{t.id}/download']"
             )

      assert has_element?(view, "[data-role=calendar-detail-recap] [data-record=recording-none]")
    end

    test "empty is its own sentence", ctx do
      Repo.delete_all(Meeting)
      view = calendar(ctx.owner, "?past=1")
      assert has_element?(view, "[data-role=past-events][data-state=empty]")
      assert has_element?(view, "[data-role=past-events-empty]", "No past calls yet.")
      refute has_element?(view, "[data-role=past-event-row]")
    end

    test "unavailable when calls are off for the install, not empty", ctx do
      Application.put_env(:platform, :meetings_enabled, false)
      ended!(ctx, "Hidden call", 30)

      view = calendar(ctx.owner, "?past=1")
      assert has_element?(view, "[data-role=past-events][data-state=unavailable]")
      assert has_element?(view, "[data-role=past-events-unavailable]")
      refute has_element?(view, "[data-role=past-events-empty]")
      refute has_element?(view, "[data-role=past-event-row]")
    end

    test "another org's calls are not listed", ctx do
      Repo.delete_all(Meeting)
      ended!(ctx, "Acme only call", 30)

      view = calendar(ctx.stranger, "?past=1")
      refute render(view) =~ "Acme only call"
      assert has_element?(view, "[data-role=past-events][data-state=empty]")
    end

    test "pages: Older and Newer move a page at a time", ctx do
      Repo.delete_all(Meeting)
      per = Platform.Meetings.PastEvents.per_page()
      for i <- 1..(per + 2), do: ended!(ctx, "Call #{i}", i * 10)

      view = calendar(ctx.owner, "?past=1")
      assert length(Regex.scan(~r/data-role="past-event-row"/, render(view))) == per
      refute has_element?(view, "[data-role=past-events-newer]")

      view |> element("[data-role=past-events-older]") |> render_click()
      assert length(Regex.scan(~r/data-role="past-event-row"/, render(view))) == 2
      assert has_element?(view, "[data-role=past-events-newer]")
      refute has_element?(view, "[data-role=past-events-older]")
    end

    test "Close keeps the view the viewer was on", ctx do
      view = calendar(ctx.owner, "?view=month&past=1")
      view |> element("[data-role=past-events] button", "Close") |> render_click()
      path = assert_patch(view)
      assert URI.decode_query(URI.parse(path).query)["view"] == "month"
      refute URI.decode_query(URI.parse(path).query)["past"]
      refute has_element?(view, "[data-role=past-events]")
    end
  end
end
