defmodule Platform.Meetings.CandidateEventsTest do
  @moduledoc """
  The candidate activity log (task 01a03fba) — the card's thinking log
  must be emitted by the writes that happened, not written into a
  template.

  ## What this file has to prove, and the trap it is built around

  The ticket's complaint is that a hardcoded log "would show the same
  three lines whether the checks ran, failed, or never fired". A test
  that only asserts the RENDERER has exactly that defect one layer up:
  it passes against a producer nobody calls. So nothing here asserts on
  a component. Every case either receives a broadcast or reloads a row.

  The second trap is the one that shipped in #856 and had to be fixed in
  #859: a `refute_receive` against a topic nothing publishes to passes
  under every implementation, including a deleted one. The refutations
  here are the ticket's central assertion — *"a candidate that closes
  early shows the gates that ran and no others"* — so each one is paired,
  IN THE SAME TEST, with a positive control that produces the very kind
  being refuted, through the same query or the same topic. See
  `"a gate that did not run leaves no line"` and
  `"the topic is live for every kind this test refutes"`.

  ## Reachability

  `Candidates.record_heard/1` has exactly one `lib/` caller —
  `IntentClassifier`'s `classify_and_enqueue/4` — and it sits behind the
  content gate, so every utterance here is first asserted to clear
  `IntentClassifier.content_bearing?/1`. `Candidates.close/2` is reached
  in production from `close_skeleton/4` and from the queue mirror;
  `advance/3` and `record_disposition/3` from the queue mirror. The
  scenarios below drive the context functions those call sites call.

  ## The gap this closes, stated so it can be re-measured

  Measured on 2026-08-29 at `origin/main` @ `3254318c`: `pub_sub.ex`
  contained 0 occurrences of `candidate` and 131 lines matching `intent`
  (positive control, same file, same query shape). `candidates.ex`
  contained no `Phoenix.PubSub` call and no telemetry, and
  `intent_classifier.ex` only ever subscribes. The nine `intent_*`
  events narrate an `IntentQueue` ROW; they cannot narrate a candidate,
  and `"a candidate whose whole life happens before any intent row
  exists"` below is the case that shows why.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.MeetingCandidateEvent
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @t0 ~U[2026-08-29 10:00:00Z]

  # The two strings `RetractionGateTest` and `ThreadResolverTest` are
  # built from, restated by value for the same reason they restate them:
  # a change to the resolver's own table must not silently change what
  # this file exercises.
  @dashboard "we should make the dashboard load faster"

  # The canonical refinement — threads onto `@dashboard` anaphorically.
  @follow_up "make that mobile only"

  # Takes the card back. Added by `58a19028`, and the newest lifecycle
  # path there is: it closes a candidate with NO intent row in existence.
  @retraction "don't make that"

  setup do
    %{meeting_id: Ecto.UUID.generate()}
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # Every lifecycle call below passes an ID, never an in-memory struct,
  # and that is load-bearing rather than stylistic.
  #
  # `Candidates.fetch/1` (`candidates.ex:1047`) returns a
  # `%MeetingCandidate{}` argument VERBATIM — it re-reads only when
  # handed a binary id. So a caller holding a stale struct bypasses
  # both `advance/3`'s `check_forward/2` and `close/2`'s
  # already-closed guard, and `close/2`'s documented idempotence
  # ("a late duplicate cancel cannot relabel the close that actually
  # happened") holds only for the id form. Measured here on
  # 2026-08-29; not reachable from either production caller today —
  # `IntentQueue.Server`'s `with_candidate/2` re-reads through
  # `get_by_intent_id/1`, and `IntentClassifier`'s `close_skeleton/4`
  # closes each skeleton once — so it is reported, not patched.
  #
  # Passing ids is therefore what makes the guard assertions below
  # about the guard, rather than about which struct the test held.

  defp heard!(meeting_id, text, seconds) do
    Candidates.record_heard(%{
      meeting_id: meeting_id,
      transcript_chunk_id: Ecto.UUID.generate(),
      evidence_quote: text,
      speaker: "alice",
      heard_at: at(seconds)
    })
  end

  # Drain everything currently in the mailbox for this topic, in arrival
  # order. Used where the assertion is about the SEQUENCE rather than
  # about one line.
  defp drain(acc \\ []) do
    receive do
      {:candidate_event, %MeetingCandidateEvent{} = event} -> drain([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # ── the producer exists ───────────────────────────────────────────────────

  describe "the producer exists on the real arrival path" do
    test "record_heard/1 broadcasts :heard on the meeting's candidate topic", %{
      meeting_id: meeting_id
    } do
      assert IntentClassifier.content_bearing?(@dashboard),
             "the scenario is unreachable in production if the content gate refuses it"

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      assert_receive {:candidate_event, %MeetingCandidateEvent{} = event}

      # Bound to THIS card, not merely to "an event fired".
      assert event.kind == :heard
      assert event.candidate_id == card.id
      assert event.meeting_id == meeting_id

      # M1 — delete the `emit(:heard, ...)` in `Candidates.create/1`:
      # this goes red (no message received).
    end

    test "the event carries what the write produced, not what the caller asked for", %{
      meeting_id: meeting_id
    } do
      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      assert_receive {:candidate_event, %MeetingCandidateEvent{kind: :heard} = event}

      # `state` and `outcome_kind` are DEFAULTED by the changeset — the
      # caller passed neither. An event echoing its input could not
      # report them, so this is the binding that separates "read off the
      # inserted row" from "restated the attrs".
      assert event.detail["state"] == "heard"
      assert event.detail["outcome_kind"] == "task"
      assert event.detail["speaker"] == "alice"
      assert card.state == :heard
    end
  end

  # ── the threading gate ────────────────────────────────────────────────────

  describe "the threading gate emits the resolver's own reason" do
    test "an attached utterance produces :threaded carrying values only the resolver computed",
         %{meeting_id: meeting_id} do
      assert IntentClassifier.content_bearing?(@follow_up)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      # No row of its own: it threaded.
      assert {:attached, host} = heard!(meeting_id, @follow_up, 8)
      assert host.id == card.id

      assert_receive {:candidate_event, %MeetingCandidateEvent{kind: :threaded} = event}
      assert event.candidate_id == card.id

      reason = event.detail["reason"]

      # Each of these is a value the RESOLVER computed and that nothing
      # else in the event, the candidate row or the caller's attrs
      # carries. `elapsed_seconds` in particular is the gap between two
      # timestamps neither of which appears on this event.
      assert reason["rule"] == "anaphoric_fragment"
      assert reason["deictic"] == "that"
      assert reason["elapsed_seconds"] == 8
      assert reason["open_candidates_in_window"] == 1

      # M2 — replace the `reason` in the `:threaded` detail with a
      # constant (`%{"rule" => "anaphoric_fragment"}`): the
      # `deictic` / `elapsed_seconds` / `open_candidates_in_window`
      # assertions go red while `rule` stays green, which is exactly the
      # difference between recording that a gate ran and recording what
      # it saw.
    end

    test "an utterance that threads produces NO :heard line of its own", %{
      meeting_id: meeting_id
    } do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      assert {:attached, _} = heard!(meeting_id, @follow_up, 8)

      # One card, two utterances, and exactly one `:heard`. A producer
      # that emitted per-utterance rather than per-write would show two.
      assert CandidateEvents.kinds_for_candidate(card.id) == [:heard, :threaded]
      assert length(CandidateEvents.list_for_meeting(meeting_id)) == 2
    end
  end

  # ── the retraction gate (58a19028) ────────────────────────────────────────

  describe "the newest lifecycle path is narrated" do
    test "a retraction closes the card with :retracted and says so on the rail", %{
      meeting_id: meeting_id
    } do
      assert IntentClassifier.content_bearing?(@retraction)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      # The retracting utterance also opens a card of its own, so two
      # events land: the close of the retracted card, and the `:heard`
      # of the new one.
      {:ok, own_card} = heard!(meeting_id, @retraction, 8)
      refute own_card.id == card.id

      assert_receive {:candidate_event, %MeetingCandidateEvent{kind: :closed} = closed}
      assert closed.candidate_id == card.id
      assert closed.detail["reason"] == "retracted"
      assert closed.detail["from"] == "heard"

      # The note the gate wrote, carried through verbatim. It names the
      # particle that fired and what it shared — the whole reason
      # `Candidates.retraction_note/3` exists — so a reader can
      # second-guess the close from the rail alone.
      assert closed.detail["note"] =~ "retracted by a later utterance"

      assert Repo.reload!(card).closed_reason == :retracted

      # M3 — make `Candidates.retract/4` call `Repo.update` directly
      # instead of going through `close/2`: this goes red, which is what
      # keeps the single-close-path rule enforced by the log rather than
      # by a comment.
    end

    test "a candidate whose whole life happens before any intent row exists is still narrated",
         %{meeting_id: meeting_id} do
      # This is the case the nine `intent_*` events structurally cannot
      # cover. `record_heard/1` runs BEFORE the model is consulted, and
      # `close_skeleton/4` closes on `:parse_error` / `:model_error` /
      # `:empty_output` / a dedupe hit — every one of them with no queue
      # row ever created, so no intent id and nothing for
      # `intents_topic/1` to broadcast.
      {:ok, skeleton} = heard!(meeting_id, @dashboard, 0)
      assert is_nil(skeleton.intent_id)
      assert is_nil(skeleton.classified_intent)

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      # Exactly what `IntentClassifier.close_skeleton/4` does.
      {:ok, _} = Candidates.record_disposition(skeleton.id, :timed_out)
      {:ok, _} = Candidates.close(skeleton.id, {:dismissed, "classifier parse_error"})

      events = drain()
      assert Enum.map(events, & &1.kind) == [:disposition_recorded, :closed]
      assert Enum.all?(events, &(&1.candidate_id == skeleton.id))

      # Still no intent row. The rail said something anyway.
      assert is_nil(Repo.reload!(skeleton).intent_id)
    end
  end

  # ── survives a reload, in order ───────────────────────────────────────────

  describe "the log survives a reload" do
    test "the ordered sequence reloads from Postgres identically", %{meeting_id: meeting_id} do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      {:ok, _} = Candidates.advance(card.id, :shaping)
      {:ok, _} = Candidates.advance(card.id, :acting)
      {:ok, _} = Candidates.record_disposition(card.id, :accepted)
      {:ok, _} = Candidates.close(card.id, :done)

      assert CandidateEvents.kinds_for_candidate(card.id) ==
               [:heard, :advanced, :advanced, :disposition_recorded, :closed]

      # M4 — delete the `emit(:advanced, ...)` in `Candidates.advance/3`:
      # this goes red.
    end

    test "order comes from seq, and seq is strictly increasing", %{meeting_id: meeting_id} do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.record_disposition(card.id, :accepted)
      {:ok, _} = Candidates.close(card.id, :done)

      seqs = card.id |> CandidateEvents.list_for_candidate() |> Enum.map(& &1.seq)

      assert length(seqs) == 3
      assert Enum.all?(seqs, &is_integer/1), "seq must be read back from Postgres, not left nil"
      assert seqs == Enum.sort(seqs)
      assert Enum.uniq(seqs) == seqs

      # The pair the ticket's ordering problem is actually about:
      # `record_disposition/3` then `close/2` routinely land inside one
      # microsecond on the classifier's path. Asserting they have
      # DISTINCT seqs is what makes the order a fact rather than a tie
      # broken differently on each read.
      [_heard, disposition, closed] = CandidateEvents.list_for_candidate(card.id)
      assert disposition.kind == :disposition_recorded
      assert closed.kind == :closed
      assert closed.seq > disposition.seq
    end

    test "detail round-trips as strings, so a reloaded line matches a broadcast one", %{
      meeting_id: meeting_id
    } do
      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.advance(card.id, :shaping)

      broadcast = drain()

      reloaded = CandidateEvents.list_for_candidate(card.id)

      # The exact divergence jsonb would introduce if `detail` were built
      # with atom keys or atom values: the live listener would match and
      # the reloading one would not.
      assert Enum.map(broadcast, & &1.detail) == Enum.map(reloaded, & &1.detail)
      assert Enum.map(broadcast, & &1.seq) == Enum.map(reloaded, & &1.seq)
    end
  end

  # ── the central assertion, and its positive control ───────────────────────

  describe "a gate that did not run leaves no line" do
    test "a candidate that closes early shows the gates that ran and no others", %{
      meeting_id: meeting_id
    } do
      # The early-closing card: heard, then closed. Never advanced,
      # never classified, never threaded.
      {:ok, early} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.close(early.id, {:dismissed, "classifier model_error"})

      early_kinds = CandidateEvents.kinds_for_candidate(early.id)

      assert early_kinds == [:heard, :closed]
      refute :advanced in early_kinds
      refute :threaded in early_kinds
      refute :disposition_recorded in early_kinds

      # ── POSITIVE CONTROL, in the same test, through the same query ──
      #
      # Without this the four assertions above are the #856 defect: they
      # would pass against a `kinds_for_candidate/1` that always returns
      # `[]`, against a producer nobody calls, and against a deleted
      # table. A SECOND card in the SAME meeting runs the very gates the
      # first one skipped, and `kinds_for_candidate/1` must return them.
      {:ok, busy} = heard!(meeting_id, release_topic(), 0)
      {:ok, _} = Candidates.advance(busy.id, :shaping)
      {:ok, _} = Candidates.record_disposition(busy.id, :accepted)

      busy_kinds = CandidateEvents.kinds_for_candidate(busy.id)

      assert :advanced in busy_kinds,
             "the refutations above are vacuous unless this query can return :advanced"

      assert :disposition_recorded in busy_kinds,
             "the refutations above are vacuous unless this query can return " <>
               ":disposition_recorded"

      # And the two cards do not bleed into each other.
      assert CandidateEvents.kinds_for_candidate(early.id) == [:heard, :closed]
    end

    test "the topic is live for every kind this test refutes", %{meeting_id: meeting_id} do
      # The broadcast-side twin of the control above, and the reason no
      # `refute_receive` in this file is vacuous: this proves the topic
      # carries `:advanced`, `:threaded` and `:closed`, so a later
      # silence on it is evidence of something.
      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:attached, _} = heard!(meeting_id, @follow_up, 8)
      {:ok, _} = Candidates.advance(card.id, :shaping)
      {:ok, _} = Candidates.close(card.id, :done)

      kinds = drain() |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

      assert kinds == [:advanced, :closed, :heard, :threaded]
    end

    test "an idempotent close is silent, because it wrote nothing", %{meeting_id: meeting_id} do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.close(card.id, :vetoed)

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      # A late duplicate cancel. `close/2` returns the row unchanged.
      {:ok, unchanged} = Candidates.close(card.id, :retracted)
      assert unchanged.closed_reason == :vetoed

      # This refutation is NOT vacuous: the test immediately above proves
      # this exact topic carries `:closed`, and the assertion below
      # proves the first close DID write one.
      refute_receive {:candidate_event, %MeetingCandidateEvent{kind: :closed}}, 100

      assert CandidateEvents.kinds_for_candidate(card.id) == [:heard, :closed]

      [_heard, closed] = CandidateEvents.list_for_candidate(card.id)
      assert closed.detail["reason"] == "vetoed"

      # M5 — hoist the `emit(:closed, ...)` out of the `else` branch in
      # `Candidates.close/2` so it runs on the idempotent path too: the
      # `refute_receive` and the `== [:heard, :closed]` both go red.
    end
  end

  # ── two participants see the same thing ───────────────────────────────────

  describe "two participants see the same sequence" do
    test "a second subscriber receives an identical seq-ordered stream", %{
      meeting_id: meeting_id
    } do
      parent = self()

      # A genuinely separate process, so this is a broadcast test and not
      # a self-send test. It needs the sandbox connection only to be
      # allowed to exist; it performs no queries.
      second =
        spawn_link(fn ->
          :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)
          send(parent, :subscribed)

          receive do
            :collect -> send(parent, {:second, drain()})
          end
        end)

      assert_receive :subscribed

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.advance(card.id, :shaping)
      {:ok, _} = Candidates.close(card.id, :done)

      mine = drain()
      send(second, :collect)
      assert_receive {:second, theirs}

      fingerprint = fn events -> Enum.map(events, &{&1.kind, &1.seq, &1.candidate_id}) end

      assert fingerprint.(mine) == fingerprint.(theirs)
      assert fingerprint.(mine) == fingerprint.(CandidateEvents.list_for_candidate(card.id))

      # M6 — broadcast before inserting (so `seq` is nil on the wire):
      # the two fingerprints still match each other but neither matches
      # the reloaded one, which is the divergence between the live rail
      # and the reloaded rail this pairing exists to catch.
    end
  end

  # ── the `from` a transition cannot re-derive ──────────────────────────────

  describe ":advanced records where the candidate came from" do
    test "the second advance reports :shaping, not the original :heard", %{
      meeting_id: meeting_id
    } do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      {:ok, _} = Candidates.advance(card.id, :shaping)
      {:ok, _} = Candidates.advance(card.id, :acting)

      [_heard, first, second] = CandidateEvents.list_for_candidate(card.id)

      assert first.kind == :advanced
      assert first.detail == %{"from" => "heard", "to" => "shaping"}

      assert second.kind == :advanced
      assert second.detail == %{"from" => "shaping", "to" => "acting"}

      # M7 — write `"from" => "heard"` as a literal: the FIRST assertion
      # stays green and the second goes red, which is why both are here.
      # Nothing on the reloaded row remembers the previous state, so
      # `from` cannot be recovered from the candidate afterwards — it has
      # to be closed over at the gate.
    end

    test "a refused backwards transition writes nothing and says nothing", %{
      meeting_id: meeting_id
    } do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, _} = Candidates.advance(card.id, :acting)

      before = CandidateEvents.kinds_for_candidate(card.id)
      assert before == [:heard, :advanced]

      # `advance/3` refuses a transition at or before the current state.
      assert {:error, {:invalid_transition, :acting, :shaping}} =
               Candidates.advance(card.id, :shaping)

      # The refusal is the gate NOT running, and it leaves no line. Not
      # vacuous: `before` above proves this query returns `:advanced`
      # when an advance does happen.
      assert CandidateEvents.kinds_for_candidate(card.id) == before
    end
  end

  # ── scoping ───────────────────────────────────────────────────────────────

  describe "scoping" do
    test "list_for_meeting/1 returns only this meeting's events", %{meeting_id: meeting_id} do
      other_meeting = Ecto.UUID.generate()

      {:ok, mine} = heard!(meeting_id, @dashboard, 0)
      {:ok, theirs} = heard!(other_meeting, @dashboard, 0)

      assert Enum.map(CandidateEvents.list_for_meeting(meeting_id), & &1.candidate_id) == [
               mine.id
             ]

      assert Enum.map(CandidateEvents.list_for_meeting(other_meeting), & &1.candidate_id) ==
               [theirs.id]
    end

    test "a subscriber to one meeting hears nothing from another", %{meeting_id: meeting_id} do
      other_meeting = Ecto.UUID.generate()

      :ok = MeetingsPubSub.subscribe_candidate_events(meeting_id)

      # Positive control FIRST, on this very subscription, so the
      # refutation below is a claim about scoping rather than about a
      # topic nobody publishes to.
      {:ok, _} = heard!(meeting_id, @dashboard, 0)
      assert_receive {:candidate_event, %MeetingCandidateEvent{kind: :heard}}

      {:ok, _} = heard!(other_meeting, @dashboard, 0)
      refute_receive {:candidate_event, _}, 100
    end

    test "list_for_candidate/1 tolerates a non-uuid without querying" do
      assert CandidateEvents.list_for_candidate("not-a-uuid") == []
      assert CandidateEvents.list_for_candidate(nil) == []
      assert CandidateEvents.list_for_meeting(nil) == []
    end
  end

  # A second content-bearing utterance with no topic vocabulary in
  # common with `@dashboard`, so the two cards in
  # `"a candidate that closes early..."` are genuinely separate and the
  # second cannot thread onto the first.
  defp release_topic, do: "the release date should slip to the fifteenth"
end
