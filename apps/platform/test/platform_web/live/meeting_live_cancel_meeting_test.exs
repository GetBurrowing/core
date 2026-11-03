defmodule PlatformWeb.MeetingLiveCancelMeetingTest do
  @moduledoc """
  The "Cancel meeting" control on /meetings (task 01a19e7f stage 3): the
  list view's detail (`?meeting=<id>`) and the calendar view's detail
  panel and sheet, both rendering
  `PlatformWeb.Components.Meetings.CancelMeeting`.

  Every refusal is paired with a permitted viewer on the same kind of
  fixture, so a control that never renders, or a confirm that never
  cancels, fails a named test instead of passing the negatives vacuously.
  Assertions key on the component's `data-role` contract, never on classes.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  setup do
    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Cancel meeting #{n}",
        slug: "cancel-meeting-#{n}",
        org_id: org_id
      })

    creator = member!(org_id, "Creator")
    plain = member!(org_id, "Plain")

    %{org_id: org_id, project: project, creator: creator, plain: plain}
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # `@example.com`: an `@acme.test` address derives an admin role and would
  # make every viewer here permitted.
  defp member!(org_id, name, role \\ "member") do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "cancel-ui-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "cancel-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: user.id, org_id: org_id, role: role})
    user
  end

  defp conn_for(conn, user, zone \\ "Etc/UTC") do
    conn
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => zone})
  end

  defp meeting!(project, creator, opts \\ []) do
    start =
      Keyword.get_lazy(opts, :start, fn ->
        Date.utc_today() |> Date.add(1) |> DateTime.new!(~T[10:00:00], "Etc/UTC")
      end)

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: Keyword.get(opts, :name, "Weekly sync"),
        created_by_user_id: creator && creator.id,
        scheduled_start_at: start,
        scheduled_end_at: DateTime.add(start, 3600)
      })

    for i <- 1..Keyword.get(opts, :invitees, 0)//1 do
      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        display_name: "Guest #{i}",
        email: "guest-#{i}-#{System.unique_integer([:positive])}@example.com"
      })
    end

    meeting
  end

  defp detail_path(meeting), do: "/meetings?" <> URI.encode_query(%{meeting: meeting.id})

  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)

  @detail "[data-role=meetings-detail]"

  # ── Who sees the control ─────────────────────────────────────────────────

  describe "the cancel row" do
    test "the creator sees it at the bottom of the detail", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))

      assert has_element?(view, @detail <> " [data-role=meeting-cancel-row]", "Cancel meeting")
      refute has_element?(view, "[data-role=meeting-cancel-confirm]")
      assert has_element?(view, @detail <> " [data-role=meetings-detail-open]")
    end

    test "an org admin sees it; a plain member sees nothing and a forged confirm changes nothing",
         %{conn: conn, project: project, creator: creator, plain: plain, org_id: org_id} do
      meeting = meeting!(project, creator)

      {:ok, view, _} = live(conn_for(conn, plain), detail_path(meeting))

      # The detail rendered (positive control), and it carries no control.
      assert has_element?(view, @detail <> " [data-meeting-id='#{meeting.id}']")
      refute has_element?(view, "[data-role=meeting-cancel-row]")

      render_click(view, "cancel_meeting_open", %{})
      refute has_element?(view, "[data-role=meeting-cancel-confirm]")

      render_click(view, "cancel_meeting_confirm", %{})
      render_async(view)

      assert reload(meeting).status == "scheduled"
      assert reload(meeting).cancelled_at == nil
      assert render(view) =~ "You can&#39;t cancel this meeting."

      admin = member!(org_id, "Admin", "admin")
      {:ok, admin_view, _} = live(conn_for(build_conn(), admin), detail_path(meeting))
      assert has_element?(admin_view, "[data-role=meeting-cancel-row]")
    end
  end

  # ── Confirming ────────────────────────────────────────────────────────────

  describe "the confirm inset" do
    test "names three invitees", %{conn: conn, project: project, creator: creator} do
      meeting = meeting!(project, creator, invitees: 3)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))

      view |> element("[data-role=meeting-cancel-row]") |> render_click()

      assert has_element?(view, "[data-role=meeting-cancel-confirm]", "Cancel this meeting?")

      assert has_element?(
               view,
               "[data-role=meeting-cancel-audience]",
               "3 people were invited. They'll be told it's cancelled."
             )

      assert has_element?(view, "[data-role=meeting-cancel-keep]", "Keep meeting")
      assert has_element?(view, "[data-role=meeting-cancel-submit]", "Cancel meeting")
      refute has_element?(view, "[data-role=meeting-cancel-row]")
    end

    test "says nobody else was invited for zero, and one person for one", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      nobody = meeting!(project, creator, name: "Solo")
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(nobody))
      render_click(view, "cancel_meeting_open", %{})

      assert has_element?(
               view,
               "[data-role=meeting-cancel-audience]",
               "Nobody else was invited."
             )

      refute render(view) =~ "be told it"

      one = meeting!(project, creator, name: "Pair", invitees: 1)
      {:ok, view, _} = live(conn_for(build_conn(), creator), detail_path(one))
      render_click(view, "cancel_meeting_open", %{})

      assert has_element?(
               view,
               "[data-role=meeting-cancel-audience]",
               "1 person was invited. They'll be told it's cancelled."
             )
    end

    test "Keep meeting and Escape both collapse it without cancelling", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))

      render_click(view, "cancel_meeting_open", %{})
      view |> element("[data-role=meeting-cancel-keep]") |> render_click()
      refute has_element?(view, "[data-role=meeting-cancel-confirm]")
      assert has_element?(view, "[data-role=meeting-cancel-row]")

      render_click(view, "cancel_meeting_open", %{})

      view
      |> element("[data-role=meeting-cancel-confirm]")
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "[data-role=meeting-cancel-confirm]")
      assert has_element?(view, @detail)
      assert reload(meeting).status == "scheduled"
    end

    test "focus moves to Keep meeting when the inset opens", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))
      render_click(view, "cancel_meeting_open", %{})

      [keep] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role=meeting-cancel-keep]")
        |> LazyHTML.attribute("phx-mounted")

      assert keep =~ "focus"
    end
  end

  # ── Confirm ───────────────────────────────────────────────────────────────

  describe "confirming" do
    test "cancels the selected meeting; the detail and the list row show it", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator, invitees: 2)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))

      render_click(view, "cancel_meeting_open", %{})
      view |> element("[data-role=meeting-cancel-submit]") |> render_click()
      render_async(view)

      assert reload(meeting).status == "cancelled"

      assert has_element?(view, @detail <> " [data-role=meeting-cancelled-chip]", "Cancelled")
      refute has_element?(view, "[data-role=meetings-detail-open]")
      refute has_element?(view, "[data-role=meeting-cancel-row]")
      refute has_element?(view, "[data-role=meeting-cancel-confirm]")

      row = "[data-role=workspace-meeting][data-meeting-id='#{meeting.id}']"
      assert has_element?(view, row <> " [data-role=meeting-cancelled-chip]")
      assert has_element?(
               view,
               row <> " [data-role=workspace-meeting-cancelled] strong",
               "Weekly sync"
             )

      # No toast on top of the chip.
      refute render(view) =~ "cancelled."
    end

    test "acts on the SELECTION, never on an id in the payload", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      selected = meeting!(project, creator, name: "Selected")
      other = meeting!(project, creator, name: "Other")
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(selected))

      render_click(view, "cancel_meeting_confirm", %{"id" => other.id, "meeting_id" => other.id})
      render_async(view)

      assert reload(other).status == "scheduled"
      assert reload(selected).status == "cancelled"
    end

    test "a forged confirm on an already-cancelled meeting changes nothing", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator)
      {:ok, cancelled} = Meetings.cancel_meeting_for_user(meeting.id, creator)

      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))
      refute has_element?(view, "[data-role=meeting-cancel-row]")
      assert has_element?(view, @detail <> " [data-role=meeting-cancelled-chip]")

      render_click(view, "cancel_meeting_confirm", %{})
      render_async(view)

      assert reload(meeting).cancelled_at == cancelled.cancelled_at
      html = render(view)
      refute html =~ "That didn&#39;t cancel"
      refute html =~ "You can&#39;t cancel this meeting."
    end

    test "a failed cancel keeps the inset open with the error line", %{
      conn: conn,
      project: project,
      creator: creator
    } do
      meeting = meeting!(project, creator)
      {:ok, view, _} = live(conn_for(conn, creator), detail_path(meeting))
      render_click(view, "cancel_meeting_open", %{})

      # The meeting ends under the open confirm without a broadcast, so the
      # cancel is refused as :not_cancellable.
      Repo.update!(Ecto.Changeset.change(reload(meeting), status: "ended"))

      view |> element("[data-role=meeting-cancel-submit]") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "[data-role=meeting-cancel-confirm] [data-role=meeting-cancel-error]",
               "That didn't cancel. Try again."
             )

      assert has_element?(view, "[data-role=meeting-cancel-keep]")
    end
  end

  # ── Calendar view ─────────────────────────────────────────────────────────

  describe "the calendar view" do
    test "the detail panel and sheet footers render the control for a permitted viewer", %{
      conn: conn,
      project: project,
      creator: creator,
      plain: plain
    } do
      zone = "America/Chicago"
      today = PlatformWeb.MeetingLive.calendar_today_date(zone)

      start =
        today |> DateTime.new!(~T[14:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")

      meeting = meeting!(project, creator, start: start, invitees: 3)

      {:ok, view, _} = live(conn_for(conn, creator, zone), "/meetings?view=calendar")
      render_click(view, "select_meeting", %{"id" => meeting.id})

      for footer <- ["meeting-detail-panel-footer", "meeting-detail-sheet-footer"] do
        assert has_element?(view, "[data-role=#{footer}] [data-role=meeting-cancel-row]")
        assert has_element?(view, "[data-role=#{footer}] [data-role=meeting-detail-open]")
      end

      render_click(view, "cancel_meeting_open", %{})

      assert has_element?(
               view,
               "[data-role=meeting-detail-panel-footer] [data-role=meeting-cancel-audience]",
               "3 people were invited."
             )

      {:ok, plain_view, _} = live(conn_for(build_conn(), plain, zone), "/meetings?view=calendar")
      render_click(plain_view, "select_meeting", %{"id" => meeting.id})
      assert has_element?(plain_view, "[data-role=meeting-detail-panel-footer]")
      refute has_element?(plain_view, "[data-role=meeting-cancel-row]")
    end
  end
end
