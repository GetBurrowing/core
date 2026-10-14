defmodule Platform.Meetings.CountdownTest do
  @moduledoc """
  The server-side countdown's arming arithmetic, its extension signal
  and the stop button (task 01a03fba stages 1, 2 and 4).

  ## Every timing claim here is a NUMBER

  "The countdown fires" and "the countdown never fires" both pass a test
  that only asks whether something eventually happened. So no assertion
  in this file is satisfied by an event merely occurring: arming asserts
  `DateTime.diff/3 == 30`, extension asserts the deadline moved by
  exactly the seconds the utterance was late by, and the sweeper file's
  fire test brackets the deadline with a sweep one second before it and
  a sweep at it.

  ## Every refutation is armed against vacuity

  A `refute` whose subject cannot occur passes under every
  implementation. Each one here is paired with a positive control run
  through the SAME code path, and the pairing is stated at the call
  site:

    * "a different speaker does not extend" is paired with a same-speaker
      utterance that does, and additionally asserts a SECOND candidate
      was opened — so the refutation cannot be passing merely because the
      utterance was dropped on the floor.
    * "an `:off` meeting arms nothing" is paired with the identical call
      on an `:automated` meeting, which arms.
    * "a stopped card does not fire" is paired with an unstopped card in
      the same sweep, which does.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.ThreadResolver
  alias Platform.Repo

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Countdown Project #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Countdown Meeting #{n}",
        slug: "countdown-meeting-#{n}"
      })

    meeting
  end

  defp heard!(meeting, opts) do
    Candidates.record_heard(%{
      meeting_id: meeting.id,
      transcript_chunk_id: Ecto.UUID.generate(),
      evidence_quote: Keyword.get(opts, :text, "somebody should write up the onboarding funnel"),
      speaker: Keyword.get(opts, :speaker, "alice"),
      heard_at: Keyword.fetch!(opts, :at)
    })
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  # The classification the mirror lands on a skeleton a second or two
  # after `record_heard/1` writes it — `IntentQueue.Server.mirror_enqueue/3`'s
  # exact call, and the state the live rail actually leaves a card in.
  #
  # Opt-in rather than folded into `heard!/2`, because most of this file
  # is about the UNCLASSIFIED skeleton: it is armed at the moment
  # somebody spoke, and that is the behaviour under test. It is needed
  # wherever a test drives the SWEEPER, because a card the classifier has
  # not answered for is not eligible to graduate — see
  # `Candidates.claim_due/2`.
  defp classify!(%MeetingCandidate{} = card, opts \\ []) do
    card = reload!(card)

    {:ok, _} =
      Candidates.create_or_attach(%{
        intent_id: Ecto.UUID.generate(),
        meeting_id: card.meeting_id,
        transcript_chunk_id: card.transcript_chunk_id,
        transcript_chunk_ids: [card.transcript_chunk_id],
        evidence_quote: card.evidence_quote,
        speaker: card.speaker,
        classified_intent: Keyword.get(opts, :intent, "action_items"),
        target_role: Keyword.get(opts, :target_role, "meeting_scribe"),
        state: :heard,
        queue_status: "queued",
        outcome_kind: card.outcome_kind,
        heard_at: card.heard_at,
        last_utterance_at: card.last_utterance_at
      })

    reload!(card)
  end

  # ── The number ────────────────────────────────────────────────────────────

  describe "Countdown.countdown_seconds/0" do
    test "is 30, globally, and the arithmetic uses it" do
      # Harper, 2026-08-27: 30 seconds, GLOBAL. Pinned as a literal so a
      # silent change to the module attribute reddens here rather than
      # only in the behaviour of a sweeper nobody is watching.
      assert Countdown.countdown_seconds() == 30

      from = ~U[2026-08-29 10:00:00.000000Z]
      assert Countdown.acts_at(from) == ~U[2026-08-29 10:00:30.000000Z]
    end

    test "sits INSIDE the timeout a model call is allowed, and the two are bound" do
      # Task 01a06575 round 3, door 2, pinned as a number rather than a
      # comment. Three providers give one model call 60 seconds; the
      # countdown gives 30. So a classification taking 31 to 60 seconds
      # is inside what the HTTP client permits and outside what the
      # countdown tolerates, and the sweeper ticks every second.
      #
      # NEITHER NUMBER MOVES — 30s is Harper's review window, 60s is what
      # a real model call needs. What must not happen is the relationship
      # being re-created implicitly, so this reads both ends.
      for provider <- [
            Platform.Agents.Providers.Anthropic,
            Platform.Agents.Providers.OpenAI,
            Platform.Agents.Providers.Codex
          ] do
        assert provider.receive_timeout_ms() == Countdown.provider_receive_timeout_ms(),
               "#{inspect(provider)} no longer agrees with the timeout " <>
                 "Countdown documents itself against"
      end

      assert Countdown.provider_receive_timeout_ms() >
               Countdown.countdown_seconds() * 1_000,
             "the countdown now outlives a model call — the whole reason " <>
               "claim_due/2 refuses an unclassified candidate has changed"
    end

    test "acts_at/1 answers nil for a nil utterance time rather than defaulting to now" do
      # "We have no utterance time" and "act 30 seconds from this moment"
      # are different claims, and a caller must not be able to get the
      # second by accident. Without this clause an unarmable card would
      # silently acquire a deadline.
      assert Countdown.acts_at(nil) == nil
    end

    test "remaining_seconds/2 counts down and floors at zero" do
      acts_at = ~U[2026-08-29 10:00:30.000000Z]

      assert Countdown.remaining_seconds(acts_at, ~U[2026-08-29 10:00:00.000000Z]) == 30
      assert Countdown.remaining_seconds(acts_at, ~U[2026-08-29 10:00:29.000000Z]) == 1
      assert Countdown.remaining_seconds(acts_at, ~U[2026-08-29 10:00:30.000000Z]) == 0
      # Past the deadline. Zero, not a negative — a ring cannot render -4.
      assert Countdown.remaining_seconds(acts_at, ~U[2026-08-29 10:00:34.000000Z]) == 0
      assert Countdown.remaining_seconds(nil, DateTime.utc_now()) == nil
    end
  end

  describe "Countdown.warning_seconds/0" do
    test "is 5, and sits strictly inside the countdown" do
      # Pinned as a literal for the same reason 30 is: the threshold is a
      # design decision (task 01a0740e stage 3), not an implementation
      # detail, and a silent edit must redden here.
      assert Countdown.warning_seconds() == 5

      # The relation that makes the step a STEP. At or above the
      # countdown, every card is amber from the moment it is armed and
      # the warning stops distinguishing anything — which is exactly the
      # mutation `candidate_rail_test.exs` runs against the rail. The
      # module raises at compile time on the same condition; this is the
      # runtime half, so the invariant is stated where a reader of the
      # tests can see it.
      assert Countdown.warning_seconds() < Countdown.countdown_seconds()
      assert Countdown.warning_seconds() > 0
    end
  end

  # ── S1: automation_mode ───────────────────────────────────────────────────

  describe "Meetings.automation_mode/1 and set_automation_mode/2" do
    setup do: %{meeting: meeting!()}

    test "a new meeting is :automated, and :off is persisted on the row", %{meeting: meeting} do
      # The positive control for every "off blocks it" assertion below.
      # A getter hardcoded to :off would pass all of them and fail HERE.
      assert Meetings.automation_mode(meeting.id) == :automated
      assert is_nil(Repo.get!(Meetings.Meeting, meeting.id).intent_muted_at)

      assert {:ok, _} = Meetings.set_automation_mode(meeting, :off)

      # Read from the DATABASE, not from the returned struct — the
      # requirement is that the mode survives the process that set it.
      assert %DateTime{} = Repo.get!(Meetings.Meeting, meeting.id).intent_muted_at
      assert Meetings.automation_mode(meeting.id) == :off
    end

    test "switching back to :automated clears the row again", %{meeting: meeting} do
      {:ok, _} = Meetings.set_automation_mode(meeting, :off)
      assert Meetings.automation_mode(meeting.id) == :off

      assert {:ok, _} = Meetings.set_automation_mode(meeting.id, :automated)

      # A setter that only ever wrote :off would pass the test above and
      # fail this one.
      assert is_nil(Repo.get!(Meetings.Meeting, meeting.id).intent_muted_at)
      assert Meetings.automation_mode(meeting.id) == :automated
    end

    test "a SECOND process sees the change without being told", %{meeting: meeting} do
      {:ok, _} = Meetings.set_automation_mode(meeting, :off)

      # Not the test process. If `set_automation_mode/2` were a no-op that
      # only mutated the struct it returned — the exact mutation named for
      # this stage — this task would still read :automated.
      task = Task.async(fn -> Meetings.automation_mode(meeting.id) end)

      assert Task.await(task) == :off
    end

    test "it is ONE switch: automation_mode is the mute, not a second column",
         %{meeting: meeting} do
      # The decision recorded in this ticket's verification block. Two
      # master switches on one rail would immediately raise "which wins",
      # so the two vocabularies are asserted to be the same fact.
      {:ok, _} = Meetings.set_intent_muted(meeting, true)
      assert Meetings.automation_mode(meeting.id) == :off

      {:ok, _} = Meetings.set_automation_mode(meeting.id, :automated)
      refute Meetings.intent_muted?(meeting.id)
    end

    test "an unknown mode is refused rather than silently treated as :off", %{meeting: meeting} do
      assert {:error, :invalid_mode} = Meetings.set_automation_mode(meeting, :paused)
      assert Meetings.automation_mode(meeting.id) == :automated
    end
  end

  # ── S2: arming ────────────────────────────────────────────────────────────

  describe "arming a candidate" do
    setup do: %{meeting: meeting!()}

    test "record_heard/1 arms acts_at exactly 30s after the utterance", %{meeting: meeting} do
      at = DateTime.utc_now()

      assert {:ok, candidate} = heard!(meeting, at: at)

      candidate = reload!(candidate)

      assert %DateTime{} = candidate.acts_at
      # The number, not "something in the future".
      assert DateTime.diff(candidate.acts_at, at, :second) == 30
      assert DateTime.compare(candidate.acts_at, candidate.last_utterance_at) == :gt
    end

    test "a meeting with automation :off arms NOTHING, and the control arms", %{meeting: meeting} do
      {:ok, _} = Meetings.set_automation_mode(meeting, :off)

      at = DateTime.utc_now()
      assert {:ok, muted_card} = heard!(meeting, at: at, text: "we should ship the export")

      # The refutation.
      assert is_nil(reload!(muted_card).acts_at)

      # The positive control, through the SAME function on a meeting
      # whose only difference is the mode. Without this, an
      # implementation that never armed anything would pass above.
      other = meeting!()
      assert {:ok, live_card} = heard!(other, at: at, text: "we should ship the export")
      assert %DateTime{} = reload!(live_card).acts_at
    end

    test "a card opened while :off is NOT retroactively armed by switching on",
         %{meeting: meeting} do
      {:ok, _} = Meetings.set_automation_mode(meeting, :off)
      at = DateTime.add(DateTime.utc_now(), -300, :second)
      assert {:ok, card} = heard!(meeting, at: at)
      assert is_nil(reload!(card).acts_at)

      {:ok, _} = Meetings.set_automation_mode(meeting, :automated)

      # The landmine this avoids: if arming were only checked in the
      # sweep, this card's deadline would be five minutes in the past and
      # it would fire the instant somebody turned automation back on.
      assert is_nil(reload!(card).acts_at)
    end
  end

  # ── Arming is gated on having an audience (task 01a06575 stage 5) ─────────

  describe "a classification that reaches nobody is not armed" do
    setup do: %{meeting: meeting!()}

    test "create/1 with an off_topic classification arms nothing, and the control arms",
         %{meeting: meeting} do
      at = DateTime.utc_now()

      assert {:ok, small_talk} =
               Candidates.create(%{
                 meeting_id: meeting.id,
                 transcript_chunk_id: Ecto.UUID.generate(),
                 evidence_quote: "did you catch the game last night",
                 speaker: "bruno",
                 state: :heard,
                 outcome_kind: :task,
                 classified_intent: "off_topic",
                 target_role: "null",
                 heard_at: at,
                 last_utterance_at: at
               })

      assert is_nil(reload!(small_talk).acts_at)

      # The control, through the SAME function with the SAME shape and
      # one field different. Without it an implementation that armed
      # nothing at all would pass above.
      assert {:ok, real} =
               Candidates.create(%{
                 meeting_id: meeting.id,
                 transcript_chunk_id: Ecto.UUID.generate(),
                 evidence_quote: "we should make the dashboard load faster",
                 speaker: "alice",
                 state: :heard,
                 outcome_kind: :task,
                 classified_intent: "action_items",
                 target_role: "null",
                 heard_at: at,
                 last_utterance_at: at
               })

      assert %DateTime{} = reload!(real).acts_at
    end

    test "a skeleton with no classification yet IS armed", %{meeting: meeting} do
      # Deliberate. `record_heard/1` writes a card before the model has
      # answered, and the countdown is anchored to the moment somebody
      # spoke. Withholding the arming until classification would move
      # the deadline by the model's latency; the disarm below is what
      # handles small talk instead.
      assert {:ok, skeleton} = heard!(meeting, at: DateTime.utc_now())
      assert %DateTime{} = reload!(skeleton).acts_at
      assert is_nil(reload!(skeleton).classified_intent)
    end

    test "reconciling an off_topic classification onto an armed skeleton disarms it",
         %{meeting: meeting} do
      at = DateTime.utc_now()
      chunk_id = Ecto.UUID.generate()

      assert {:ok, skeleton} =
               Candidates.record_heard(%{
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 evidence_quote: "did you catch the game last night",
                 speaker: "bruno",
                 heard_at: at
               })

      # It counted down while the model was thinking.
      assert %DateTime{} = reload!(skeleton).acts_at

      # The classifier answers `off_topic`. This is the exact call
      # `IntentQueue.Server.mirror_enqueue/3` makes.
      assert {:ok, _} =
               Candidates.create_or_attach(%{
                 intent_id: Ecto.UUID.generate(),
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 transcript_chunk_ids: [chunk_id],
                 evidence_quote: "did you catch the game last night",
                 speaker: "bruno",
                 classified_intent: "off_topic",
                 target_role: "null",
                 state: :heard,
                 queue_status: "queued",
                 outcome_kind: :task,
                 heard_at: at,
                 last_utterance_at: at
               })

      reconciled = reload!(skeleton)

      assert reconciled.classified_intent == "off_topic"

      assert is_nil(reconciled.acts_at),
             "an off_topic card kept its deadline through classification — it is " <>
               "relying on the dispatcher to close it first, which is a race"

      # And it is not merely disarmed by accident of being closed:
      # `Candidates.close/2` does not nil `acts_at`, so a closed row
      # would still be carrying one.
      refute reconciled.state == :closed
    end

    test "an off_topic classification is disarmed even when it names a REAL role",
         %{meeting: meeting} do
      # `routable?/2` was `responsibility_key/1 != nil or routable_role?/1`,
      # and only the first half knows what `off_topic` means. The response
      # schema demands a `target_role` string on every answer, so an
      # `off_topic` naming `meeting_scribe` is ordinary model noise — and
      # it took the OR's second branch, armed the card, and minted this
      # exact sentence into `tasks` (task 01a06575).
      at = DateTime.utc_now()
      chunk_id = Ecto.UUID.generate()
      text = "did you catch the game last night, that last quarter was something"

      refute Candidates.routable_attrs?(%{
               classified_intent: "off_topic",
               target_role: "meeting_scribe"
             })

      assert {:ok, skeleton} =
               Candidates.record_heard(%{
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 evidence_quote: text,
                 speaker: "bruno",
                 heard_at: at
               })

      assert %DateTime{} = reload!(skeleton).acts_at

      assert {:ok, _} =
               Candidates.create_or_attach(%{
                 intent_id: Ecto.UUID.generate(),
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 transcript_chunk_ids: [chunk_id],
                 evidence_quote: text,
                 speaker: "bruno",
                 classified_intent: "off_topic",
                 # The role the model named. A VALID one.
                 target_role: "meeting_scribe",
                 state: :heard,
                 queue_status: "queued",
                 outcome_kind: :task,
                 heard_at: at,
                 last_utterance_at: at
               })

      reconciled = reload!(skeleton)

      assert reconciled.classified_intent == "off_topic"
      assert reconciled.target_role == "meeting_scribe"

      assert is_nil(reconciled.acts_at),
             "an off_topic card naming a real role kept its deadline — the role " <>
               "string on a decline is model noise, not routing"

      # Not disarmed merely by being closed: `close/2` leaves `acts_at`
      # standing, so a closed row would still carry one.
      refute reconciled.state == :closed
    end

    test "reconciling a ROUTABLE classification leaves the deadline alone",
         %{meeting: meeting} do
      at = DateTime.utc_now()
      chunk_id = Ecto.UUID.generate()

      assert {:ok, skeleton} =
               Candidates.record_heard(%{
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 evidence_quote: "we should make the dashboard load faster",
                 speaker: "alice",
                 heard_at: at
               })

      armed_at = reload!(skeleton).acts_at
      assert %DateTime{} = armed_at

      assert {:ok, _} =
               Candidates.create_or_attach(%{
                 intent_id: Ecto.UUID.generate(),
                 meeting_id: meeting.id,
                 transcript_chunk_id: chunk_id,
                 transcript_chunk_ids: [chunk_id],
                 evidence_quote: "we should make the dashboard load faster",
                 speaker: "alice",
                 classified_intent: "action_items",
                 # Unaddressed, which stage 3 made a correct answer. A
                 # null target must NOT cost a routable intent its card.
                 target_role: "null",
                 state: :heard,
                 queue_status: "queued",
                 outcome_kind: :task,
                 heard_at: at,
                 last_utterance_at: at
               })

      assert reload!(skeleton).acts_at == armed_at
    end

    test "routable_attrs?/1 answers on attrs alone, in both key spellings" do
      assert Candidates.routable_attrs?(%{})
      assert Candidates.routable_attrs?(%{classified_intent: nil})
      assert Candidates.routable_attrs?(%{classified_intent: "action_items"})
      assert Candidates.routable_attrs?(%{"classified_intent" => "action_items"})

      refute Candidates.routable_attrs?(%{classified_intent: "off_topic", target_role: "null"})
      refute Candidates.routable_attrs?(%{"classified_intent" => "off_topic"})

      # An intent with no responsibility row, routed by role instead.
      assert Candidates.routable_attrs?(%{
               classified_intent: "pull_numbers",
               target_role: "historian"
             })

      refute Candidates.routable_attrs?(%{
               classified_intent: "pull_numbers",
               target_role: "null"
             })
    end
  end

  # ── S2: extension ─────────────────────────────────────────────────────────

  describe "extending a countdown" do
    setup do: %{meeting: meeting!()}

    test "a threaded continuation pushes acts_at forward by exactly the gap",
         %{meeting: meeting} do
      at = DateTime.utc_now()

      assert {:ok, card} =
               heard!(meeting, at: at, text: "we should rewrite the onboarding funnel")

      first = reload!(card).acts_at

      later = DateTime.add(at, 8, :second)

      # Same speaker, inside `ThreadResolver`'s window, so this threads.
      card_id = card.id

      # The host comes back UPDATED, so the id is what identifies it —
      # pinning the whole struct would compare the pre-attachment row.
      assert {:attached, %{id: ^card_id}} =
               heard!(meeting,
                 at: later,
                 speaker: "alice",
                 text: "and the onboarding funnel copy needs a rewrite too"
               )

      extended = reload!(card).acts_at

      # The number: the deadline moved by the same 8 seconds the
      # utterance was late by, not merely "forward".
      assert DateTime.diff(extended, first, :second) == 8
      assert DateTime.diff(extended, later, :second) == 30
    end

    test "a DIFFERENT speaker does not extend — the deferred defect, pinned",
         %{meeting: meeting} do
      # `ThreadResolver.gate/3` is same-speaker-only and a nil speaker
      # never matches, so a colleague agreeing opens a new card instead of
      # extending the first. Widening that is the THREADING ticket's
      # decision (01a03fb9) — it would re-open the retraction gate's
      # "exactly one candidate survives" invariant — so it is deferred,
      # and this test is what makes the deferral a measured fact.
      at = DateTime.utc_now()

      # ANTI-VACUITY, and the reason these two strings are these two
      # strings: they are the IDENTICAL pair that the test above proves
      # DOES thread, from `alice` to `alice`. Only the speaker changes
      # here, so the sole thing standing between this utterance and an
      # extension is `same_speaker?/2`. Measured: with that predicate
      # forced to `true`, this test goes red — an earlier draft using a
      # different second string stayed green under the same mutation and
      # was therefore proving nothing.
      assert {:ok, card} =
               heard!(meeting,
                 at: at,
                 speaker: "alice",
                 text: "we should rewrite the onboarding funnel"
               )

      before = reload!(card).acts_at

      later = DateTime.add(at, 8, :second)

      # And it is not merely dropped on the floor: it opens its own
      # candidate, so the refutation below cannot be passing because
      # nothing was processed.
      assert {:ok, second} =
               heard!(meeting,
                 at: later,
                 speaker: "bob",
                 text: "and the onboarding funnel copy needs a rewrite too"
               )

      refute second.id == card.id
      assert %DateTime{} = reload!(second).acts_at

      # And the first card's deadline is byte-identical.
      assert reload!(card).acts_at == before
    end

    test "the two clocks do not compose: the threading window is double the countdown" do
      # Measured, not remembered. A same-speaker continuation at t=45s is
      # inside `@window_seconds` but arrives at a card that fired at
      # t=30s and closed, and a closed card is not in
      # `open_for_meeting/1`. Nothing is lost or double-acted, but it is
      # lossy — and it is lossy because two numbers were chosen
      # independently by two tickets. Pinned so that changing either one
      # forces a decision here.
      assert ThreadResolver.window_seconds() == 60
      assert Countdown.countdown_seconds() == 30
      assert ThreadResolver.window_seconds() > Countdown.countdown_seconds()
    end

    test "an attachment does NOT re-arm a card a human already stopped", %{meeting: meeting} do
      at = DateTime.utc_now()

      assert {:ok, card} =
               heard!(meeting, at: at, text: "we should rewrite the onboarding funnel")

      participant_id = Ecto.UUID.generate()
      assert {:ok, _} = Candidates.stop(card, participant_id)

      # A stopped card is closed, so it is out of `open_for_meeting/1`
      # and the resolver cannot even see it. Asserted at the row: the
      # deadline stays nil.
      assert is_nil(reload!(card).acts_at)

      assert {:ok, _second} =
               heard!(meeting,
                 at: DateTime.add(at, 8, :second),
                 speaker: "alice",
                 text: "and the onboarding funnel copy needs a rewrite too"
               )

      assert is_nil(reload!(card).acts_at)
    end
  end

  # ── S4: stop ──────────────────────────────────────────────────────────────

  describe "Candidates.stop/3" do
    setup do
      meeting = meeting!()
      {:ok, card} = heard!(meeting, at: DateTime.utc_now())
      %{meeting: meeting, card: card}
    end

    test "disarms, closes :dismissed, and NAMES the human", %{card: card} do
      participant_id = Ecto.UUID.generate()

      assert {:ok, stopped} = Candidates.stop(card, participant_id, actor_name: "Harper Parker")

      row = reload!(stopped)

      assert is_nil(row.acts_at)
      assert row.state == :closed
      assert row.closed_reason == :dismissed
      # The attribution is a REFERENCE, not a sentence somebody typed.
      assert row.closed_by_participant_id == participant_id
      assert row.closed_note =~ "Harper Parker"
    end

    test "a machine close leaves closed_by_participant_id nil, so non-nil means a person",
         %{meeting: meeting} do
      # The control that gives `closed_by_participant_id` its meaning. If
      # every close stamped it, the column would record nothing.
      {:ok, other} = heard!(meeting, at: DateTime.utc_now(), text: "unrelated thing entirely")
      {:ok, closed} = Candidates.close(other, :duplicate)

      assert is_nil(reload!(closed).closed_by_participant_id)
    end

    test "is idempotent: a second stop does not relabel the first", %{card: card} do
      {:ok, first} = Candidates.stop(card, Ecto.UUID.generate(), actor_name: "Harper")
      first = reload!(first)

      assert {:ok, _} = Candidates.stop(card, Ecto.UUID.generate(), actor_name: "Somebody Else")

      second = reload!(card)

      assert second.closed_at == first.closed_at
      assert second.closed_reason == first.closed_reason
      assert second.closed_by_participant_id == first.closed_by_participant_id
      assert second.closed_note == first.closed_note
    end

    test "narrates itself on the EXISTING candidate event stream", %{card: card} do
      Platform.Meetings.PubSub.subscribe_candidate_events(card.meeting_id)

      {:ok, _} = Candidates.stop(card, Ecto.UUID.generate())

      # Reused rather than a second mechanism: `914a980c` already
      # broadcasts every candidate write on this topic.
      assert_receive {:candidate_event, %{kind: :countdown_stopped}}

      kinds = CandidateEvents.kinds_for_candidate(card.id)
      assert :countdown_stopped in kinds
      assert :closed in kinds
    end

    test "an unknown candidate is not found, not silently accepted" do
      assert {:error, :not_found} = Candidates.stop(Ecto.UUID.generate(), nil)
    end
  end

  # ── S4: stop is SERVER-side ───────────────────────────────────────────────

  describe "stop survives the process that pressed it" do
    setup do: %{meeting: meeting!()}

    test "the caller is killed, the sweeper still runs, and nothing is minted",
         %{meeting: meeting} do
      at = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, stopped_card} = heard!(meeting, at: at, text: "we should build the export screen")

      {:ok, live_card} =
        heard!(meeting, at: at, speaker: "bob", text: "somebody redo the pricing page please")

      # Both have been through the classifier, as the live rail's cards
      # have by the time a 60-second-overdue deadline comes round.
      _ = classify!(stopped_card)
      _ = classify!(live_card)

      # Both are armed and both are already overdue.
      assert %DateTime{} = reload!(stopped_card).acts_at
      assert %DateTime{} = reload!(live_card).acts_at

      parent = self()

      # A separate process presses stop and then dies. This is the
      # ticket's actual claim — the countdown is server-side, so a stop
      # must outlive the session that issued it.
      {pid, ref} =
        spawn_monitor(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          {:ok, _} = Candidates.stop(stopped_card, Ecto.UUID.generate())
          send(parent, :stopped)

          receive do
            :never -> :ok
          end
        end)

      assert_receive :stopped, 2_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      # The stop's process is gone. Sweep.
      fired = Platform.Meetings.CandidateSweeper.sweep(now: DateTime.utc_now())
      fired_ids = Enum.map(fired, & &1.id)

      # The refutation...
      refute stopped_card.id in fired_ids
      assert is_nil(reload!(stopped_card).task_id)

      # ...and the positive control that makes it non-vacuous. The very
      # same sweep, on the very same meeting, fired the card nobody
      # stopped. A sweeper that fired nothing at all would fail here.
      assert live_card.id in fired_ids
      assert reload!(live_card).task_id
    end

    test "stopping AFTER the sweeper won is refused, not silently accepted",
         %{meeting: meeting} do
      at = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, card} = heard!(meeting, at: at)
      _ = classify!(card)

      assert [fired] = Platform.Meetings.CandidateSweeper.sweep(now: DateTime.utc_now())
      assert fired.id == card.id

      # The human has to be able to be told the stop was too late; a
      # `{:ok, _}` here would let the UI claim it prevented a task that
      # actually exists.
      assert {:error, :already_fired} = Candidates.stop(card, Ecto.UUID.generate())
      assert reload!(card).task_id
    end
  end
end
