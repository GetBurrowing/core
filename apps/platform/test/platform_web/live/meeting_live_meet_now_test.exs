defmodule PlatformWeb.MeetingLiveMeetNowTest do
  @moduledoc """
  Two assertions the Meet now feature (task 01a0d4d5) needs that the
  ":index action — Meet now" block in `meeting_live_test.exs` does not make.

  Kept in a separate file rather than appended to that block because the
  block is also the regression control for the scheduling flow, and two
  agents were writing it concurrently while this was authored.

  1. CALENDAR PLACEMENT. The ticket's acceptance line is "it shows on the
     calendar at that time", and the plan called this out as the assertion
     that would catch Meet now being built as an ad-hoc create. Nothing in
     the existing block calls `list_meetings_in_range/3`. That query compares
     only `scheduled_start_at` and drops NULL rows by construction
     (`meetings.ex:566`), so a Meet now with nil times starts a real call and
     is invisible on the calendar forever — while still passing every
     "a meeting row exists" assertion.

  2. THE DURATION LITERAL. The existing duration assertion reads
     `PlatformWeb.MeetingLive.default_duration_minutes() * 60`, which is the
     vacuous form the plan explicitly ruled out: an expectation computed by
     the module under test holds for every value that module returns. Change
     the default to 5 and it still passes. This one spells 30.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "meet_now_cal_#{System.unique_integer([:positive])}@example.com",
        name: "Meet Now Calendar User",
        oidc_sub: "oidc-meet-now-cal-#{System.unique_integer([:positive])}"
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
        name: "Meet Now Calendar Project",
        slug: "meet-now-cal-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, conn: init_test_session(conn, current_user_id: user.id), project: project}
  end

  defp meet_now(conn) do
    # The FAB lives on the calendar and archive halves; the v4 list view
    # (task 01a18d9f stage 4) has its own `+ New meeting` modal.
    {:ok, view, _html} = live(conn, ~p"/meetings?view=calendar")
    _ = view |> element(~s([data-role="start-meeting-fab"])) |> render_click()
    _ = render_click(view, "meet_now", %{})
    view
  end

  test "the instant meeting is returned by the calendar's own window query",
       %{conn: conn, project: project} do
    _view = meet_now(conn)

    created = Repo.one!(Meeting)

    # Stated before the arithmetic so a nil-times regression fails saying
    # "scheduled_start_at is nil" rather than raising FunctionClauseError
    # from inside DateTime.add/3, which reads as a broken test.
    refute is_nil(created.scheduled_start_at)
    refute is_nil(created.scheduled_end_at)

    # Scoped to this test's project so the window query cannot be satisfied
    # by some other row that happens to sit in the same minute.
    found =
      Meetings.list_meetings_in_range(
        DateTime.add(created.scheduled_start_at, -60, :second),
        DateTime.add(created.scheduled_start_at, 60, :second),
        project_id: project.id
      )

    assert Enum.map(found, & &1.id) == [created.id]
  end

  test "the instant meeting runs for 30 minutes", %{conn: conn} do
    _view = meet_now(conn)

    created = Repo.one!(Meeting)

    refute is_nil(created.scheduled_start_at)
    refute is_nil(created.scheduled_end_at)

    # The literal, deliberately. `default_duration_minutes() * 60` here would
    # be an expectation the code under test supplies to itself.
    assert DateTime.diff(created.scheduled_end_at, created.scheduled_start_at, :second) ==
             30 * 60
  end
end
