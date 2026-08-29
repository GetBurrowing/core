defmodule Platform.Meetings.RetractionGateTest do
  @moduledoc """
  The retraction gate (task 01a03fba): when a later utterance takes back
  an open candidate, that candidate closes as `:retracted`.

  ## What this file is the second half of

  `105da003` stopped `"don't make that"` threading onto the card it
  negates, and stopped exactly there — its moduledoc says interpreting
  the retraction is a different ticket. This is that ticket. The
  negating utterance already becomes its own visible card; the question
  left open was what happens to the card it was aimed at, and the answer
  built here is that it closes through `Candidates.close/2` with
  `:retracted`, the same reason a human's stop button writes.

  ## The trap this file is built around

  A gate that closes retractions by closing too much passes every
  assertion an "it caught the retraction" test can make. So every
  catching assertion below is paired with a MUST-SURVIVE case drawn
  from the suite that already exists:

    * `"make that mobile only"` — the canonical refinement, and the
      whole reason the anaphoric path exists.
    * `ThreadResolverTest`'s `@rejected_marker_fragments` — the four
      fragments carrying `stop` / `cancel` / `no`, words the resolver
      measured and deliberately refused as markers.
    * `ThreadResolverTest`'s `@accepted_polarity_costs` — `"make that
      not bold"` and `"make that never expire"`. These are the sharpest
      controls in the file: they ARE negated, they DO clear the shared-
      token floor, and they must still survive. Only the subset clause
      separates them from a retraction.

  Each of those sets is restated here by value rather than imported, so
  a change to the resolver's own table cannot silently shrink the
  controls this file runs.

  ## Reachability

  Every string is first asserted to clear
  `IntentClassifier.content_bearing?/1`. `Candidates.record_heard/1` is
  called from exactly one place in `lib/` — `classify_and_enqueue/4` —
  and that call sits BEHIND the content gate. An utterance that fails
  the gate never reaches this code in production however good the rule
  is, and a scenario built from one would be green and meaningless.
  That is also why the retractions this gate cannot see are recorded as
  costs below rather than fixed here: no gate placed after the content
  gate can see them.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.ThreadResolver

  @t0 ~U[2026-08-28 10:00:00Z]

  # The same two candidates `ThreadResolverTest` is built from — no
  # shared topic vocabulary, so a two-open-candidates scenario is a real
  # discrimination test.
  @dashboard "we should make the dashboard load faster"
  @release "the release date should slip to the fifteenth"

  # The canonical must-survive refinement.
  @follow_up "make that mobile only"

  # Negations that DO take the card back. Each is measured against
  # `@dashboard` unless the tuple says otherwise.
  @retractions [
    "don't make that",
    "dont make that",
    "do not make that",
    "actually don't make that",
    "can't make that",
    "won't make that",
    # The case `105da003` cannot see: long enough to carry its own topic,
    # so `:topic_overlap` fires before `:anaphoric_fragment` is ever
    # reached and the polarity check there never runs.
    "don't make the dashboard load faster"
  ]

  # Must survive: refinements carrying a word the resolver measured and
  # REFUSED as a negation marker. Restated from
  # `ThreadResolverTest.@rejected_marker_fragments` by value.
  @rejected_marker_fragments [
    "make that stop at five",
    "make that cancel button bigger",
    "no make that mobile only",
    "no, make that friday instead"
  ]

  # Must survive, and the hardest case in the file: negated refinements.
  # Restated from `ThreadResolverTest.@accepted_polarity_costs`.
  @accepted_polarity_costs ["make that not bold", "make that never expire"]

  # Must survive: AFFIRMATIVE refinements whose every topic token the
  # candidate already has. These are what the negation check actually
  # protects — see the test of the same name, and mutation M1.
  @affirmative_no_new_topic ["make that faster", "make that load faster"]

  # Retractions in plain English that this gate answers `:none` for,
  # split by WHY. Both halves are asserted below rather than described.
  @cost_not_a_marker ["cancel that", "let's cancel that"]
  @cost_fails_content_gate ["scratch that", "forget it", "never mind"]

  defp candidate(quote_text, id) do
    %MeetingCandidate{
      id: id,
      speaker: "alice",
      evidence_quote: quote_text,
      last_utterance_at: @t0
    }
  end

  defp dashboard_candidate, do: candidate(@dashboard, "11111111-1111-7111-8111-111111111111")
  defp release_candidate, do: candidate(@release, "22222222-2222-7222-8222-222222222222")

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)
  defp utterance(text, seconds), do: %{speaker: "alice", text: text, at: at(seconds)}

  describe "reachability — production can actually reach this gate" do
    test "every utterance the gate is asserted to CATCH clears the content gate" do
      for text <- @retractions do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} never reaches record_heard/1, so catching it here is vacuous"
      end
    end

    test "every must-survive utterance clears the content gate too" do
      for text <-
            [@dashboard, @release, @follow_up] ++
              @rejected_marker_fragments ++
              @accepted_polarity_costs ++ @affirmative_no_new_topic ++ @cost_not_a_marker do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} cannot reach the gate, so its survival here proves nothing"
      end
    end

    test "POSITIVE CONTROL — the content gate is capable of answering false" do
      # Without this, the two assertions above would also pass against a
      # `content_bearing?/1` that returned true for everything, and the
      # cost recorded below would be unfalsifiable.
      for text <- @cost_fails_content_gate do
        refute IntentClassifier.content_bearing?(text),
               "#{inspect(text)} now clears the content gate — it is no longer an unreachable " <>
                 "cost and the gate should be measured against it"
      end
    end
  end

  describe "the window this gate runs in — the ticket's premise, re-measured" do
    test "an unclassified skeleton is OPEN, and an acting candidate is not", %{} do
      meeting_id = Ecto.UUID.generate()
      chunk_id = Ecto.UUID.generate()

      # This is the window task 01a04a7f (#851) created: a row that
      # exists, is attachable, and carries NO classification — written
      # before the model is consulted. The ticket was blocked on there
      # being no such state.
      {:ok, skeleton} =
        Candidates.record_heard(%{
          meeting_id: meeting_id,
          transcript_chunk_id: chunk_id,
          evidence_quote: @dashboard,
          speaker: "alice",
          heard_at: @t0
        })

      assert skeleton.state == :heard
      assert is_nil(skeleton.classified_intent)
      assert skeleton.id in Enum.map(Candidates.open_for_meeting(meeting_id), & &1.id)

      # And the far edge of the window: `:acting` means a runtime has
      # already read the brief, which is the expensive thing the gate is
      # supposed to run before.
      {:ok, acting} = Candidates.advance(skeleton, :acting)
      assert acting.state == :acting
      refute acting.id in Enum.map(Candidates.open_for_meeting(meeting_id), & &1.id)
    end
  end

  describe "retraction_target/2 — what it catches" do
    test "PROVES IT WORKS — the case resolve/2 still gets wrong today" do
      # `105da003`'s polarity refusal sits on the ANAPHORIC path only.
      # This string is 6 tokens and repeats the candidate's whole topic,
      # so `:topic_overlap` answers first and the polarity check is never
      # consulted. Asserted, not assumed — if the resolver is ever fixed
      # to refuse this too, this assertion goes red and the ordering
      # comment in `Candidates.thread_or_open/3` needs rewriting.
      negation = "don't make the dashboard load faster"

      assert ThreadResolver.negated?(negation)
      assert ThreadResolver.relatedness(negation, @dashboard) == 1.0

      assert {:thread, _candidate, %{rule: :topic_overlap}} =
               ThreadResolver.resolve(utterance(negation, 8), [dashboard_candidate()]),
             "resolve/2 no longer threads this, so the gate's before-the-resolver ordering " <>
               "is no longer load-bearing"

      # The gate sees it anyway, because it runs first.
      assert {:retraction, target, reason} =
               ThreadResolver.retraction_target(utterance(negation, 8), [dashboard_candidate()])

      assert target.id == dashboard_candidate().id
      assert reason.rule == :retraction
      assert reason.markers == ["don't"]
      assert reason.utterance_topic == ["dashboard", "faster", "load"]
      assert reason.antecedent_topic == ["dashboard", "faster", "load"]
      assert reason.elapsed_seconds == 8
      assert reason.open_candidates_in_window == 1
    end

    test "every retraction in the table names the dashboard candidate" do
      for text <- @retractions do
        assert {:retraction, target, reason} =
                 ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]),
               "#{inspect(text)} was not read as a retraction"

        assert target.id == dashboard_candidate().id
        assert reason.rule == :retraction

        # Load-bearing anti-vacuity: each one had EVIDENCE it was aimed
        # at this card. A retraction that shared nothing would be the
        # gate firing on polarity alone.
        assert reason.shared != [],
               "#{inspect(text)} shares no lexical token with the candidate, so its retraction " <>
                 "is not evidence of aim"

        # And each brings nothing the card does not already say — the
        # clause that separates it from a refinement.
        assert reason.utterance_topic -- reason.antecedent_topic == []
      end
    end

    test "a retraction against the OTHER candidate names that one, not the dashboard" do
      # The gate is not a constant function. Same shape of utterance,
      # different antecedent, different answer.
      text = "don't slip that release date"
      assert IntentClassifier.content_bearing?(text)

      assert {:retraction, target, _reason} =
               ThreadResolver.retraction_target(utterance(text, 8), [release_candidate()])

      assert target.id == release_candidate().id

      # And that same utterance retracts NOTHING against the dashboard
      # card: it shares no vocabulary with it and every topic token it
      # carries is new there.
      assert ThreadResolver.shared_lexical(text, @dashboard) == []

      assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
               :none
    end
  end

  describe "retraction_target/2 — what must survive it" do
    test "the canonical refinement survives" do
      # `"make that mobile only"` is the whole reason the anaphoric path
      # exists. If the gate closes this card the feature is worse than
      # not having shipped.
      assert ThreadResolver.retraction_target(utterance(@follow_up, 8), [dashboard_candidate()]) ==
               :none

      # And it still threads, unchanged.
      assert {:thread, _candidate, _reason} =
               ThreadResolver.resolve(utterance(@follow_up, 8), [dashboard_candidate()])
    end

    test "AFFIRMATIVE refinements that bring no new topic survive — the polarity check, on its own" do
      # Found by mutation M1, which the first cut of this file did not
      # kill. `"make that mobile only"` is NOT what the negation check
      # protects — the subset clause refuses it anyway, because `mobile`
      # is a topic token the candidate does not have. These are: each
      # one clears the shared-token floor AND brings no new topic, so
      # conditions 2 and 3 both pass and ONLY polarity refuses them.
      # Without the negation check every one of these closes the card it
      # is refining.
      for text <- @affirmative_no_new_topic do
        assert IntentClassifier.content_bearing?(text)

        refute ThreadResolver.negated?(text),
               "#{inspect(text)} is negated, so it does not isolate the polarity check"

        assert length(ThreadResolver.shared_lexical(text, @dashboard)) >=
                 ThreadResolver.anaphoric_shared_floor(),
               "#{inspect(text)} fails the floor, so the floor refuses it and polarity is not " <>
                 "the clause under test"

        assert ThreadResolver.topic_tokens(text)
               |> MapSet.difference(ThreadResolver.topic_tokens(@dashboard))
               |> MapSet.size() == 0,
               "#{inspect(text)} brings new topic, so the subset clause refuses it and polarity " <>
                 "is not the clause under test"

        assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
                 :none,
               "#{inspect(text)} — an affirmative refinement — was closed as a retraction"

        # And it is a refinement, so it must still THREAD.
        assert {:thread, _candidate, _reason} =
                 ThreadResolver.resolve(utterance(text, 8), [dashboard_candidate()]),
               "#{inspect(text)} no longer threads, so it is no longer a refinement and this " <>
                 "control has stopped testing anything"
      end
    end

    test "NEGATED refinements survive — the subset clause, on its own" do
      # The sharpest control in the file. Each of these IS negated and
      # each DOES clear the shared-token floor, so conditions 1 and 3a
      # both pass. Only "brings no new topic" refuses them.
      for text <- @accepted_polarity_costs do
        assert ThreadResolver.negated?(text),
               "#{inspect(text)} is not negated, so it does not test the subset clause"

        assert length(ThreadResolver.shared_lexical(text, @dashboard)) >=
                 ThreadResolver.anaphoric_shared_floor(),
               "#{inspect(text)} fails the floor, so its survival is the floor's doing and " <>
                 "not the subset clause's"

        assert ThreadResolver.topic_tokens(text)
               |> MapSet.difference(ThreadResolver.topic_tokens(@dashboard))
               |> MapSet.size() > 0,
               "#{inspect(text)} brings no new topic, so it is indistinguishable from a retraction"

        assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
                 :none,
               "#{inspect(text)} — a refinement that negates an ATTRIBUTE — was closed as a " <>
                 "retraction"
      end
    end

    test "fragments carrying a REJECTED marker survive" do
      for text <- @rejected_marker_fragments do
        refute ThreadResolver.negated?(text),
               "#{inspect(text)} now carries a negation marker, so it no longer tests the " <>
                 "closed marker class"

        assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
                 :none
      end
    end

    test "TWO open candidates in the window — the gate switches itself off" do
      # A bare negation with two cards on the table names neither.
      # Closing the wrong one is strictly worse than closing none, which
      # is the same call the anaphoric path already makes.
      both = [dashboard_candidate(), release_candidate()]

      assert {:retraction, _target, _reason} =
               ThreadResolver.retraction_target(utterance("don't make that", 8), [
                 dashboard_candidate()
               ]),
             "the one-candidate case must fire, or the two-candidate case proves nothing"

      assert ThreadResolver.retraction_target(utterance("don't make that", 8), both) == :none
    end

    test "a different speaker, and a stale utterance, both survive" do
      other_speaker = %{speaker: "bruno", text: "don't make that", at: at(8)}
      assert ThreadResolver.retraction_target(other_speaker, [dashboard_candidate()]) == :none

      stale = utterance("don't make that", ThreadResolver.window_seconds() + 1)
      assert ThreadResolver.retraction_target(stale, [dashboard_candidate()]) == :none

      # Positive control on both: the same utterance inside the window,
      # from the same speaker, DOES fire.
      assert {:retraction, _target, _reason} =
               ThreadResolver.retraction_target(
                 utterance("don't make that", ThreadResolver.window_seconds()),
                 [dashboard_candidate()]
               )
    end

    test "no shared lexical token — the floor, on its own" do
      # `"we can't do it"` is negated and brings no new topic, so
      # conditions 1 and 3b both pass. Only the shared-token floor
      # refuses it. Without that floor this closes whatever card happens
      # to be open.
      text = "we can't do it"
      assert IntentClassifier.content_bearing?(text)
      assert ThreadResolver.negated?(text)
      assert ThreadResolver.shared_lexical(text, @dashboard) == []
      assert MapSet.size(ThreadResolver.topic_tokens(text)) == 0

      assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
               :none
    end
  end

  describe "ACCEPTED COSTS — retractions this gate does not catch" do
    test "COST 1: `cancel that` is a retraction and answers :none" do
      # `cancel` is not a negation marker, and `ThreadResolverTest`
      # records the measurement that kept it out: `"make that cancel
      # button bigger"` is a refinement. Widening the marker class to
      # catch this retraction would break that refinement. The trade is
      # recorded here rather than rediscovered.
      for text <- @cost_not_a_marker do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} is unreachable, so this is COST 2 and not COST 1"

        refute ThreadResolver.negated?(text)

        assert ThreadResolver.retraction_target(utterance(text, 8), [dashboard_candidate()]) ==
                 :none
      end
    end

    test "COST 2: `scratch that` / `forget it` / `never mind` never arrive at all" do
      # A different cost with a different cause. These carry no token in
      # `IntentClassifier`'s action set, so the content gate drops the
      # chunk and `record_heard/1` is never called for them. NO gate
      # placed after the content gate can see these, whatever its
      # vocabulary — which is why widening the marker class would not
      # help and the fix, if one is wanted, is upstream.
      for text <- @cost_fails_content_gate do
        refute IntentClassifier.content_bearing?(text)
      end

      # Stated positively so the cost is not confused with COST 1: were
      # they to reach the gate, `never mind` would still answer :none
      # because `mind` is a topic token the dashboard card does not have.
      assert ThreadResolver.negated?("never mind")

      assert ThreadResolver.retraction_target(utterance("never mind", 8), [dashboard_candidate()]) ==
               :none
    end
  end

  defp heard!(meeting_id, text, seconds) do
    Candidates.record_heard(%{
      meeting_id: meeting_id,
      transcript_chunk_id: Ecto.UUID.generate(),
      evidence_quote: text,
      speaker: "alice",
      heard_at: at(seconds)
    })
  end

  describe "end to end through Candidates.record_heard/1" do
    setup do
      %{meeting_id: Ecto.UUID.generate()}
    end

    test "a retraction closes the card AND gets a card of its own", %{meeting_id: meeting_id} do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      assert card.state == :heard

      {:ok, retraction_card} = heard!(meeting_id, "don't make that", 8)

      # Two rows, not one. The retracting utterance is still visible —
      # `105da003` shipped that and this must not undo it.
      assert retraction_card.id != card.id
      assert length(Candidates.list_for_meeting(meeting_id)) == 2

      closed = Candidates.get(card.id)
      assert closed.state == :closed
      assert closed.closed_reason == :retracted
      assert closed.closed_at

      # The note has to be diagnosable after the fact, not just present.
      assert closed.closed_note =~ "don't make that"
      assert closed.closed_note =~ "8s later"
      assert closed.closed_note =~ ~s(["make"])

      # And the closed card is no longer an attachment target.
      refute closed.id in Enum.map(Candidates.open_for_meeting(meeting_id), & &1.id)

      # The utterance did NOT thread onto the card it retracted.
      assert closed.transcript_chunk_ids == [card.transcript_chunk_id]
      assert closed.threading_events == []
    end

    test "the LONG negation closes the card too — the ordering, end to end", %{
      meeting_id: meeting_id
    } do
      # `"don't make the dashboard load faster"` is the string
      # `resolve/2` still threads (asserted above). If the gate ran after
      # the resolver instead of before it, this utterance would be
      # absorbed into the card it negates: one row, an attachment, and no
      # close. All three are asserted.
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, own} = heard!(meeting_id, "don't make the dashboard load faster", 8)

      assert own.id != card.id
      assert length(Candidates.list_for_meeting(meeting_id)) == 2

      closed = Candidates.get(card.id)
      assert closed.state == :closed
      assert closed.closed_reason == :retracted
      assert closed.threading_events == []
      assert closed.transcript_chunk_ids == [card.transcript_chunk_id]
    end

    test "POSITIVE CONTROL — the refinement still threads and the card stays open", %{
      meeting_id: meeting_id
    } do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)

      assert {:attached, host} = heard!(meeting_id, @follow_up, 8)
      assert host.id == card.id

      still_open = Candidates.get(card.id)
      assert still_open.state == :heard
      assert is_nil(still_open.closed_reason)
      assert length(still_open.transcript_chunk_ids) == 2
      assert [%{"reason" => %{"rule" => "anaphoric_fragment"}}] = still_open.threading_events

      # One row, because the refinement attached rather than opening a
      # second card.
      assert length(Candidates.list_for_meeting(meeting_id)) == 1
    end

    test "a retraction cannot reopen or relabel an already-closed card", %{
      meeting_id: meeting_id
    } do
      {:ok, card} = heard!(meeting_id, @dashboard, 0)
      {:ok, vetoed} = Candidates.close(card, {:vetoed, "operator"})
      assert vetoed.closed_reason == :vetoed

      {:ok, _own_card} = heard!(meeting_id, "don't make that", 8)

      # Untouched: a closed row is not in `open_for_meeting/1`, so the
      # gate never sees it, and `close/2` is idempotent besides.
      assert Candidates.get(card.id).closed_reason == :vetoed
    end

    test "the retraction does not close a card belonging to a DIFFERENT speaker", %{
      meeting_id: meeting_id
    } do
      {:ok, card} =
        Candidates.record_heard(%{
          meeting_id: meeting_id,
          transcript_chunk_id: Ecto.UUID.generate(),
          evidence_quote: @dashboard,
          speaker: "bruno",
          heard_at: @t0
        })

      {:ok, _own} = heard!(meeting_id, "don't make that", 8)

      assert Candidates.get(card.id).state == :heard
      assert is_nil(Candidates.get(card.id).closed_reason)
    end
  end
end
