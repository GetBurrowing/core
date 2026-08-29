defmodule PlatformWeb.MeetingLiveCandidateStopTest do
  @moduledoc """
  The stop button as a HUMAN affordance (task 01a03fba stage 4).

  A test that only proves a flag can be set proves nothing about a
  button. So every assertion here goes through the rendered DOM: the
  control is found by `has_element?/2`, pressed with `render_click/1`,
  and the consequence is then read out of the DATABASE — because the
  claim being tested is that a click in one participant's browser stops
  a countdown that runs on the server.

  ## The pairing that makes it non-vacuous

  `stops the fire` and `fires when nobody clicks` are the same fixture,
  the same meeting, the same sweep and the same instant. The only
  difference between them is whether a human pressed the button. An
  implementation where the sweeper never fired would pass the first and
  fail the second; one where the stop did nothing would pass the second
  and fail the first.

  `async: false`: `Candidates.stop/3` runs inside the LiveView process
  and `CandidateSweeper.sweep/1` in the test process, and both need the
  same sandbox connection.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tasks.Task, as: WorkTask
  alias Platform.Tenancy.OrgMembership

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "candidate_stop_#{n}@example.com",
        name: "Stop Test User",
        oidc_sub: "oidc-candidate-stop-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp meeting!(user) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Stop Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Stop Meeting #{n}",
        slug: "stop-meeting-#{n}"
      })

    # A participant row for the VIEWER, so `:current_participant`
    # resolves and the stop can be attributed to a real id rather than
    # nil. This is what makes "with the human named" testable.
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {meeting, participant}
  end

  # Overdue on arrival: the countdown is 30s and no test is going to wait
  # for it, so the card is heard a minute ago and the sweep runs at the
  # real `now`. The timing arithmetic itself is bracketed with a number
  # in `Platform.Meetings.CandidateSweeperTest`.
  defp overdue_candidate!(meeting, text) do
    {:ok, candidate} =
      Candidates.record_heard(%{
        meeting_id: meeting.id,
        transcript_chunk_id: Ecto.UUID.generate(),
        evidence_quote: text,
        speaker: "alice",
        heard_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    candidate
  end

  defp tasks_for(project_id),
    do: Repo.all(from(t in WorkTask, where: t.project_id == ^project_id))

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  describe "the stop button" do
    setup %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      {meeting, participant} = meeting!(user)
      %{conn: conn, user: user, meeting: meeting, participant: participant}
    end

    test "renders for an armed candidate, naming what it will stop", %{
      conn: conn,
      meeting: meeting
    } do
      candidate = overdue_candidate!(meeting, "we should build the CSV export screen")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      assert has_element?(view, "[data-role=meeting-candidate-countdown-rail]")

      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{candidate.id}']"
             )

      assert view
             |> element("[data-role=meeting-candidate-countdown-rail]")
             |> render() =~ "CSV export screen"
    end

    test "a CLICK stops the fire — and the identical setup without the click fires",
         %{conn: conn, meeting: meeting, participant: participant} do
      stopped = overdue_candidate!(meeting, "we should build the CSV export screen")
      untouched = overdue_candidate!(meeting, "somebody rewrite the pricing page copy")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      # The human action. Not a context call — a click on a rendered
      # button, from an ordinary participant's session.
      view
      |> element("[data-role=meeting-candidate-stop][data-candidate-id='#{stopped.id}']")
      |> render_click()

      # The sweeper runs afterwards, in the test process, with the
      # LiveView's own opinion of the world irrelevant.
      fired_ids =
        DateTime.utc_now() |> then(&CandidateSweeper.sweep(now: &1)) |> Enum.map(& &1.id)

      # The refutation.
      refute stopped.id in fired_ids
      stopped_row = reload!(stopped)
      assert is_nil(stopped_row.task_id)
      assert stopped_row.closed_reason == :dismissed
      # And the human is named — from THIS socket's participant, never
      # from the click payload.
      assert stopped_row.closed_by_participant_id == participant.id

      # The control, in the same sweep: the card nobody clicked DID
      # fire. Without this the refutation above would pass under a
      # sweeper that never fires anything.
      assert untouched.id in fired_ids
      assert reload!(untouched).task_id

      assert [task] = tasks_for(meeting.project_id)
      assert task.title =~ "pricing page"
    end

    test "the stopped card leaves the rail, and the other one stays", %{
      conn: conn,
      meeting: meeting
    } do
      stopped = overdue_candidate!(meeting, "we should build the CSV export screen")
      kept = overdue_candidate!(meeting, "somebody rewrite the pricing page copy")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      view
      |> element("[data-role=meeting-candidate-stop][data-candidate-id='#{stopped.id}']")
      |> render_click()

      refute has_element?(
               view,
               "[data-role=meeting-candidate][data-candidate-id='#{stopped.id}']"
             )

      refute has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{stopped.id}']"
             )

      # The control: the rail did not simply disappear.
      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{kept.id}']"
             )
    end

    test "clicking after the sweeper won says so instead of claiming success", %{
      conn: conn,
      meeting: meeting
    } do
      candidate = overdue_candidate!(meeting, "we should build the CSV export screen")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{candidate.id}']"
             )

      # It fires between the render and the click — the race the stop
      # button actually has to survive.
      assert [_] = CandidateSweeper.sweep(now: DateTime.utc_now())

      # The fire's own candidate event reaches this socket and the card
      # leaves the rail, which is the CORRECT behaviour and is why the
      # click below is sent as a raw event rather than through
      # `element/2`: the browser that is about to click has not
      # repainted yet, and that stale click is exactly the race being
      # tested. Asserting the removal first keeps this honest — the
      # event is not being sent at a button that never existed.
      refute has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{candidate.id}']"
             )

      html = render_click(view, "stop_candidate", %{"candidate_id" => candidate.id})

      assert html =~ "already went ahead"
      # The task really does exist, so the message is true.
      assert [_task] = tasks_for(meeting.project_id)
    end

    test "no rail at all when nothing is counting down", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      # The refutation. Its control is the first test in this describe
      # block, which finds the rail on the same route with one armed
      # candidate — so this cannot be passing because the selector is
      # wrong.
      refute has_element?(view, "[data-role=meeting-candidate-countdown-rail]")
    end

    test "a candidate from ANOTHER meeting cannot be stopped through this socket",
         %{conn: conn, meeting: meeting, user: user} do
      _mine = overdue_candidate!(meeting, "we should build the CSV export screen")

      {other, _} = meeting!(user)
      theirs = overdue_candidate!(other, "somebody rewrite the pricing page copy")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      render_click(view, "stop_candidate", %{"candidate_id" => theirs.id})

      # Untouched: still armed, still open, still stoppable by somebody
      # in ITS meeting.
      row = reload!(theirs)
      assert row.state == :heard
      assert %DateTime{} = row.acts_at
      assert is_nil(row.closed_by_participant_id)
    end
  end

  describe "the rail is not behind the meeting_producer gate" do
    test "it renders for a participant who cannot see the intents bar", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      {meeting, _participant} = meeting!(user)
      _candidate = overdue_candidate!(meeting, "we should build the CSV export screen")

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")

      # No `meeting_producer` role is assigned anywhere in this test, so
      # the intents bar is absent — that is the control proving the gate
      # really is closed here...
      refute has_element?(view, "[data-role=meeting-intent-mute-toggle]")

      # ...and the stop button is present anyway, which is the ticket's
      # "works from any participant's session".
      assert has_element?(view, "[data-role=meeting-candidate-stop]")
    end
  end
end
