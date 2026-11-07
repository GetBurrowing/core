defmodule PlatformWeb.MeetingDeleteLiveTest do
  @moduledoc """
  Delete a cancelled or past meeting from /meetings and /calendar (task
  01a1b281 stage 4): `PlatformWeb.Components.Meetings.DeleteMeeting` driven
  by `PlatformWeb.MeetingLive` and `PlatformWeb.CalendarLive`.

  Every refusal is paired with a permitted viewer on the same fixture, so a
  control that never renders fails a named test instead of passing the
  negatives vacuously. Removal is asserted on OTHER open LiveViews (the
  invitee's list, archive and calendar), which only the
  `{:meeting_deleted, _}` broadcast can reach.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  @copy "Delete this meeting? It disappears from everyone's lists. Its transcript and recording are kept."

  setup do
    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Delete meeting #{n}",
        slug: "delete-meeting-#{n}",
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
        email: "delete-ui-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "delete-ui-#{n}"
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

  # A scheduled meeting the invitee holds a live invite to. Tomorrow 10:00
  # UTC unless `:start` says otherwise.
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

    Repo.insert!(%Invite{
      meeting_id: meeting.id,
      user_id: ctx.invitee.id,
      display_name: ctx.invitee.name
    })

    meeting
  end

  defp cancelled!(ctx, opts \\ []) do
    meeting = meeting!(ctx, opts)
    {:ok, cancelled} = Meetings.cancel_meeting_for_user(meeting.id, ctx.organizer)
    cancelled
  end

  # Status flipped in the row, the way the completion sweep leaves it.
  defp ended!(ctx, opts) do
    meeting = meeting!(ctx, opts)
    Repo.update!(Ecto.Changeset.change(meeting, status: "ended"))
  end

  # Yesterday 10:00 UTC, still `scheduled`: it never happened.
  defp past_scheduled!(ctx) do
    start = Date.utc_today() |> Date.add(-1) |> DateTime.new!(~T[10:00:00], "Etc/UTC")
    meeting!(ctx, start: start, name: "Missed sync")
  end

  # A complete transcript with segments, pinned to `meeting` the way the
  # FK (nilify_all) holds it.
  defp transcript!(meeting) do
    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: Ecto.UUID.generate(),
        space_id: Ecto.UUID.generate(),
        started_at: ~U[2026-04-10 14:00:00.000000Z],
        status: "complete"
      })

    {:ok, _} =
      Meetings.append_segment(transcript.id, %{
        "speaker_name" => "Sam",
        "text" => "Hello everyone, let's get started",
        "start_time" => 0,
        "end_time" => 3000,
        "final" => true
      })

    {:ok, _} =
      Meetings.append_segment(transcript.id, %{
        "speaker_name" => "Alex",
        "text" => "Sounds good, what's on the agenda?",
        "start_time" => 3500,
        "end_time" => 6000,
        "final" => true
      })

    {1, _} =
      from(t in Platform.Meetings.Transcript, where: t.id == ^transcript.id)
      |> Repo.update_all(set: [meeting_id: meeting.id])

    Meetings.get_transcript(transcript.id)
  end

  defp detail_path(meeting), do: "/meetings?" <> URI.encode_query(%{meeting: meeting.id})
  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)

  defp download(user, transcript) do
    conn = get(conn_for(user), "/api/transcripts/#{transcript.id}/download")
    {conn.status, conn.resp_body}
  end

  @detail "[data-role=meetings-detail]"
  @row "[data-role=meeting-delete-row]"
  @confirm "[data-role=meeting-delete-confirm]"
  @submit "[data-role=meeting-delete-submit]"

  defp list_row(meeting), do: "[data-role=workspace-meeting][data-meeting-id='#{meeting.id}']"
  defp archive_row(meeting), do: "[data-role=archive-row][data-meeting-id='#{meeting.id}']"

  # ── Who sees Delete ───────────────────────────────────────────────────────

  describe "the Delete action on /meetings" do
    test "a cancelled meeting: the organizer sees Delete and no Edit; the invitee sees none",
         ctx do
      meeting = cancelled!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      assert has_element?(view, @detail <> " [data-meeting-id='#{meeting.id}']")
      assert has_element?(view, @detail <> " " <> @row, "Delete meeting")
      refute has_element?(view, "[data-role=meeting-edit-open]")
      refute has_element?(view, "[data-role=meeting-cancel-row]")

      {:ok, invitee_view, _} = live(conn_for(ctx.invitee), detail_path(meeting))
      # Positive control: the invitee's detail did render this meeting.
      assert has_element?(invitee_view, @detail <> " [data-meeting-id='#{meeting.id}']")
      refute has_element?(invitee_view, @row)
    end

    test "an ended meeting and a scheduled one whose time has passed both carry Delete", ctx do
      for meeting <- [ended!(ctx, name: "Ran already"), past_scheduled!(ctx)] do
        {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
        assert has_element?(view, @detail <> " [data-meeting-id='#{meeting.id}']")
        assert has_element?(view, @detail <> " " <> @row, "Delete meeting")
        refute has_element?(view, "[data-role=meeting-edit-open]")
      end
    end

    test "a future scheduled meeting shows no Delete, and a forged delete is refused", ctx do
      meeting = meeting!(ctx)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      # Positive control: the organizer does hold the surface Delete would sit on.
      assert has_element?(view, @detail <> " [data-role=meeting-edit-open]")
      refute has_element?(view, @row)

      render_click(view, "delete_meeting_open", %{})
      refute has_element?(view, @confirm)

      render_click(view, "delete_meeting_confirm", %{"id" => meeting.id})
      render_async(view)

      assert reload(meeting).deleted_at == nil
      refute_receive {:meeting_deleted, _}, 100
      assert has_element?(view, @detail <> " [data-meeting-id='#{meeting.id}']")
    end

    test "the invitee's forged delete on a cancelled meeting changes nothing", ctx do
      meeting = cancelled!(ctx)

      {:ok, view, _} = live(conn_for(ctx.invitee), detail_path(meeting))
      render_click(view, "delete_meeting_open", %{})
      refute has_element?(view, @confirm)

      render_click(view, "delete_meeting_confirm", %{})
      render_async(view)

      assert reload(meeting).deleted_at == nil
      refute_receive {:meeting_deleted, _}, 100
    end
  end

  # ── The inset ─────────────────────────────────────────────────────────────

  describe "the confirm inset" do
    test "carries the copy verbatim, and Keep it collapses it without deleting", ctx do
      meeting = cancelled!(ctx)
      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))

      view |> element(@detail <> " " <> @row) |> render_click()
      assert has_element?(view, @confirm, @copy)
      assert has_element?(view, @confirm <> " [data-role=meeting-delete-keep]", "Keep it")
      assert has_element?(view, @confirm <> " " <> @submit, "Delete")
      refute has_element?(view, @row)

      view |> element("[data-role=meeting-delete-keep]") |> render_click()
      refute has_element?(view, @confirm)
      assert has_element?(view, @row)
      assert reload(meeting).deleted_at == nil
    end

    test "a delete the server refuses collapses the inset with a flash", ctx do
      meeting = cancelled!(ctx)
      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      view |> element(@detail <> " " <> @row) |> render_click()

      # The meeting is put back on the calendar under the open confirm,
      # without a broadcast, so the delete is refused as :not_deletable.
      Repo.update!(Ecto.Changeset.change(reload(meeting), status: "scheduled"))

      view |> element(@submit) |> render_click()
      render_async(view)

      assert reload(meeting).deleted_at == nil
      refute has_element?(view, @confirm)
      assert render(view) =~ "You can&#39;t delete this meeting."
    end
  end

  # ── Confirming ────────────────────────────────────────────────────────────

  describe "confirming" do
    test "removes the row from the organizer's and the invitee's lists and archive, " <>
           "the room URL is not found, and the transcript still downloads",
         ctx do
      meeting = cancelled!(ctx, name: "Soon deleted")
      keeper = cancelled!(ctx, name: "Still here")
      transcript = transcript!(meeting)
      {200, body} = download(ctx.organizer, transcript)

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(meeting))
      {:ok, invitee_list, _} = live(conn_for(ctx.invitee), "/meetings")
      {:ok, invitee_archive, _} = live(conn_for(ctx.invitee), "/meetings?view=archive")
      {:ok, organizer_archive, _} = live(conn_for(ctx.organizer), "/meetings?view=archive")

      # Visible before, so each refutation below is about the delete.
      for v <- [view, invitee_list], do: assert(has_element?(v, list_row(meeting)))

      for v <- [invitee_archive, organizer_archive],
          do: assert(has_element?(v, archive_row(meeting)))

      view |> element(@detail <> " " <> @row) |> render_click()
      view |> element(@submit) |> render_click()
      render_async(view)

      deleted = reload(meeting)
      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_by_user_id == ctx.organizer.id
      assert_receive {:meeting_deleted, %Meeting{id: id}}
      assert id == meeting.id

      # The deleter's own page: selection dropped, row gone, the other row stays.
      assert_patch(view, "/meetings")
      refute has_element?(view, list_row(meeting))
      assert has_element?(view, list_row(keeper))
      refute has_element?(view, @confirm)

      # Every other open list, redrawn by the broadcast.
      refute has_element?(invitee_list, list_row(meeting))
      assert has_element?(invitee_list, list_row(keeper))
      refute has_element?(invitee_archive, archive_row(meeting))
      assert has_element?(invitee_archive, archive_row(keeper))
      refute has_element?(organizer_archive, archive_row(meeting))

      # A fresh mount agrees.
      {:ok, fresh, _} = live(conn_for(ctx.invitee), "/meetings?view=archive")
      refute has_element?(fresh, archive_row(meeting))

      # The room URL answers not found for both viewers.
      for user <- [ctx.organizer, ctx.invitee] do
        assert {:error, {:live_redirect, %{to: "/meetings", flash: flash}}} =
                 live(conn_for(user), "/meetings/#{meeting.slug}")

        assert %{"error" => "Meeting not found."} = flash
      end

      # The transcript is untouched and still downloads byte for byte.
      assert %{meeting_id: ^id} = Meetings.get_transcript(transcript.id)
      assert {200, ^body} = download(ctx.organizer, transcript)
    end

    test "acts on the SELECTION, never on an id in the payload", ctx do
      selected = cancelled!(ctx, name: "Selected")
      other = cancelled!(ctx, name: "Other")

      {:ok, view, _} = live(conn_for(ctx.organizer), detail_path(selected))
      render_click(view, "delete_meeting_open", %{})
      render_click(view, "delete_meeting_confirm", %{"id" => other.id, "meeting_id" => other.id})
      render_async(view)

      assert %DateTime{} = reload(selected).deleted_at
      assert reload(other).deleted_at == nil
    end
  end

  # ── Calendar view of /meetings ────────────────────────────────────────────

  describe "the calendar view" do
    test "the panel and sheet footers carry Delete for an ended meeting, organizer only", ctx do
      start = DateTime.utc_now() |> DateTime.add(-2 * 3600) |> DateTime.truncate(:second)
      meeting = ended!(ctx, start: %{start | second: 0}, minutes: 30)

      {:ok, view, _} = live(conn_for(ctx.organizer), "/meetings?view=calendar")
      render_click(view, "select_meeting", %{"id" => meeting.id})

      for footer <- ["meeting-detail-panel-footer", "meeting-detail-sheet-footer"] do
        assert has_element?(view, "[data-role=#{footer}] " <> @row)
        refute has_element?(view, "[data-role=#{footer}] [data-role=meeting-edit-open]")
      end

      {:ok, invitee_view, _} = live(conn_for(ctx.invitee), "/meetings?view=calendar")
      render_click(invitee_view, "select_meeting", %{"id" => meeting.id})
      assert has_element?(invitee_view, "[data-role=meeting-detail-panel-footer]")
      refute has_element?(invitee_view, @row)

      render_click(view, "delete_meeting_open", %{})
      view |> element("[data-role=meeting-detail-panel-footer] " <> @submit) |> render_click()
      render_async(view)

      assert %DateTime{} = reload(meeting).deleted_at
      refute has_element?(view, "[data-role=meeting-detail-panel-footer]")
      refute has_element?(invitee_view, "[data-role=meeting-detail-panel-footer]")
    end
  end

  # ── /calendar ─────────────────────────────────────────────────────────────

  describe "the /calendar details" do
    defp midday_zone do
      offset = 12 - DateTime.utc_now().hour

      cond do
        offset == 0 -> "Etc/UTC"
        offset > 0 -> "Etc/GMT-#{offset}"
        true -> "Etc/GMT+#{-offset}"
      end
    end

    # Earlier today in `zone` (09:00 local, when local noon is now), ended.
    defp cal_ended!(ctx, zone) do
      today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()
      start = today |> DateTime.new!(~T[09:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")
      ended!(ctx, start: start)
    end

    defp chip(meeting),
      do: "[data-role=calendar-week] .cal-ev[data-kind=meeting][phx-value-id='#{meeting.id}']"

    defp open_chip(view, meeting), do: view |> element(chip(meeting)) |> render_click()

    test "carry Delete for the organizer, and the confirm drops the block for every viewer",
         ctx do
      zone = midday_zone()
      meeting = cal_ended!(ctx, zone)

      {:ok, view, _} = live(conn_for(ctx.organizer, zone), "/calendar")
      {:ok, invitee_view, _} = live(conn_for(ctx.invitee, zone), "/calendar")
      assert has_element?(invitee_view, chip(meeting))

      open_chip(view, meeting)
      assert has_element?(view, "[data-role=calendar-details] " <> @row, "Delete meeting")
      refute has_element?(view, "[data-role=calendar-details] [data-role=meeting-edit-open]")

      view |> element("[data-role=calendar-details] " <> @row) |> render_click()
      assert has_element?(view, "[data-role=calendar-details] " <> @confirm, @copy)

      # Escape collapses the inset only; the details stay open.
      render_keydown(view, "escape", %{"key" => "Escape"})
      refute has_element?(view, @confirm)
      assert has_element?(view, "[data-role=calendar-details]")

      view |> element("[data-role=calendar-details] " <> @row) |> render_click()
      view |> element(@submit) |> render_click()
      render_async(view)

      assert %DateTime{} = reload(meeting).deleted_at
      refute has_element?(view, "[data-role=calendar-details]")
      refute has_element?(view, chip(meeting))
      refute has_element?(invitee_view, chip(meeting))
    end

    test "carry none for the invitee, and a forged delete does nothing", ctx do
      zone = midday_zone()
      meeting = cal_ended!(ctx, zone)

      {:ok, view, _} = live(conn_for(ctx.invitee, zone), "/calendar")
      open_chip(view, meeting)

      assert has_element?(view, "[data-role=calendar-details]", "Weekly sync")
      refute has_element?(view, @row)

      render_click(view, "delete_meeting_open", %{})
      refute has_element?(view, @confirm)

      render_click(view, "delete_meeting_confirm", %{"id" => meeting.id})
      render_async(view)

      assert reload(meeting).deleted_at == nil
      refute_receive {:meeting_deleted, _}, 100
      assert has_element?(view, chip(meeting))
    end

    test "a future scheduled meeting shows Edit, not Delete", ctx do
      zone = midday_zone()
      today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()
      start = today |> DateTime.new!(~T[15:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")
      meeting = meeting!(ctx, start: start)

      {:ok, view, _} = live(conn_for(ctx.organizer, zone), "/calendar")
      open_chip(view, meeting)

      assert has_element?(view, "[data-role=calendar-details] [data-role=meeting-edit-open]")
      refute has_element?(view, @row)

      render_click(view, "delete_meeting_open", %{})
      refute has_element?(view, @confirm)
      render_click(view, "delete_meeting_confirm", %{})
      render_async(view)
      assert reload(meeting).deleted_at == nil
    end
  end
end
