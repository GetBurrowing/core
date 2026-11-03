defmodule PlatformWeb.CalendarLiveCancelMeetingTest do
  @moduledoc """
  Cancel meeting on /calendar, and the cancelled block that stays on the
  grid (task 01a19e7f stage 4).

  A new file rather than more cases in `calendar_live_test.exs`, so it does
  not collide with the live-invite work in that file; the fixtures are the
  minimal copies of its helpers. Every refusal is paired with a permitted
  viewer, and assertions key on `data-role` / `data-*` attributes.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access.Scope
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  setup do
    org_id = Platform.TenancyFixtures.acme_org_id()
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Calendar cancel #{n}",
        slug: "calendar-cancel-#{n}",
        org_id: org_id
      })

    zone = midday_zone()

    %{
      org_id: org_id,
      project: project,
      creator: member!(org_id, "Creator"),
      plain: member!(org_id, "Plain"),
      zone: zone,
      today: local_today(zone)
    }
  end

  # ── Fixtures (copied from calendar_live_test.exs) ────────────────────────

  # A zone where it is midday now, so "today" cannot roll over mid-test.
  defp midday_zone do
    offset = 12 - DateTime.utc_now().hour

    cond do
      offset == 0 -> "Etc/UTC"
      offset > 0 -> "Etc/GMT-#{offset}"
      true -> "Etc/GMT+#{-offset}"
    end
  end

  defp at(zone, date, hour, minute),
    do: date |> DateTime.new!(Time.new!(hour, minute, 0), zone) |> DateTime.shift_zone!("Etc/UTC")

  defp local_today(zone),
    do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "calendar-cancel-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "calendar-cancel-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{user_id: user.id, org_id: org_id, role: "member"})
    user
  end

  defp conn_for(user, zone) do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => zone})
  end

  defp meeting!(ctx, opts \\ []) do
    {h, m} = Keyword.get(opts, :start, {14, 0})
    minutes = Keyword.get(opts, :minutes, 60)
    start = at(ctx.zone, ctx.today, h, m)

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: ctx.project.id,
        name: Keyword.get(opts, :name, "Weekly sync"),
        created_by_user_id: ctx.creator.id,
        scheduled_start_at: start,
        scheduled_end_at: DateTime.add(start, minutes * 60)
      })

    for i <- 1..Keyword.get(opts, :invitees, 0)//1 do
      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        display_name: "Guest #{i}",
        email: "cal-guest-#{i}-#{System.unique_integer([:positive])}@example.com"
      })
    end

    meeting
  end

  defp grid_chip(meeting),
    do: "[data-role=calendar-week] .cal-ev[data-kind=meeting][phx-value-id='#{meeting.id}']"

  defp open_chip(view, meeting), do: view |> element(grid_chip(meeting)) |> render_click()

  @details "[data-role=calendar-details]"

  defp reload(meeting), do: Repo.get!(Meeting, meeting.id)

  # ── The control ───────────────────────────────────────────────────────────

  describe "the creator" do
    test "opens the chip, confirms, and the block stays on the grid as cancelled", ctx do
      meeting = meeting!(ctx, invitees: 3)
      {:ok, view, _} = live(conn_for(ctx.creator, ctx.zone), "/calendar")

      open_chip(view, meeting)
      assert has_element?(view, @details <> " [data-role=meeting-cancel-row]", "Cancel meeting")

      render_click(view, "cancel_meeting_open", %{})

      assert has_element?(
               view,
               @details <> " [data-role=meeting-cancel-audience]",
               "3 people were invited. They'll be told it's cancelled."
             )

      view |> element(@details <> " [data-role=meeting-cancel-submit]") |> render_click()
      render_async(view)

      assert reload(meeting).status == "cancelled"

      # Still in the grid, still a meeting block, now struck through.
      assert has_element?(view, grid_chip(meeting) <> "[data-cancelled=true]")
      assert has_element?(view, grid_chip(meeting) <> " [data-role=meeting-cancelled-chip]")
      refute has_element?(view, grid_chip(meeting) <> ".cal-live")
      assert has_element?(view, grid_chip(meeting) <> " b.line-through", "Weekly sync")

      # The details: the chip pill, no Join / Open, no cancel row.
      assert has_element?(view, @details <> " [data-role=meeting-cancelled-chip]", "Cancelled")
      refute has_element?(view, @details, "Join now")
      refute has_element?(view, @details, "Open meeting")
      assert has_element?(view, @details, "View in Meetings")
      refute has_element?(view, "[data-role=meeting-cancel-row]")
    end

    test "Escape while confirming collapses the inset and keeps the details open", ctx do
      meeting = meeting!(ctx)
      {:ok, view, _} = live(conn_for(ctx.creator, ctx.zone), "/calendar")

      open_chip(view, meeting)
      render_click(view, "cancel_meeting_open", %{})
      assert has_element?(view, "[data-role=meeting-cancel-confirm]")

      view |> element("[data-page=calendar]") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "[data-role=meeting-cancel-confirm]")
      assert has_element?(view, @details)
      assert has_element?(view, "[data-role=meeting-cancel-row]")

      # A second Escape, with nothing to collapse, closes the details.
      view |> element("[data-page=calendar]") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, @details)
      assert reload(meeting).status == "scheduled"
    end

    test "the confirm acts on the open details, never on an id in the payload", ctx do
      selected = meeting!(ctx, name: "Selected", start: {9, 0})
      other = meeting!(ctx, name: "Other", start: {15, 0})
      {:ok, view, _} = live(conn_for(ctx.creator, ctx.zone), "/calendar")

      open_chip(view, selected)

      render_click(view, "cancel_meeting_confirm", %{
        "id" => other.id,
        "meeting_id" => other.id
      })

      render_async(view)

      assert reload(other).status == "scheduled"
      assert reload(selected).status == "cancelled"
    end
  end

  describe "a plain org member" do
    test "sees no cancel row, and a forged confirm leaves the meeting scheduled", ctx do
      meeting = meeting!(ctx)
      {:ok, view, _} = live(conn_for(ctx.plain, ctx.zone), "/calendar")

      open_chip(view, meeting)
      # The details rendered (positive control) and carry no control.
      assert has_element?(view, @details <> "[data-kind=meeting]")
      refute has_element?(view, "[data-role=meeting-cancel-row]")

      render_click(view, "cancel_meeting_open", %{})
      refute has_element?(view, "[data-role=meeting-cancel-confirm]")

      render_click(view, "cancel_meeting_confirm", %{})
      render_async(view)

      assert reload(meeting).status == "scheduled"
      assert render(view) =~ "You can&#39;t cancel this meeting."
    end
  end

  # ── The grid ──────────────────────────────────────────────────────────────

  describe "a cancelled block on the grid" do
    test "a meeting cancelled more than 24h ago still renders in its slot", ctx do
      meeting = meeting!(ctx)
      {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, ctx.creator)

      Repo.update!(
        Ecto.Changeset.change(reload(meeting),
          cancelled_at: DateTime.add(DateTime.utc_now(), -3 * 86_400)
        )
      )

      {:ok, view, _} = live(conn_for(ctx.creator, ctx.zone), "/calendar")

      assert has_element?(view, grid_chip(meeting) <> "[data-cancelled=true]")
      assert has_element?(view, grid_chip(meeting) <> " [data-role=meeting-cancelled-chip]")
    end

    test "drops the chip on a narrow, shared-lane block and keeps the strike-through", ctx do
      wide = meeting!(ctx, name: "Wide cancelled", start: {9, 0})
      narrow = meeting!(ctx, name: "Narrow cancelled", start: {14, 0})
      _overlap = meeting!(ctx, name: "Overlapping", start: {14, 0})

      for m <- [wide, narrow], do: {:ok, _} = Meetings.cancel_meeting_for_user(m.id, ctx.creator)

      {:ok, view, _} = live(conn_for(ctx.creator, ctx.zone), "/calendar")

      # Positive control: the lone block carries the chip.
      assert has_element?(view, grid_chip(wide) <> " [data-role=meeting-cancelled-chip]")

      assert has_element?(view, grid_chip(narrow) <> "[data-cancelled=true]")
      assert has_element?(view, grid_chip(narrow) <> " b.line-through", "Narrow cancelled")
      refute has_element?(view, grid_chip(narrow) <> " [data-role=meeting-cancelled-chip]")
    end
  end

  # ── The list query ────────────────────────────────────────────────────────

  describe "Calendar.list_entries/4" do
    test "drops a long-cancelled meeting by default and keeps it with cancelled_meetings: :keep",
         ctx do
      meeting = meeting!(ctx)
      {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, ctx.creator)

      Repo.update!(
        Ecto.Changeset.change(reload(meeting),
          cancelled_at: DateTime.add(DateTime.utc_now(), -3 * 86_400)
        )
      )

      scope = Scope.for_user(ctx.creator)
      from = at(ctx.zone, ctx.today, 0, 0)
      to = DateTime.add(from, 86_400)

      ids = fn opts ->
        scope |> Platform.Calendar.list_entries(from, to, opts) |> Enum.map(& &1.id)
      end

      refute meeting.id in ids.([])
      assert meeting.id in ids.(cancelled_meetings: :keep)
    end

    test "booking availability does not count a cancelled meeting as busy", ctx do
      meeting = meeting!(ctx)
      busy_meeting = meeting!(ctx, name: "Still on", start: {9, 0})
      {:ok, _} = Meetings.cancel_meeting_for_user(meeting.id, ctx.creator)

      scope = Scope.for_user(ctx.creator)
      from = at(ctx.zone, ctx.today, 0, 0)
      to = DateTime.add(from, 86_400)

      assert {:ok, busy} =
               Platform.Calendar.Subscriptions.availability(scope, from, to, time_zone: ctx.zone)

      starts = Enum.map(busy, & &1.starts_at)
      assert busy_meeting.scheduled_start_at in starts
      refute meeting.scheduled_start_at in starts
    end
  end
end
