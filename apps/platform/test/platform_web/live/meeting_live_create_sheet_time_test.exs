defmodule PlatformWeb.MeetingLiveCreateSheetTimeTest do
  @moduledoc """
  The new-meeting sheet's Start field (task 01a192d6 stage 2).

  Start is a text field parsed by `PlatformWeb.TimeEntry`, and the form is
  `novalidate`. A Start typed without AM/PM ("01:00") used to be read as
  1 AM by `Time.from_iso8601/1`, and a half-entered native `type=time`
  control blocked submit with a browser bubble ("Invalid value" in Safari)
  that the server never saw. Now the server answers with an inline message
  and writes no row.

  Every "no row" assertion is paired with a create on the same view, so a
  fixture that could never write a row cannot make a refusal look correct.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @zone "America/Chicago"
  @date ~D[2026-11-18]
  @needs_meridiem "Start time is incomplete — pick AM or PM."

  setup %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "time_entry_#{System.unique_integer([:positive])}@example.com",
        name: "Time Entry User",
        oidc_sub: "oidc-time-entry-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Time Entry Project #{System.unique_integer([:positive])}",
        slug: "time-entry-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    Repo.delete_all(Meeting)

    conn =
      conn
      |> init_test_session(current_user_id: user.id)
      |> put_connect_params(%{"timezone" => @zone})

    {:ok, conn: conn, project: project}
  end

  defp open_sheet(conn) do
    {:ok, view, _html} = live(conn, ~p"/meetings")
    _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
    view
  end

  defp submit(view, project, overrides) do
    params =
      Map.merge(
        %{
          "name" => "Planning",
          "project_id" => project.id,
          "date" => Date.to_iso8601(@date),
          "start_time" => "",
          "duration_minutes" => "30"
        },
        overrides
      )

    view
    |> form("#start-meeting-form", start_meeting: params)
    |> render_submit()
  end

  defp meeting_count, do: Repo.aggregate(Meeting, :count)

  defp one_pm_utc do
    @date |> DateTime.new!(~T[13:00:00], @zone) |> DateTime.shift_zone!("Etc/UTC")
  end

  describe "the form" do
    test "is novalidate, so the server, not a browser bubble, answers", %{conn: conn} do
      view = open_sheet(conn)
      assert has_element?(view, "#start-meeting-form[novalidate]")
    end

    test "renders Start as a text field with a 12-hour placeholder", %{conn: conn} do
      view = open_sheet(conn)

      assert has_element?(
               view,
               ~s(#meeting-create-start-time[type="text"][name="start_meeting[start_time]"][placeholder="1:00 PM"])
             )

      refute has_element?(view, ~s(#meeting-create-start-time[type="time"]))
    end
  end

  describe "a Start with no AM/PM" do
    test "with a date shows the AM/PM message and writes no row",
         %{conn: conn, project: project} do
      view = open_sheet(conn)
      before = meeting_count()

      html = submit(view, project, %{"start_time" => "01:00"})

      assert html =~ @needs_meridiem
      assert meeting_count() == before

      assert has_element?(view, ~s(#meeting-create-start-time[aria-invalid="true"]))
      assert has_element?(view, ~s(#meeting-create-start-time[value="01:00"]))

      # Positive control on the same view: completing the time writes a row.
      submit(view, project, %{"start_time" => "1:00 PM"})
      assert meeting_count() == before + 1
    end

    test "with no date still says pick AM or PM, not the pair error",
         %{conn: conn, project: project} do
      view = open_sheet(conn)
      before = meeting_count()

      html = submit(view, project, %{"date" => "", "start_time" => "01:00"})

      assert html =~ @needs_meridiem
      refute html =~ "Date and start time are required together."
      assert meeting_count() == before
    end
  end

  describe "a complete Start" do
    for typed <- ["1pm", "1:00 PM", "13:00"] do
      test "#{inspect(typed)} schedules 13:00 in the viewer's zone",
           %{conn: conn, project: project} do
        view = open_sheet(conn)

        html = submit(view, project, %{"start_time" => unquote(typed)})

        assert html =~ "Meeting created."
        assert [%Meeting{} = created] = Repo.all(Meeting)
        assert DateTime.compare(created.scheduled_start_at, one_pm_utc()) == :eq

        assert DateTime.compare(
                 created.scheduled_end_at,
                 DateTime.add(one_pm_utc(), 30 * 60, :second)
               ) == :eq

        refute has_element?(view, ~s(#meeting-create-start-time[aria-invalid="true"]))
      end
    end
  end

  describe "a half-typed date" do
    # A native date with no year posts "" under novalidate. The
    # DateEntryGuard hook sets `date_incomplete`; without the refusal below,
    # a blank Start would make this an unscheduled meeting.
    test "the date input carries the guard hook and its hidden flag", %{conn: conn} do
      view = open_sheet(conn)

      assert has_element?(
               view,
               ~s(#meeting-create-date[phx-hook="DateEntryGuard"][data-incomplete-flag="meeting-create-date-incomplete"])
             )

      assert has_element?(
               view,
               ~s(#meeting-create-date-incomplete[type="hidden"][name="start_meeting[date_incomplete]"])
             )
    end

    test "is refused, not read as an ad-hoc meeting", %{conn: conn, project: project} do
      view = open_sheet(conn)
      before = meeting_count()

      html = submit(view, project, %{"date" => "", "date_incomplete" => "true"})

      assert html =~ "Date is incomplete — pick the month, day and year."
      assert meeting_count() == before

      # Positive control: the same blank fields without the flag ARE the
      # supported ad-hoc create.
      submit(view, project, %{"date" => "", "date_incomplete" => ""})
      assert meeting_count() == before + 1
    end
  end

  describe "unchanged behaviour" do
    test "blank date and blank Start still create an ad-hoc meeting",
         %{conn: conn, project: project} do
      view = open_sheet(conn)

      submit(view, project, %{"date" => "", "start_time" => ""})

      assert [%Meeting{scheduled_start_at: nil, scheduled_end_at: nil}] = Repo.all(Meeting)
    end

    test "a blank name is still refused by the server under novalidate",
         %{conn: conn, project: project} do
      view = open_sheet(conn)
      before = meeting_count()

      html = submit(view, project, %{"name" => "", "start_time" => "1pm"})

      assert html =~ "Name is required."
      assert meeting_count() == before
    end
  end
end
