defmodule PlatformWeb.MeetingLiveCandidateCorrectionTest do
  @moduledoc """
  The correction panel's WIRING (task 01a0740e stage 2).

  Sibling to `meeting_live_candidate_stop_test.exs`, and the same
  discipline: the claim under test is that a click in one participant's
  browser writes a training example on the server, so every assertion
  lands on the DATABASE — a `meeting_intent_corrections` row read back
  with `Repo`, and the candidate reloaded — and never on a return value
  or an assign.

  ## Why that matters more here than anywhere else on this card

  A correction panel whose buttons write nothing passes every rendering
  test there is. It renders, it opens, it closes, the copy is right, and
  the classifier learns nothing forever. `Repo.aggregate(IntentCorrection,
  :count)` is the only assertion that can tell those two implementations
  apart, so it is in every test below, including the refusals — where the
  count that must not move is zero.

  ## The part-spent fixture

  `armed!/2` opens its card with FIVE seconds left, never thirty. The
  re-arm assertions cannot pass unless the deadline actually moved; a
  fixture already sitting at thirty would be green against a LiveView
  that never called `rearm/2` at all, which is precisely the defect that
  would make the panel feel like it costs the reader their window.

  `async: false`: the write runs inside the LiveView process and the
  assertions in the test process, and both need the same sandbox
  connection.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.MeetingLive

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "candidate_correct_#{n}@example.com",
        name: "Correction Test User",
        oidc_sub: "oidc-candidate-correct-#{n}"
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
        name: "Correction Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Correction Meeting #{n}",
        slug: "correction-meeting-#{n}"
      })

    # A participant row for the VIEWER, so `:current_participant`
    # resolves and the correction can be attributed to a real id rather
    # than nil. This is what makes "the actor is read off THIS socket"
    # testable at all.
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {meeting, participant}
  end

  defp insert_agent!(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    %Agent{}
    |> Agent.changeset(%{slug: slug, name: slug, status: "active", kind: "native"})
    |> Repo.insert!()
  end

  # An open card with FIVE seconds left, not thirty. See the moduledoc.
  defp armed!(meeting, agent, overrides \\ %{}) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            evidence_quote: "somebody should rotate the staging secrets",
            speaker: "alice",
            classified_intent: "action_items",
            assigned_agent_id: agent.id,
            assigned_agent_slug: agent.slug,
            target_role: "meeting_scribe",
            state: :shaping,
            outcome_kind: :artifact,
            acts_at: DateTime.add(DateTime.utc_now(), 5, :second)
          },
          overrides
        )
      )

    # A task override represents a pre-cutover row for task-to-artifact correction.
    candidate
    |> Ecto.Changeset.change(
      acts_at: Map.get(overrides, :acts_at, DateTime.add(DateTime.utc_now(), 5, :second))
    )
    |> Repo.update!()
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp correction_count, do: Repo.aggregate(IntentCorrection, :count)

  defp only_correction! do
    assert correction_count() == 1
    [row] = Repo.all(IntentCorrection)
    row
  end

  # The whole 30 seconds, not the five the fixture opened with. Bracketed
  # rather than equated because the write happens inside the LiveView
  # process at an instant this test does not hold.
  defp assert_full_window!(candidate) do
    remaining = DateTime.diff(candidate.acts_at, DateTime.utc_now())
    assert remaining > 5, "expected a re-armed window, got #{remaining}s"
    assert remaining <= Countdown.countdown_seconds()
    candidate
  end

  defp open_meeting(conn, meeting) do
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")
    view
  end

  setup %{conn: conn} do
    {conn, user} = authenticated_conn(conn)
    {meeting, participant} = meeting!(user)

    %{
      conn: conn,
      user: user,
      meeting: meeting,
      participant: participant,
      scribe: insert_agent!("scribe"),
      designer: insert_agent!("designer")
    }
  end

  describe "opening the panel" do
    test "gives the card its FULL countdown back", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      assert DateTime.diff(candidate.acts_at, DateTime.utc_now()) <= 5

      view = open_meeting(ctx.conn, ctx.meeting)
      render_click(view, "candidate_correct_open", %{"candidate_id" => candidate.id})

      # The signature element of this ticket, asserted on the server
      # state the rail draws from: opening the panel BUYS window rather
      # than spending it.
      assert_full_window!(reload!(candidate))

      # And opening a panel is not itself a correction. Nothing is
      # taught by looking.
      assert correction_count() == 0
    end

    test "a candidate belonging to another meeting is not re-armed", ctx do
      {other_meeting, _other_participant} = meeting!(ctx.user)
      foreign = armed!(other_meeting, ctx.scribe)
      before = reload!(foreign)

      view = open_meeting(ctx.conn, ctx.meeting)
      render_click(view, "candidate_correct_open", %{"candidate_id" => foreign.id})

      # Byte-for-byte, not a spot check: a click on a card belonging to
      # another meeting must write nothing and say nothing.
      assert reload!(foreign) == before
      refute has_element?(view, "[data-role=meeting-candidate-error]")
    end
  end

  describe "hand to another agent" do
    test "writes one :corrected / :wrong_target row and re-arms the card", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)

      view = open_meeting(ctx.conn, ctx.meeting)

      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.designer.id
      })

      row = only_correction!()
      assert row.correction == :corrected
      assert row.reason == :wrong_target
      assert row.corrected_target_agent_id == ctx.designer.id
      assert row.classified_target_agent_id == ctx.scribe.id
      assert row.meeting_id == ctx.meeting.id
      # Read off THIS socket, never the payload.
      assert row.actor_participant_id == ctx.participant.id

      # The card moved with it — the id AND the denormalized slug, which
      # is what the rail actually renders.
      corrected = assert_full_window!(reload!(candidate))
      assert corrected.assigned_agent_id == ctx.designer.id
      assert corrected.assigned_agent_slug == ctx.designer.slug
    end

    test "the actor is this socket's participant even when the payload names another", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      impostor = Ecto.UUID.generate()

      view = open_meeting(ctx.conn, ctx.meeting)

      # The crafted click. A `phx-value-` a page never emitted must not
      # attribute somebody else's correction.
      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.designer.id,
        "actor_participant_id" => impostor
      })

      row = only_correction!()
      assert row.actor_participant_id == ctx.participant.id
      refute row.actor_participant_id == impostor
    end
  end

  describe "make it a canvas instead" do
    test "writes one :corrected / :wrong_intent row and flips the outcome", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe, %{outcome_kind: :task})
      assert candidate.outcome_kind == :task

      view = open_meeting(ctx.conn, ctx.meeting)
      render_click(view, "candidate_correct_flip", %{"candidate_id" => candidate.id})

      row = only_correction!()
      assert row.correction == :corrected
      assert row.reason == :wrong_intent
      assert row.actor_participant_id == ctx.participant.id

      flipped = assert_full_window!(reload!(candidate))
      assert flipped.outcome_kind == :artifact
    end
  end

  describe "not an action" do
    test "writes one :removed_no_action / :not_actionable row and closes the card", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)

      view = open_meeting(ctx.conn, ctx.meeting)
      render_click(view, "candidate_correct_none", %{"candidate_id" => candidate.id})

      row = only_correction!()
      assert row.correction == :removed_no_action
      assert row.reason == :not_actionable
      assert row.actor_participant_id == ctx.participant.id

      # The one choice of the three that does NOT re-arm: a card a human
      # said was never an action has nothing to count down to.
      closed = reload!(candidate)
      assert closed.state == :closed
      assert closed.closed_reason == :dismissed
      assert closed.closed_by_participant_id == ctx.participant.id
      assert is_nil(closed.task_id)
    end
  end

  describe "a refused correction" do
    test "says so, writes nothing, and does not move the countdown", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      before = reload!(candidate)

      view = open_meeting(ctx.conn, ctx.meeting)

      # Naming the agent already on the card. `Candidates.correct/3`
      # refuses it as `:same_agent` BEFORE writing anything.
      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.scribe.id
      })

      # The corpus is silent AND the card did not move — including its
      # deadline, which a failed correction must never touch.
      assert correction_count() == 0
      assert reload!(candidate) == before

      # And the failure is SAID. A silently-swallowed refusal is the
      # exact bug that makes this feature vacuous: the participant walks
      # away believing they taught the classifier something.
      assert has_element?(view, "[data-role=meeting-candidate-error]")
    end

    test "an agent id naming no agent row is refused, not written", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      before = reload!(candidate)

      view = open_meeting(ctx.conn, ctx.meeting)

      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => Ecto.UUID.generate()
      })

      assert correction_count() == 0
      assert reload!(candidate) == before
      assert has_element?(view, "[data-role=meeting-candidate-error]")
    end
  end

  describe "another meeting's candidate" do
    test "writes nothing and says nothing, for every one of the three choices", ctx do
      {other_meeting, _} = meeting!(ctx.user)
      foreign = armed!(other_meeting, ctx.scribe)
      before = reload!(foreign)

      view = open_meeting(ctx.conn, ctx.meeting)

      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => foreign.id,
        "agent_id" => ctx.designer.id
      })

      render_click(view, "candidate_correct_flip", %{"candidate_id" => foreign.id})
      render_click(view, "candidate_correct_none", %{"candidate_id" => foreign.id})

      assert correction_count() == 0
      assert reload!(foreign) == before

      # Silent, not merely refused: an error message would tell a prober
      # that the id names a real row.
      refute has_element?(view, "[data-role=meeting-candidate-error]")
    end
  end

  describe "candidate_correction_agents/1" do
    test "maps an agent presence row to the AGENT id and its resolved name", ctx do
      agent = ctx.designer

      rows =
        [
          %Meetings.Participant{
            id: Ecto.UUID.generate(),
            agent_id: agent.id,
            agent: agent,
            metadata: %{}
          }
        ]
        |> Enum.map(&MeetingLive.meeting_participant_view_model/1)

      assert [%{id: id, name: name}] = MeetingLive.candidate_correction_agents(rows)

      # THE FIELD THAT MATTERS. `:participant_id` on this view-model is
      # the agent's own id and not the presence row's id — an exemplar
      # built from the row id would name a target that is not an agent,
      # and `Candidates.correct/3` would answer `:unknown_agent`.
      assert id == agent.id
      refute id == hd(rows).id
      assert name == agent.name
    end

    test "keeps only agents, drops unresolved names, and dedupes a rejoin", ctx do
      agent = ctx.designer

      twice = [
        %{participant_type: "agent", participant_id: agent.id, display_name: agent.name},
        %{participant_type: "agent", participant_id: agent.id, display_name: agent.name}
      ]

      others = [
        %{participant_type: "user", participant_id: ctx.user.id, display_name: "Alice"},
        # An orphaned presence row: `resolve_identity/1` answers nil, and
        # `Hand to <nothing>` is not a choice anybody can make.
        %{participant_type: "agent", participant_id: Ecto.UUID.generate(), display_name: nil}
      ]

      assert [%{id: id}] = MeetingLive.candidate_correction_agents(twice ++ others)
      assert id == agent.id
    end

    test "answers [] for a room with no agents at all", ctx do
      assert MeetingLive.candidate_correction_agents([]) == []

      assert MeetingLive.candidate_correction_agents([
               %{participant_type: "user", participant_id: ctx.user.id, display_name: "Alice"}
             ]) == []
    end
  end

  # ── The rendered control, clicked (task 01a0740e stage 2, part 2) ──────
  #
  # Every test above pushes its event with `render_click(view, event,
  # payload)`, which reaches the handler WITHOUT going through the DOM.
  # That is the right shape for asserting what a handler does, and it is
  # blind to the defect this stage's markup can introduce: a button that
  # renders with no `phx-click`, or with a `phx-value-` key the handler's
  # clause does not match, pushes nothing at all and the handler's
  # catch-all clause swallows it silently.
  #
  # `element(view, selector) |> render_click()` cannot be blind to it. The
  # selector has to FIND the button, LiveViewTest reads the event name and
  # the `phx-value-` attributes off the element it found, and the
  # assertion at the end is still the database. So these close the loop
  # between the markup this stage adds and the handlers part 1 added.

  # A live room with an agent present, which is what puts a reassign
  # option on the card: `:participants` is presence
  # (`build_meeting_participants/1` over
  # `Meetings.active_participants_for_space/1`), not durable membership,
  # so adding the agent to the chat space would NOT be enough.
  defp present_agent!(meeting, agent) do
    room =
      Repo.insert!(%Meetings.Room{
        space_id: meeting.chat_space_id,
        livekit_room_name: "correction-room-#{System.unique_integer([:positive])}",
        status: "active"
      })

    %Meetings.Participant{}
    |> Meetings.Participant.changeset(%{
      room_id: room.id,
      agent_id: agent.id,
      display_name: agent.name,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    room
  end

  defp click!(view, selector) do
    view |> element(selector) |> render_click()
  end

  defp pencil_selector(candidate),
    do: "[data-role=meeting-candidate-correct][data-candidate-id='#{candidate.id}']"

  defp choice_selector(role, candidate),
    do: "[data-role=#{role}][data-candidate-id='#{candidate.id}']"

  describe "clicking the RENDERED pencil and the RENDERED choices" do
    test "the pencil is on the card, opens the drawer, and re-arms through the DOM", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      # The drawer is SHUT to begin with, so the assertion after the click
      # is about the click.
      refute has_element?(view, choice_selector("meeting-candidate-correction-none", candidate))
      assert has_element?(view, pencil_selector(candidate))

      click!(view, pencil_selector(candidate))

      assert has_element?(view, choice_selector("meeting-candidate-correction-none", candidate))

      # The DATABASE, not the assign: the card really did get its window
      # back, and it got it from a click on a rendered element.
      assert_full_window!(reload!(candidate))

      # Nothing was written by merely looking. Opening the drawer is not a
      # correction and must not put an exemplar in the corpus.
      assert correction_count() == 0
    end

    test ~s(pressing the rendered "Not an action" writes the corpus row and closes the card),
         ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      before = correction_count()
      click!(view, pencil_selector(candidate))
      click!(view, choice_selector("meeting-candidate-correction-none", candidate))

      assert correction_count() == before + 1
      row = only_correction!()
      assert row.correction == :removed_no_action
      assert row.reason == :not_actionable
      assert row.actor_participant_id == ctx.participant.id

      closed = reload!(candidate)
      assert closed.state == :closed
      assert is_nil(closed.acts_at)
      # The stored vocabulary is NOT renegotiated by this ticket.
      assert closed.closed_reason == :dismissed
    end

    test "task evidence offers no pencil, conversion or countdown", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe, %{outcome_kind: :task})
      view = open_meeting(ctx.conn, ctx.meeting)
      refute has_element?(view, pencil_selector(candidate))
      refute has_element?(view, choice_selector("meeting-candidate-correction-flip", candidate))
      assert has_element?(view, "[data-role=meeting-candidate-evidence]")
      assert Enum.empty?(countdown_foot(render(view), candidate))
      assert correction_count() == 0
      assert reload!(candidate).task_id == nil
    end

    test "pressing the rendered reassign hands the card to the agent the BUTTON names", ctx do
      # Both agents present in the room. The card is on the scribe, so the
      # DESIGNER is the only option the drawer may offer, and the id the
      # click carries comes off the rendered element rather than from this
      # test.
      present_agent!(ctx.meeting, ctx.scribe)

      %Meetings.Participant{}
      |> Meetings.Participant.changeset(%{
        room_id: Meetings.get_active_room(ctx.meeting.chat_space_id).id,
        agent_id: ctx.designer.id,
        display_name: ctx.designer.name,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      click!(view, pencil_selector(candidate))

      reassign = choice_selector("meeting-candidate-correction-reassign", candidate)
      assert has_element?(view, reassign)

      # THE ASSIGNEE IS NOT OFFERED, and this is the assertion that makes
      # the click below unambiguous: there is exactly one reassign option
      # and it is the designer's.
      assert view |> element(reassign) |> render() =~ ctx.designer.name
      refute view |> element(reassign) |> render() =~ ctx.scribe.name

      click!(view, reassign)

      row = only_correction!()
      assert row.correction == :corrected
      assert row.reason == :wrong_target
      assert row.classified_target_agent_id == ctx.scribe.id
      assert row.corrected_target_agent_id == ctx.designer.id
      assert row.actor_participant_id == ctx.participant.id
      # Derived from the meeting, never passed by the caller.
      refute is_nil(row.org_id)

      moved = reload!(candidate)
      assert moved.assigned_agent_id == ctx.designer.id
      assert_full_window!(moved)
    end

    test "a REFUSED correction keeps the drawer open, says so, and writes nothing", ctx do
      # A nil-intent card is writable (stage 1 made it so), so the honest
      # guaranteed failure here is a reassign naming the agent already on
      # the card. It cannot be reached through the rendered drawer — the
      # assignee is filtered out — which is exactly why it is pushed
      # directly: the failure PATH still has to be right for the day a
      # broadcast repaints the roster under a reader mid-press.
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      click!(view, pencil_selector(candidate))
      before_card = reload!(candidate)

      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.scribe.id
      })

      assert correction_count() == 0

      # THE DRAWER STAYS OPEN. A correction that silently failed while the
      # panel closed underneath would leave the reader believing they had
      # taught the classifier something.
      assert has_element?(view, choice_selector("meeting-candidate-correction-none", candidate))

      # AND IT SAYS SO, at the element the rail already renders errors in.
      assert has_element?(view, "[data-role=meeting-candidate-error]")
      assert render(view) =~ "already the agent on this one"

      # The candidate is byte-for-byte what it was: same assignee, same
      # kind, same state, same deadline. In particular the countdown did
      # NOT jump.
      after_card = reload!(candidate)
      assert after_card.assigned_agent_id == before_card.assigned_agent_id
      assert after_card.outcome_kind == before_card.outcome_kind
      assert after_card.state == before_card.state
      assert after_card.acts_at == before_card.acts_at
    end

    test "the pencil is a TOGGLE: a second press shuts the drawer and writes nothing", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      click!(view, pencil_selector(candidate))
      assert has_element?(view, choice_selector("meeting-candidate-correction-none", candidate))

      # The same selector, pressed again. `aria-expanded` is a promise
      # that this collapses, and the event behind the pencil swaps to
      # `candidate_correct_close` to keep it.
      click!(view, pencil_selector(candidate))
      refute has_element?(view, choice_selector("meeting-candidate-correction-none", candidate))

      assert correction_count() == 0

      # Closing does NOT take the re-arm back: the seconds were given for
      # reading the card, and a reader who decided the card was right has
      # still done the reading.
      assert_full_window!(reload!(candidate))
    end
  end

  # ── THE WINDOW, AS THE READER SEES IT (task 01a0740e stage 3) ──────────
  #
  # Every re-arm assertion above lands on `acts_at` in Postgres. That is
  # the right column for "the server gave the window back" and it is
  # blind to the defect that decides whether this feature works for the
  # person looking at the card: a deadline that moved while the rendered
  # NUMBER did not. The count is what the reader is deciding against, so
  # these read it back out of the DOM.
  #
  # ## The fixture IS the clock advance, and there is no sleep
  #
  # `armed!/3` opens its card at `now + 5s`. That row is ARITHMETICALLY
  # THE SAME ROW as a thirty-second card twenty-five seconds into its
  # countdown: both carry `acts_at == now + 5`. So the card is already
  # "visibly part-way through" by construction, deterministically, with
  # no `Process.sleep/1` (house rule) and no time seam to invent. The
  # pre-press control in each test below MEASURES that rather than
  # assuming it.
  #
  # ## Why the count is bracketed and the deadline is exact
  #
  # `Countdown.remaining_seconds/2` is `DateTime.diff(acts_at, now,
  # :second)`, which truncates toward zero. `acts_at` is computed inside
  # the LiveView process from ITS `DateTime.utc_now()`, and the rail
  # renders against a `DateTime.utc_now()` read strictly afterwards, so
  # the rendered integer is 29 whenever any time at all has passed and 30
  # only if none has. `data-remaining == "30"` is therefore an assertion
  # that two clock reads land in the same microsecond: flaky, not strict,
  # and it would be a test that fails for a reason unrelated to its
  # claim. The exact claims are made where they can be — `data-acts-at`
  # is compared VERBATIM against the re-armed row here, and
  # `candidate_correction_test.exs` pins `remaining_seconds/2 ==
  # Countdown.countdown_seconds()` against a fixed `now`. What the
  # bracket must exclude is the vacuous implementation, and it does: a
  # card that was never re-armed renders 5.
  #
  # ## Why these press the event and not the drawer
  #
  # Opening the drawer RE-ARMS on its own (`candidate_correct_open`
  # calls `Candidates.rearm/2`; the test above pins it). So a test that
  # opens the drawer and then presses a choice cannot tell the
  # correction's re-arm from the opening's — it reads 30 either way, and
  # it stays GREEN with the re-arm deleted from `correct/3` entirely.
  # The first two cases below therefore push the event WITHOUT opening,
  # which is the only shape that isolates the claim. The third walks the
  # reader's real path and says in its own body that it cannot attribute
  # the re-arm, so nobody later mistakes it for the guard.

  defp countdown_foot(html, %MeetingCandidate{id: id}) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role='meeting-candidate-countdown'][data-candidate-id='#{id}']")
  end

  # `LazyHTML.query/2` descends the whole tree; `filter/2` matches only
  # the fragment's root nodes and would answer `[]` for this nested
  # `<time>`, which reads as "the count is not there".
  defp rendered_remaining(html, candidate) do
    html
    |> countdown_foot(candidate)
    |> LazyHTML.query("[data-role='meeting-candidate-remaining']")
    |> LazyHTML.attribute("data-remaining")
    |> List.first()
    |> then(fn
      nil -> flunk("no [data-role=meeting-candidate-remaining] on this card")
      value -> String.to_integer(value)
    end)
  end

  defp rendered_acts_at(html, candidate) do
    html
    |> countdown_foot(candidate)
    |> LazyHTML.attribute("data-acts-at")
    |> List.first()
  end

  # The two-sided claim: the number the reader is watching went from a
  # nearly spent card to a full one, and the deadline the client ticker
  # will count against is the row's own re-armed `acts_at`, verbatim.
  defp assert_rendered_full_window!(view, candidate, before) do
    assert before in 0..6,
           "the fixture must render a PART-SPENT card or this case proves nothing, got #{before}"

    html = render(view)
    after_remaining = rendered_remaining(html, candidate)

    assert after_remaining in (Countdown.countdown_seconds() - 1)..Countdown.countdown_seconds(),
           "expected the full window back on the rendered card, got #{after_remaining}"

    assert after_remaining > before

    # EXACT, because this one can be: the client hook ticks against
    # `data-acts-at`, so a card whose count was repainted from a stale
    # deadline would tick straight back down to five.
    reloaded = reload!(candidate)
    assert rendered_acts_at(html, candidate) == DateTime.to_iso8601(reloaded.acts_at)

    reloaded
  end

  describe "the rendered countdown comes back" do
    test "a reassign repaints the card at the FULL window, not the remainder", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      before = rendered_remaining(render(view), candidate)

      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.designer.id
      })

      moved = assert_rendered_full_window!(view, candidate, before)

      # The correction really happened, so the repaint is not a repaint
      # of nothing: one exemplar, and the card moved to the new agent.
      assert correction_count() == 1
      assert moved.assigned_agent_id == ctx.designer.id
    end

    test "a task-to-canvas correction renders only the new canvas timer", ctx do
      candidate = armed!(ctx.meeting, ctx.scribe, %{outcome_kind: :task})
      view = open_meeting(ctx.conn, ctx.meeting)
      assert Enum.empty?(countdown_foot(render(view), candidate))
      render_click(view, "candidate_correct_flip", %{"candidate_id" => candidate.id})
      flipped = assert_full_window!(reload!(candidate))
      assert flipped.outcome_kind == :artifact
      assert flipped.task_id == nil
      assert DateTime.compare(flipped.acts_at, candidate.acts_at) == :gt

      assert rendered_remaining(render(view), candidate) in (Countdown.countdown_seconds() - 1)..Countdown.countdown_seconds()

      assert rendered_acts_at(render(view), candidate) == DateTime.to_iso8601(flipped.acts_at)
      assert correction_count() == 1
    end

    test "the reader's whole path never shows the window shrink", ctx do
      # The literal interaction the ticket describes: a part-spent card,
      # the pencil, then a correction. It is here because it is what a
      # participant does, NOT because it carries the re-arm claim — it
      # cannot. `candidate_correct_open` re-arms too, so this case reads
      # 30 after the second press whether or not `correct/3` re-arms at
      # all. The two cases above are the guard; this one is the journey.
      room = present_agent!(ctx.meeting, ctx.scribe)

      %Meetings.Participant{}
      |> Meetings.Participant.changeset(%{
        room_id: room.id,
        agent_id: ctx.designer.id,
        display_name: ctx.designer.name,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      assert rendered_remaining(render(view), candidate) in 0..6

      click!(view, pencil_selector(candidate))
      opened = rendered_remaining(render(view), candidate)
      assert opened in (Countdown.countdown_seconds() - 1)..Countdown.countdown_seconds()

      click!(view, choice_selector("meeting-candidate-correction-reassign", candidate))

      assert_full_window!(reload!(candidate))
      assert reload!(candidate).outcome_kind == :artifact
      assert reload!(candidate).assigned_agent_id == ctx.designer.id

      assert correction_count() == 1
    end

    test "a REFUSED correction leaves the rendered countdown exactly where it was", ctx do
      # THE NEGATIVE CONTROL for the instrument above. A reader who is
      # told their correction failed must not also be shown a card that
      # bought thirty seconds, and an assertion that can only ever say
      # "30" would pass against an implementation that re-armed on
      # failure too. The drawer is deliberately NOT opened, for the same
      # reason as the two guards above: opening it would re-arm the card
      # and this case would have nothing left to measure.
      candidate = armed!(ctx.meeting, ctx.scribe)
      view = open_meeting(ctx.conn, ctx.meeting)

      before_html = render(view)
      before = rendered_remaining(before_html, candidate)
      assert before in 0..6

      # Refused in `plan_correction/3`, before the corpus write: naming
      # the agent already on the card.
      render_click(view, "candidate_correct_reassign", %{
        "candidate_id" => candidate.id,
        "agent_id" => ctx.scribe.id
      })

      after_html = render(view)

      assert correction_count() == 0
      assert rendered_remaining(after_html, candidate) == before
      assert rendered_acts_at(after_html, candidate) == rendered_acts_at(before_html, candidate)

      assert rendered_acts_at(after_html, candidate) ==
               DateTime.to_iso8601(reload!(candidate).acts_at)

      # And it SAYS so, rather than failing silently at a card that did
      # not move.
      assert has_element?(view, "[data-role=meeting-candidate-error]")
    end
  end
end
