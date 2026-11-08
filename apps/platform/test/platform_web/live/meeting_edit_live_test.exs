defmodule PlatformWeb.MeetingEditLiveTest do
  @moduledoc """
  Edit a scheduled meeting in place from /meetings and /calendar (task
  01a1b281 stage 3): `PlatformWeb.Components.Meetings.EditMeeting` driven by
  `PlatformWeb.MeetingLive.MeetingEdit`.

  Every refusal is paired with a permitted viewer on the same fixture, so a
  control that never renders fails a named test instead of passing the
  negatives vacuously. "No mail" is asserted two ways: no `mail_deliveries`
  row appears, and no `{:meeting_updated, ...}` broadcast (the only thing
  `MeetingNotifier` sends edit mail on) is made.
  """
  use PlatformWeb.ConnCase, async: false

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

  defp open_edit(view) do
    view |> element("[data-role=meetings-detail] [data-role=meeting-edit-open]") |> render_click()
    assert has_element?(view, "[data-role=meeting-edit]")
  end

  defp change(view, attrs) do
    view |> form("#meeting-edit-form", meeting_edit: attrs) |> render_change()
  end

  @detail "[data-role=meetings-detail]"
  @save "[data-role=meeting-edit-save]"

  # ── Who sees Edit ─────────────────────────────────────────────────────────

  describe "the Edit action on /meetings" do
    test "the organizer sees it beside Cancel on the list detail; the invitee sees none",
         ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      assert has_element?(view, @detail <> " [data-role=meetings-detail-edit-row]")
      assert has_element?(view, @detail <> " [data-role=meeting-edit-open]", "Edit")
      assert has_element?(view, @detail <> " [data-role=meeting-cancel-row]")

      {:ok, invitee_view, _} = live(conn_for(ctx.invitee), detail_path(meeting))
      # Positive control: the invitee's detail did render this meeting.
      assert has_element?(invitee_view, @detail <> " [data-meeting-id='#{meeting.id}']")
      refute has_element?(invitee_view, "[data-role=meeting-edit-open]")
    end

    test "the calendar view's panel and sheet footers carry it for the organizer only", ctx do
      zone = "America/Chicago"
      # Ahead of now, inside today's week.
      start = DateTime.utc_now() |> DateTime.add(120) |> DateTime.truncate(:second)
      start = %{start | second: 0}
      meeting = meeting!(ctx, start: start, minutes: 30)

      {:ok, view, _} = live(conn_for(ctx.organizer, zone), "/meetings?view=calendar")
      render_click(view, "select_meeting", %{"id" => meeting.id})

      for footer <- ["meeting-detail-panel-footer", "meeting-detail-sheet-footer"] do
        assert has_element?(view, "[data-role=#{footer}] [data-role=meeting-edit-open]")
      end

      render_click(view, "meeting_edit_open", %{})
      assert has_element?(view, "[data-role=meeting-edit] [data-role=meeting-edit-name]")

      {:ok, invitee_view, _} = live(conn_for(ctx.invitee, zone), "/meetings?view=calendar")
      render_click(invitee_view, "select_meeting", %{"id" => meeting.id})
      assert has_element?(invitee_view, "[data-role=meeting-detail-panel-footer]")
      refute has_element?(invitee_view, "[data-role=meeting-edit-open]")
    end

    test "a cancelled meeting shows no Edit, even to its organizer", ctx do
      meeting = meeting!(ctx)
      {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, ctx.organizer)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      assert has_element?(view, @detail <> " [data-meeting-id='#{meeting.id}']")
      refute has_element?(view, "[data-role=meeting-edit-open]")
    end
  end

  # ── Forged events ─────────────────────────────────────────────────────────

  describe "a forged edit" do
    test "from the invitee opens nothing, saves nothing and mails nobody", ctx do
      meeting = meeting!(ctx, guests: 2)
      before = deliveries()

      {:ok, view, _} = live(conn_for(ctx.invitee), detail_path(meeting))

      render_click(view, "meeting_edit_open", %{})
      refute has_element?(view, "[data-role=meeting-edit]")

      render_submit(view, "meeting_edit_save", %{
        "meeting_id" => meeting.id,
        "meeting_edit" => %{"name" => "Hijacked", "start_time" => "3:00 PM"}
      })

      render_click(view, "meeting_edit_remove", %{"id" => meeting.id})

      row = reload(meeting)
      assert row.name == "Weekly sync"
      assert row.scheduled_start_at == meeting.scheduled_start_at
      assert row.ical_sequence == meeting.ical_sequence
      assert length(Meetings.list_invites(meeting.id)) == 3
      refute_receive {:meeting_updated, _, _}, 100
      assert deliveries() == before
    end

    test "names the meeting the form was opened on, never the payload's id", ctx do
      opened = meeting!(ctx, name: "Opened one")
      other = meeting!(ctx, name: "Other one", invite_invitee: false)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(opened))
      open_edit(view)

      render_submit(view, "meeting_edit_save", %{
        "meeting_id" => other.id,
        "id" => other.id,
        "meeting_edit" => %{"name" => "Renamed"}
      })

      assert reload(opened).name == "Renamed"
      assert reload(other).name == "Other one"
    end

    test "every event reloads the meeting: one cancelled meanwhile shuts the form", ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      # Cancelled from another window: the form's own state still says
      # "editable", only a reload knows otherwise.
      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
        set: [status: "cancelled"]
      )

      change(view, %{name: "Too late"})
      refute has_element?(view, "[data-role=meeting-edit]")
      assert render(view) =~ "You can&#39;t edit this meeting."
      assert reload(meeting).name == "Weekly sync"
    end
  end

  # ── Saving ────────────────────────────────────────────────────────────────

  describe "saving" do
    test "a new time keeps the id and the link, and the list redraws", ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      assert has_element?(view, "[data-role=meeting-edit-start-time][value='10:00 AM']")
      refute has_element?(view, "[data-role=meeting-edit-was]")

      change(view, %{start_time: "11:30 AM"})
      assert has_element?(view, "[data-role=meeting-edit-was]", "was 10:00 AM")

      assert has_element?(
               view,
               "[data-role=meeting-edit-summary-link]",
               "/meetings/#{meeting.slug}"
             )

      view |> form("#meeting-edit-form") |> render_submit()

      row = reload(meeting)
      assert row.id == meeting.id
      assert row.slug == meeting.slug

      assert DateTime.compare(
               row.scheduled_start_at,
               DateTime.add(meeting.scheduled_start_at, 5400)
             ) == :eq

      assert DateTime.compare(row.scheduled_end_at, DateTime.add(meeting.scheduled_end_at, 5400)) ==
               :eq

      assert row.ical_sequence == meeting.ical_sequence + 1

      assert_receive {:meeting_updated, %Meeting{id: id}, %{changed: changed}}
      assert id == meeting.id
      assert :time in changed

      refute has_element?(view, "[data-role=meeting-edit]")
      assert render(view) =~ "11:30"
    end

    test "the summary renders preview_meeting_edit/2's recipients", ctx do
      meeting = meeting!(ctx, guests: 2)
      [removed | _] = Enum.filter(Meetings.list_invites(meeting.id), &is_binary(&1.email))

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      change(view, %{name: "Weekly sync, renamed"})
      render_click(view, "meeting_edit_remove", %{"id" => removed.id})
      assert has_element?(view, "[data-role=meeting-edit-removed]", "removed:")

      preview =
        Meetings.preview_meeting_edit(reload(meeting), %{
          name: "Weekly sync, renamed",
          remove_invite_ids: [removed.id],
          add_invitees: []
        })

      # Anti-vacuity: this edit does mail someone both ways.
      assert preview.update_recipients != []
      assert preview.cancel_recipients != []

      summary = "[data-role=meeting-edit-summary]"

      for r <- preview.update_recipients do
        name = PlatformWeb.Components.Meetings.EditMeeting.recipient_name(r)
        assert has_element?(view, summary <> " [data-role=meeting-edit-summary-updated]", name)
      end

      assert has_element?(
               view,
               summary <> " [data-role=meeting-edit-summary-updated]",
               "an updated invite (new title)."
             )

      for r <- preview.cancel_recipients do
        name = PlatformWeb.Components.Meetings.EditMeeting.recipient_name(r)
        assert has_element?(view, summary <> " [data-role=meeting-edit-summary-cancelled]", name)
      end

      # Undo puts the row back and the cancellation sentence goes.
      render_click(view, "meeting_edit_undo", %{"id" => removed.id})
      refute has_element?(view, "[data-role=meeting-edit-summary-cancelled]")
      refute render(view) =~ ~r/reschedul/i
    end

    test "no change disables Save; notes alone mail nobody", ctx do
      meeting = meeting!(ctx, guests: 1)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      assert has_element?(
               view,
               "[data-role=meeting-edit-summary-none]",
               "Nothing has changed yet."
             )

      assert has_element?(view, @save <> "[disabled]")

      change(view, %{start_time: "11:00 AM"})
      refute has_element?(view, @save <> "[disabled]")

      # Back to the original value: nothing has changed again.
      change(view, %{start_time: "10:00 AM"})
      assert has_element?(view, @save <> "[disabled]")
      assert has_element?(view, "[data-role=meeting-edit-summary-none]")

      change(view, %{description: "Bring the numbers."})
      refute has_element?(view, @save <> "[disabled]")

      assert has_element?(
               view,
               "[data-role=meeting-edit-summary-notes-only]",
               "only the notes changed."
             )

      before = deliveries()
      view |> form("#meeting-edit-form") |> render_submit()
      assert reload(meeting).description == "Bring the numbers."
      assert reload(meeting).ical_sequence == meeting.ical_sequence
      assert deliveries() == before
    end

    test "removing the last invitee is refused inline and the row stays", ctx do
      meeting = meeting!(ctx)
      [only] = Meetings.list_invites(meeting.id)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      render_click(view, "meeting_edit_remove", %{"id" => only.id})

      assert has_element?(
               view,
               "[data-role=meeting-edit-last-invitee]",
               "Keep at least one invitee, or cancel the meeting."
             )

      refute has_element?(view, "[data-role=meeting-edit-removed]")
      assert has_element?(view, "[data-role=meeting-edit-invitee]", ctx.invitee.name)
    end

    test "Add people stages a guest by email as an email chip, invited on Save", ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      open_edit(view)

      view |> element("[data-role=meeting-edit-add-people]") |> render_click()
      address = "edit-new-#{System.unique_integer([:positive])}@example.com"
      render_keyup(view, "meeting_edit_invite_search", %{"value" => address})
      view |> element("[data-role=meeting-invite-option][data-option=guest]") |> render_click()

      assert has_element?(view, "[data-role=meeting-edit-invitee][data-email-chip=true]", address)
      assert has_element?(view, "[data-role=meeting-edit-summary-invited]", address)

      view |> form("#meeting-edit-form") |> render_submit()
      assert Enum.any?(Meetings.list_invites(meeting.id), &(&1.email == address))
    end
  end

  # ── Live redraw ───────────────────────────────────────────────────────────

  describe "an open list" do
    test "redraws on {:meeting_updated, ...} and drops a deleted meeting", ctx do
      meeting = meeting!(ctx, name: "Before the edit")
      gone = meeting!(ctx, name: "Soon deleted", invite_invitee: false)
      {:ok, _} = Meetings.cancel_meeting_for_user(gone.id, ctx.organizer)

      {:ok, view, _} = live(conn_for(ctx.invitee), "/meetings")
      row = "[data-role=workspace-meeting][data-meeting-id='#{meeting.id}'] strong"
      assert has_element?(view, row, "Before the edit")
      assert has_element?(view, "[data-role=workspace-meeting][data-meeting-id='#{gone.id}']")

      {:ok, _} =
        Meetings.update_meeting_for_user(meeting.id, %{name: "After the edit"}, ctx.organizer)

      {:ok, _} = Meetings.delete_meeting_for_user(gone.id, ctx.organizer)

      assert has_element?(view, row, "After the edit")
      refute has_element?(view, row, "Before the edit")
      refute has_element?(view, "[data-role=workspace-meeting][data-meeting-id='#{gone.id}']")
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
