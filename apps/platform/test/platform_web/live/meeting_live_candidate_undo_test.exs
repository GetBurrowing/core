defmodule PlatformWeb.MeetingLiveCandidateUndoTest do
  @moduledoc """
  The ten-second undo a stop leaves in the slot the card was in (task
  01a0740e stage 5).

  ## Everything here goes through the rendered DOM

  The same posture `meeting_live_candidate_stop_test.exs` sets out: a
  test that proves a flag can be set proves nothing about a control. So
  the stop is a `render_click/3` on a rendered button, the undo is a
  click on the button that stop produced, and what is asserted is the
  markup a participant is actually looking at plus the row Postgres
  actually holds.

  ## The two claims, and why each carries a control

    * **Where it goes.** The spent row is drawn where the card was, so
      the eye that was on the card finds the undo. The fixture arms two
      cards with deadlines 5 and 20 seconds out and stops the SOONER
      one, which belongs at the TOP — an implementation that appended
      the spent row would put it second and this test would fail. The
      control is the same rail before the click, which already reads
      soonest-first.

    * **What comes back.** A stop that is undone hands the card to an
      explicit human decision rather than resuming a countdown, so the
      restored card carries `Not now` / `Go ahead` and NO count. The
      controls are asserted present AND the countdown absent, because an
      absence assertion on its own is satisfied by a rail that drew
      nothing at all — so the countdown is asserted PRESENT before the
      stop, on the same card, in the same test.

  `async: false`: the click runs `Candidates.stop/3` and
  `Candidates.reopen/2` inside the LiveView process against the test's
  sandbox connection.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "candidate_undo_#{n}@example.com",
        name: "Undo Test User",
        oidc_sub: "oidc-candidate-undo-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Undo Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Undo Meeting #{n}",
        slug: "undo-meeting-#{n}"
      })

    # A participant row for the VIEWER, so the stop and the undo are both
    # attributed to a real id rather than to nil.
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      meeting: meeting,
      participant: participant
    }
  end

  # An armed card at `:shaping` — classified, routed, and past the point
  # where the board offers a human gate. `secs` is how far out its
  # deadline sits, which is the rail's whole sort key.
  defp armed!(meeting, text, secs) do
    {:ok, candidate} =
      Candidates.create(%{
        meeting_id: meeting.id,
        evidence_quote: text,
        speaker: "alice",
        classified_intent: "action_items",
        target_role: "meeting_scribe",
        state: :shaping,
        outcome_kind: :task,
        acts_at: DateTime.add(DateTime.utc_now(), secs, :second)
      })

    candidate
  end

  defp rail_html(view),
    do: view |> element("[data-role=meeting-candidate-countdown-rail]") |> render()

  # Every ROW the rail draws, live cards and spent rows alike, in
  # document order.
  defp row_order(view) do
    view
    |> rail_html()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "[data-role='meeting-candidate-card'], [data-role='meeting-candidate-spent']"
    )
    |> LazyHTML.attribute("data-candidate-id")
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  describe "stop leaves an undo where the card was" do
    test "the spent row takes the stopped card's slot and offers no stop control", %{
      conn: conn,
      meeting: meeting
    } do
      soonest = armed!(meeting, "we should rotate the staging secrets", 5)
      later = armed!(meeting, "somebody rewrite the pricing page copy", 20)

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

      # THE CONTROL, before anything is clicked: two live cards,
      # soonest-first, each with its own stop.
      assert row_order(view) == [soonest.id, later.id]

      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{soonest.id}']"
             )

      render_click(view, "stop_candidate", %{"candidate_id" => soonest.id})

      # The row moved to `:closed` in Postgres — the stop really happened
      # and the spent row is not a card that simply stayed put.
      stopped = reload!(soonest)
      assert stopped.state == :closed
      assert stopped.closed_reason == :dismissed
      assert is_nil(stopped.acts_at)

      # SAME POSITION. The spent row sits where the card was, above a
      # card whose deadline was always later.
      assert row_order(view) == [soonest.id, later.id]

      assert has_element?(
               view,
               "[data-role=meeting-candidate-spent][data-candidate-id='#{soonest.id}']"
             )

      assert has_element?(
               view,
               "[data-role=meeting-candidate-undo][data-candidate-id='#{soonest.id}']"
             )

      # No stop control on the spent row, and the still-armed card keeps
      # its own — which is what makes this an assertion about the row
      # rather than about a rail that lost every button.
      refute has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{soonest.id}']"
             )

      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{later.id}']"
             )

      assert rail_html(view) =~ "Stopped"
    end

    test "pressing Undo brings the card back DISARMED, for a decision", %{
      conn: conn,
      meeting: meeting
    } do
      candidate = armed!(meeting, "we should rotate the staging secrets", 12)

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

      # THE CONTROL: while it is armed the card counts down and carries
      # no review gate. Without this the two `refute`s after the undo
      # would pass against a rail that never drew a countdown at all.
      assert has_element?(
               view,
               "[data-role=meeting-candidate-countdown][data-candidate-id='#{candidate.id}']"
             )

      refute has_element?(
               view,
               "[data-role=meeting-candidate-approve][data-candidate-id='#{candidate.id}']"
             )

      render_click(view, "stop_candidate", %{"candidate_id" => candidate.id})
      render_click(view, "undo_stop_candidate", %{"candidate_id" => candidate.id})

      row = reload!(candidate)
      assert row.state == :shaping
      assert is_nil(row.closed_reason)
      assert is_nil(row.closed_by_participant_id)

      # DISARMED — restoring the deadline would fire the card the instant
      # the stop was undone.
      assert is_nil(row.acts_at)

      # So the card is back on the rail in REVIEW mode: an explicit
      # decision, and no clock.
      assert has_element?(
               view,
               "[data-role=meeting-candidate-card][data-candidate-id='#{candidate.id}']"
             )

      assert has_element?(
               view,
               "[data-role=meeting-candidate-approve][data-candidate-id='#{candidate.id}']"
             )

      assert has_element?(
               view,
               "[data-role=meeting-candidate-decline][data-candidate-id='#{candidate.id}']"
             )

      refute has_element?(
               view,
               "[data-role=meeting-candidate-countdown][data-candidate-id='#{candidate.id}']"
             )

      # The undo is spent: the row it was offered on is gone.
      refute has_element?(view, "[data-role=meeting-candidate-spent]")

      # And the reversal is on the card's own log.
      assert :countdown_undone in CandidateEvents.kinds_for_candidate(candidate.id)
    end

    test "a candidate from ANOTHER meeting cannot be reopened through this socket", %{
      conn: conn,
      meeting: meeting
    } do
      mine = armed!(meeting, "we should rotate the staging secrets", 12)

      {:ok, other_project} =
        Platform.Tasks.create_project(%{
          name: "Other Undo Project #{System.unique_integer([:positive])}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })

      {:ok, other} =
        Meetings.create_meeting(%{
          project_id: other_project.id,
          name: "Other Undo Meeting",
          slug: "other-undo-meeting-#{System.unique_integer([:positive])}"
        })

      theirs = armed!(other, "buy more staging capacity", 12)
      {:ok, _} = Candidates.stop(theirs, Ecto.UUID.generate())

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

      render_click(view, "undo_stop_candidate", %{"candidate_id" => theirs.id})

      # Untouched. Still closed, still carrying the stop's own reason.
      row = reload!(theirs)
      assert row.state == :closed
      assert row.closed_reason == :dismissed
      refute :countdown_undone in CandidateEvents.kinds_for_candidate(theirs.id)

      # And this socket's own card is exactly as it was.
      assert reload!(mine).state == :shaping
    end
  end
end
