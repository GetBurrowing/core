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
        org_id: Platform.Tenancy.get_org_by_slug!("fabrikam").id
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
