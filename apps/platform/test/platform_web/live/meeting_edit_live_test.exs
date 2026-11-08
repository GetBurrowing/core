defmodule PlatformWeb.MeetingEditLiveTest do
  @moduledoc """
  Edit a scheduled meeting in place (task 01a1b281 stage 3). Since task
  01a1b8a5 stage 4 that is Calendar's one editor only: the /meetings Edit
  meeting form (`PlatformWeb.MeetingLive.MeetingEdit`) is gone, and the
  listing that survives on the meet host draws no Edit.

  Every refusal is paired with a permitted viewer on the same fixture, so a
  control that never renders fails a named test instead of passing the
  negatives vacuously. "No mail" is asserted two ways: no `mail_deliveries`
  row appears, and no `{:meeting_updated, ...}` broadcast (the only thing
  `MeetingNotifier` sends edit mail on) is made.
  """
  use PlatformWeb.ConnCase, async: false

  # The meetings LISTING survives only on the `meet.` host's member surface
  # (task 01a1b8a5 stage 4, the `meet-member-meetings-index` ParallelUI
  # shim); the app-host `/meetings` redirects to Calendar. These tests
  # exercise that surviving listing, so they reach it the way a member does.
  defp meet_member_host(conn), do: %{conn | host: "meet.example.com"}

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Mail.Delivery
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  setup do
    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Edit meeting #{n}",
        slug: "edit-meeting-#{n}",
        org_id: org_id
      })

    organizer = member!(org_id, "Organizer")
    invitee = member!(org_id, "Invitee")

    Meetings.subscribe_to_project_meetings(project.id)

    %{org_id: org_id, project: project, organizer: organizer, invitee: invitee}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "edit-ui-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "edit-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    user
  end

  defp conn_for(user, zone \\ "Etc/UTC") do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => zone})
  end

  # Tomorrow 10:00-11:00 UTC by default; the invitee holds a live invite,
  # plus `guests` guest invites with an address.
  defp meeting!(ctx, opts \\ []) do
    start =
      Keyword.get_lazy(opts, :start, fn ->
        Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[10:00:00], "Etc/UTC")
      end)

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: ctx.project.id,
        name: Keyword.get(opts, :name, "Weekly sync"),
        created_by_user_id: ctx.organizer.id,
        scheduled_start_at: start,
        scheduled_end_at: DateTime.add(start, Keyword.get(opts, :minutes, 60) * 60)
      })

    if Keyword.get(opts, :invite_invitee, true) do
      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        user_id: ctx.invitee.id,
        display_name: ctx.invitee.name
      })
    end

    for i <- 1..Keyword.get(opts, :guests, 0)//1 do
      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        display_name: "Guest #{i}",
        email: "edit-guest-#{i}-#{System.unique_integer([:positive])}@example.com"
      })
    end

    meeting
  end

  defp detail_path(meeting), do: "/meetings?" <> URI.encode_query(%{meeting: meeting.id})
  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)
  defp deliveries, do: Repo.aggregate(Delivery, :count)

  @detail "[data-role=meetings-detail]"

  # ── The listing has no Edit (task 01a1b8a5 stage 4) ──────────────────────
  #
  # The /meetings "Edit meeting" form was the second authoring flow; it is
  # gone with the app-host listing. The meet-host listing that survives (the
  # `meet-member-meetings-index` shim) draws no Edit for anyone and no
  # longer handles `meeting_edit_*` at all, so a forged one writes nothing.

  describe "the surviving meet-host listing" do
    test "draws no Edit for the organizer either; Cancel is still there", ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(meet_member_host(conn_for(ctx.organizer)), detail_path(meeting))

      assert has_element?(view, @detail, "Weekly sync")
      assert has_element?(view, "#{@detail} [data-role=meeting-cancel-row]"), "positive control"
      refute has_element?(view, "[data-role=meeting-edit-open]")
      refute has_element?(view, "[data-role=meeting-edit]")
    end

    test "a forged meeting_edit event saves nothing and mails nobody", ctx do
      meeting = meeting!(ctx)
      before = deliveries()

      {:ok, view, _} = live(meet_member_host(conn_for(ctx.organizer)), detail_path(meeting))
      Process.flag(:trap_exit, true)

      # No clause handles it any more: the LiveView refuses by crashing,
      # which is a refusal, not a write.
      catch_exit(render_click(view, "meeting_edit_save", %{"meeting_edit" => %{"name" => "X"}}))

      assert reload(meeting).name == "Weekly sync"
      refute_receive {:meeting_updated, _, _}, 100
      assert deliveries() == before
    end

    test "the app-host listing (and its ?meeting= selection) lands in Calendar", ctx do
      meeting = meeting!(ctx)
      to = "/calendar?meeting=#{meeting.id}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn_for(ctx.organizer), detail_path(meeting))
    end
  end

  # ── /calendar ─────────────────────────────────────────────────────────────

  describe "the calendar details" do
    defp midday_zone do
      offset = 12 - DateTime.utc_now().hour

      cond do
        offset == 0 -> "Etc/UTC"
        offset > 0 -> "Etc/GMT-#{offset}"
        true -> "Etc/GMT+#{-offset}"
      end
    end

    defp cal_meeting!(ctx, zone) do
      today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()
      start = today |> DateTime.new!(~T[15:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")
      meeting!(ctx, start: start, guests: 1)
    end

    defp open_chip(view, meeting) do
      view
      |> element(
        "[data-role=calendar-week] .cal-ev[data-kind=meeting][phx-value-id='#{meeting.id}']"
      )
      |> render_click()
    end

    # Task 01a1b8a5 stage 2: Calendar's Edit opens Calendar's ONE event
    # editor (`CalendarLive.Editor`) on the meeting, not a second Edit
    # meeting form; it saves through `Meetings.update_meeting_for_user/3`.
    test "carry Edit for the organizer, and Save renames in place", ctx do
      zone = midday_zone()
      meeting = cal_meeting!(ctx, zone)

      {:ok, view, _} = live(conn_for(ctx.organizer, zone), "/calendar")
      open_chip(view, meeting)

      assert has_element?(
               view,
               "[data-role=calendar-details] [data-role=meeting-edit-open]",
               "Edit"
             )

      view
      |> element("[data-role=calendar-details] [data-role=meeting-edit-open]")
      |> render_click()

      assert has_element?(view, "#calendar-editor")
      refute has_element?(view, "[data-role=meeting-edit]")

      view |> form("#calendar-event-form", event: %{title: "Calendar rename"}) |> render_change()
      assert has_element?(view, "[data-role=meeting-edit-was]", "was Weekly sync")
      view |> form("#calendar-event-form") |> render_submit()

      row = reload(meeting)
      assert row.name == "Calendar rename"
      assert row.slug == meeting.slug
      assert_receive {:meeting_updated, %Meeting{}, _}
      refute has_element?(view, "#calendar-editor")
      assert has_element?(view, "[data-role=calendar-details]", "Calendar rename")
    end

    test "carry none for the invitee, and a forged edit does nothing", ctx do
      zone = midday_zone()
      meeting = cal_meeting!(ctx, zone)
      before = deliveries()

      {:ok, view, _} = live(conn_for(ctx.invitee, zone), "/calendar")
      open_chip(view, meeting)

      assert has_element?(view, "[data-role=calendar-details]", "Weekly sync")
      refute has_element?(view, "[data-role=meeting-edit-open]")

      render_click(view, "meeting_edit_open", %{})
      refute has_element?(view, "[data-role=meeting-edit]")
      refute has_element?(view, "#calendar-editor")

      render_submit(view, "save", %{
        "meeting_id" => meeting.id,
        "event" => %{"title" => "Hijacked"}
      })

      assert reload(meeting).name == "Weekly sync"
      refute_receive {:meeting_updated, _, _}, 100
      assert deliveries() == before
    end
  end
end
