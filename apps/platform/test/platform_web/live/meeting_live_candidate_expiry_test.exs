defmodule PlatformWeb.MeetingLiveCandidateExpiryTest do
  @moduledoc """
  What happens when NOBODY presses stop — the ticket's anti-vacuity
  clause for FE-9 (task 01a0740e-5f37-7001-97fc-10d21788beec, stage 1).

  ## Why this test exists next to the ones that already pass

  `meeting_live_candidate_stop_test.exs` proves an armed card renders a
  countdown and a stop button, and `meeting_live_candidate_board_test.exs`
  proves the ring's number differs per card. Both render a card that is
  still counting down. Neither of them lets the deadline PASS, so an
  implementation in which the 30 seconds simply never end would pass
  every one of them: the ring would draw, the number would tick, and
  nothing would ever happen. The countdown's whole meaning is that
  silence becomes consent at the end of it, and that end is the part
  nothing was measuring from the rendered page.

  So this file arms one card, advances the clock past
  `Platform.Meetings.Countdown.countdown_seconds/0`, sweeps, and asserts
  both halves of what expiry means:

    1. **it graduated** — a `task_id` is stored on the row and the task
       row exists, and
    2. **the rail no longer offers stop for it** — the affordance that
       was there a second earlier is gone from the rendered page.

  ## The assertion that is deliberately NOT `state == :acting`

  `Candidates.claim_due/2` writes `state: :acting` as its own claim
  marker BEFORE anything is minted, and `Candidates.fire/1` documents
  that a failed mint leaves the row `:acting` and disarmed with no
  deliverable — the reading `CandidateDisplay.outcome_label/1` already
  records. So `state == :acting` is satisfied by a sweeper that claimed
  the row and then did nothing at all, which is the exact failure this
  test is here to catch. The stored deliverable id is the only fact that
  separates "the countdown ended" from "the countdown ended and
  something happened".

  ## Which half of the pair actually discriminates — MEASURED

  Both halves are asserted because the ticket asks for both, and they
  are not equally strong. Run against the named mutation (the sweeper's
  call into `Candidates.fire/1` replaced with `{:ok, candidate}`, so
  `graduate/2` is never reached), the row comes back
  `state: :acting, task_id: nil, canvas_id: nil` and:

    * the stored-id assertion FAILS, which is the test going red;
    * `state == :acting` would have PASSED, which is why the ticket
      forbids it;
    * the DOM refutation below also PASSES. `claim_due/2` nils `acts_at`
      in the same statement that sets `:acting`, and the rail draws stop
      only for `acts_at != nil`, so the button disappears whether or not
      anything was minted — the card simply falls back into review mode.

  So half 2 is a real claim about the page and NOT the load-bearing one.
  Do not delete half 1 on the grounds that the pair is redundant; the
  pair is not redundant, and half 2 alone measures nothing about
  graduation.

  ## The controls

  Every assertion below is paired, because a card that is missing from
  the page satisfies a `refute` for the wrong reason just as easily as
  for the right one:

    * **BEFORE the deadline** — the same fixture, swept one second
      early, fires nothing and still renders its stop button. Without
      this, a sweeper that fired everything unconditionally would pass
      the expiry assertions.
    * **A card that is not yet due** — armed later, present in the same
      render as the expired one. Without this, a rail that had stopped
      rendering stop buttons altogether would pass the refutation.

  `async: false`, matching its neighbours: the sweep runs in the test
  process and the mount in a LiveView process, and both need the same
  sandbox connection.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.CandidateSweeper
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tasks.Task, as: WorkTask
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "candidate_expiry_#{n}@example.com",
        name: "Expiry Test User",
        oidc_sub: "oidc-candidate-expiry-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp meeting!(user) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Expiry Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Expiry Meeting #{n}",
        slug: "expiry-meeting-#{n}"
      })

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    meeting =
      meeting |> Ecto.Changeset.change(host_participant_id: participant.id) |> Repo.update!()

    {meeting, participant}
  end

  # A card armed the way the live rail arms one, at a stated instant.
  #
  # `record_heard/1` writes the skeleton and derives `acts_at` from
  # `heard_at` through `Countdown.acts_at/1`, so the deadline under test
  # is the real 30 seconds and not a number this file chose. The clock is
  # then moved with `sweep(now:)` rather than by backdating the fixture,
  # which keeps "advance past the countdown" a statement about the
  # countdown.
  #
  # `create_or_attach/1` on the same chunk is the classification landing
  # a second or two later — `IntentQueue.Server.mirror_enqueue/3`'s exact
  # call. Required: `claim_due/2` passes over a card the classifier has
  # not answered for, so a skeleton alone would never fire and every
  # assertion below would pass for the wrong reason.
  defp armed_candidate!(meeting, text, speaker, spoken_at) do
    chunk_id = Ecto.UUID.generate()

    # `{:ok, _}` and not `{:attached, _}`: two utterances by the same
    # speaker inside the threading window join one card, and a fixture
    # that silently became one row would make the control below vanish.
    {:ok, candidate} =
      Candidates.record_heard(%{
        meeting_id: meeting.id,
        transcript_chunk_id: chunk_id,
        evidence_quote: text,
        speaker: speaker,
        outcome_kind: :artifact,
        heard_at: spoken_at
      })

    {:ok, _classified} =
      Candidates.create_or_attach(%{
        intent_id: Ecto.UUID.generate(),
        meeting_id: meeting.id,
        transcript_chunk_id: chunk_id,
        transcript_chunk_ids: [chunk_id],
        evidence_quote: text,
        speaker: speaker,
        classified_intent: "action_items",
        target_role: "meeting_scribe",
        state: :heard,
        queue_status: "queued",
        outcome_kind: :artifact,
        heard_at: spoken_at,
        last_utterance_at: spoken_at
      })

    reload!(candidate)
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp tasks_for(project_id),
    do: Repo.all(from(t in WorkTask, where: t.project_id == ^project_id))

  defp mount_board(conn, meeting) do
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")
    view
  end

  defp stop_button?(view, %MeetingCandidate{id: id}) do
    has_element?(view, "[data-role=meeting-candidate-stop][data-candidate-id='#{id}']")
  end

  setup %{conn: conn} do
    {conn, user} = authenticated_conn(conn)
    {meeting, participant} = meeting!(user)
    %{conn: conn, user: user, meeting: meeting, participant: participant}
  end

  describe "when the 30 seconds run out and nobody pressed stop" do
    test "the card graduates into a stored task and the rail stops offering stop for it",
         %{conn: conn, meeting: meeting} do
      spoken_at = DateTime.utc_now()
      countdown = Countdown.countdown_seconds()

      expiring =
        armed_candidate!(meeting, "we should build the CSV export screen", "alice", spoken_at)

      # Not due for another minute, and present in every render below.
      # This is what stops the refutation passing on a rail that had
      # simply stopped drawing stop buttons.
      not_yet_due =
        armed_candidate!(
          meeting,
          "somebody rewrite the pricing page copy",
          "bella",
          DateTime.add(spoken_at, 60, :second)
        )

      # The deadline really is the countdown module's number, applied to
      # the moment somebody spoke. Asserted rather than assumed, because
      # everything below is arithmetic on it.
      assert DateTime.compare(expiring.acts_at, DateTime.add(spoken_at, countdown, :second)) ==
               :eq

      # ── The control: ONE SECOND EARLY ──────────────────────────────
      #
      # Same fixture, same sweeper, same meeting. The only difference
      # between this and the run below is the instant. A sweeper that
      # fired regardless of the deadline passes the expiry assertions
      # and fails here.
      early = DateTime.add(spoken_at, countdown - 1, :second)

      assert CandidateSweeper.sweep(now: early) == []
      assert is_nil(reload!(expiring).task_id)
      assert %DateTime{} = reload!(expiring).acts_at

      view = mount_board(conn, meeting)
      assert stop_button?(view, expiring)
      assert stop_button?(view, not_yet_due)

      # ── Past the deadline ──────────────────────────────────────────
      late = DateTime.add(spoken_at, countdown + 1, :second)

      fired = CandidateSweeper.sweep(now: late)
      assert Enum.map(fired, & &1.id) == [expiring.id]

      # HALF 1 — it graduated. The STORED deliverable id, never
      # `state == :acting`: `claim_due/2` writes that state as its own
      # claim marker before anything is minted, and `fire/1` leaves it
      # behind on a mint that failed. The id is the only column that
      # says something was actually created.
      graduated = reload!(expiring)

      refute is_nil(graduated.canvas_id),
             "the countdown ended and nothing was created: the row is " <>
               "#{graduated.state} with no task_id and no canvas_id"

      assert canvas = Repo.get(Platform.Chat.Canvas, graduated.canvas_id)
      assert canvas.title =~ "CSV export"
      assert tasks_for(meeting.project_id) == []

      # HALF 2 — the rail no longer offers stop for it. Rendered fresh
      # from the database rather than waiting on a PubSub frame, so the
      # claim is about what the page draws for a graduated card.
      after_view = mount_board(conn, meeting)
      refute stop_button?(after_view, expiring)

      # The control, in the SAME render: the card whose deadline has not
      # arrived is still stoppable. Without it the refutation above is
      # satisfied by a rail that renders nothing.
      assert stop_button?(after_view, not_yet_due)
      assert is_nil(reload!(not_yet_due).task_id)
    end
  end
end
