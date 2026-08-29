defmodule Platform.Meetings.IntentFramesTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentFrames` — the use/mention frame gate
  (task `01a04b6b`).

  ## What each block is for

  The gate was derived by reading 8 measured false positives, so its
  lexicon is FITTED to those rows and a test that only replays them
  proves nothing. Three separate defences are laid out below:

    * **the five it catches** — the measured rows, each pinned to the
      class that catches it, so a lexicon edit that catches a row by
      accident under the wrong class fails rather than passes;
    * **the three it does not** — the deliberate misses. If a future
      widening starts catching them, that is a design change and it
      should have to argue for itself here first;
    * **anti-vacuity** — genuine asks, including ones deliberately
      built to look like the frames, that must survive. These are the
      real test: a gate that suppressed everything would pass the first
      block perfectly.

  ## Named mutations

  Each is a real edit to `intent_frames.ex` (or, for M1, to
  `intent_classifier.ex`) that MUST turn something below red. All six
  were applied and reverted while writing this file; the test each one
  kills is named at its site.

    * **M1** — delete the `IntentFrames.cancelling_frame/2` call from
      `IntentClassifier.evidence_verdict/3`. Killed 4 tests, two of them
      in `intent_eval/harness_test.exs`.
    * **M2** — drop the forward-scope guard: change `start < quote_end`
      in `first_hit/3` to a tautology. Its FIRST run killed only one
      test, and not the one whose comment claimed to be about scope —
      "Promote to prod." survives the gate because no operator matches
      it at any position, not because of scope. That comment was wrong
      and the tests below were restructured rather than the mutant
      patched away.
    * **M3** — make the label-scoped tier unconditional: delete the
      `mentions_taxonomy_label?/1` check in `label_scoped/3`.
    * **M4** — drop the `\\b` word boundaries from `@taxonomy_label`.
    * **M5** — widen `frame_delegation`'s object set to include
      `the designer`.
    * **M6** — restore `get|have` to `frame_delegation`'s verb set.
      Moves no slice number at all; it exists because the corpus has no
      row that would expose it.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentFrames

  # The 8 rows that fire on `priv/intent_eval/cassettes/off_topic_default.jsonl`,
  # each with the `evidence_quote` the model actually returned. Copied
  # verbatim from the replay; the harness test re-derives the counts from
  # the cassette itself so these two can never quietly disagree.
  describe "the five measured false positives it catches" do
    # M2 kills this one: without forward scope, "No, actually" would
    # still match, but so would every operator anywhere in any chunk.
    test "a retraction before the quote cancels it" do
      assert {:cancelled, :frame_retraction} =
               IntentFrames.cancelling_frame(
                 "No, actually, never mind. As an action item, Chris needs to start developing the podcast.",
                 "As an action item, Chris needs to start developing the podcast."
               )
    end

    test "a first-person perception report of a taxonomy label cancels it" do
      assert {:cancelled, :frame_perception} =
               IntentFrames.cancelling_frame(
                 "I do see the action items, briefly, visual address, blah, blah, blah, blah.",
                 "I do see the action items"
               )
    end

    test "first-person doubt about a taxonomy label cancels it" do
      assert {:cancelled, :frame_epistemic} =
               IntentFrames.cancelling_frame(
                 "I wonder if this is really briefworthy.",
                 "I wonder if this is really briefworthy"
               )
    end

    test "handing the work to an unnamed person cancels it" do
      assert {:cancelled, :frame_delegation} =
               IntentFrames.cancelling_frame(
                 "We can ask him to bring it in here.",
                 "bring it in here"
               )
    end

    test "a quality predicated of a taxonomy label cancels it" do
      assert {:cancelled, :frame_evaluative} =
               IntentFrames.cancelling_frame(
                 "Yeah, but the interaction design part is probably wrong.",
                 "the interaction design part is probably wrong"
               )
    end
  end

  # These three still fire after the gate. They are pinned so that the
  # gate's REACH is a stated fact rather than a number in a report: a
  # change that starts catching one of them has changed the design and
  # must say so here.
  describe "the three measured false positives it deliberately does not catch" do
    # Honest account of WHY this one survives, because the obvious
    # story is the wrong one. It is not forward scope that saves it:
    # M2 (drop the scope guard) leaves this test GREEN, because the
    # peer-agreement run that cancels the ask — "Yeah, I know, me too"
    # — is not in any of the gate's five lexicons at any position. It
    # survives for want of an operator, not for want of scope. Forward
    # scope is tested on its own two tests down; that separation was
    # found by running M2 and watching this test fail to die.
    test "a peer-agreement backchannel is not a frame class the gate knows" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Promote to prod. Yeah, I know, me too. Okay, so let's go.",
                 "Promote to prod."
               )
    end

    # THE forward-scope test, on the same row's shape. English operators
    # scope forward, so a retraction that arrives after the quote has
    # ended takes back nothing the model quoted. M2 — replace
    # `start < quote_end` with a tautology — turns this red.
    test "a retraction AFTER the quote does not scope backwards over it" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Promote to prod. No, actually, never mind.",
                 "Promote to prod."
               )

      # Same words, quote taken from the other side of the operator:
      # now it IS in scope, so the gate must cancel. Without this the
      # test above would also pass on a gate that never cancels at all.
      assert {:cancelled, :frame_retraction} =
               IntentFrames.cancelling_frame(
                 "No, actually, never mind. Promote to prod.",
                 "Promote to prod."
               )
    end

    # A hortative is NOT a frame class here — see the moduledoc. The
    # shipped prompt's own worked example makes "let's make that button
    # teal" a genuine visual_adjust, and this corpus cannot see that
    # cost because every control row is built to name a role.
    test "a hortative is not a cancelling frame" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Let's put together some kind of plan here.",
                 "put together some kind of plan here"
               )

      assert :ok =
               IntentFrames.cancelling_frame(
                 "Let's make that primary button teal instead of the blue.",
                 "make that primary button teal"
               )
    end

    # A severed fragment is a different defect with a different gate:
    # `IntentClassifier.content_bearing?/1` already drops it before any
    # model call. This gate must not grow a second, worse copy of that.
    test "a severed fragment is left to the content gate" do
      assert :ok = IntentFrames.cancelling_frame("and assign them.", "and assign them")
      refute Platform.Meetings.IntentClassifier.content_bearing?("and assign them.")
    end
  end

  # The trap this whole task exists to avoid: suppressing the false
  # positives by suppressing everything. Every row here is a genuine ask
  # and every one must survive.
  describe "anti-vacuity — genuine asks survive" do
    test "an addressed ask with no frame at all is untouched" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Designer, make that primary button teal instead of the blue.",
                 "make that primary button teal"
               )
    end

    # M3 kills this: with the label-scoped tier made unconditional, a
    # polite indirect request — one of the commonest ways a human asks
    # for anything — is suppressed. This is why the epistemic class is
    # gated on the quote naming a taxonomy label.
    test "a polite indirect request survives because it names no taxonomy label" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "I wonder if the designer could make that primary button teal.",
                 "make that primary button teal"
               )
    end

    # M3 also kills this one. An evaluative copula is everywhere in
    # genuine design feedback; only a judgement OF A LABEL is a mention.
    test "a genuine complaint that something is wrong survives" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Designer, the spacing on those cards is wrong, tighten it up.",
                 "the spacing on those cards is wrong, tighten it up"
               )
    end

    # M5 kills this: widening the delegation object set to cover a named
    # role turns control rows of the shape "ask the designer to …" into
    # demotions.
    test "delegating to a NAMED role is an ask, not a hand-off to a person" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Ask the designer to darken the sidebar background.",
                 "darken the sidebar background"
               )

      assert :ok =
               IntentFrames.cancelling_frame(
                 "Have the designer add a confirm step before the destructive delete.",
                 "add a confirm step before the destructive delete"
               )
    end

    # The verb-set narrowing, pinned. "get them"/"have them" take
    # INANIMATE objects all the time in design speech; "ask"/"tell" do
    # not. Mutation M6 — restore `get|have` to the `frame_delegation`
    # verb set — turns this red while changing no slice number, which is
    # the whole point: this corpus cannot see the cost, so the test has
    # to carry it.
    test "get/have plus a pronoun is about objects, not people, and survives" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Designer, get them aligned on the left edge.",
                 "get them aligned on the left edge"
               )

      assert :ok =
               IntentFrames.cancelling_frame(
                 "Designer, have them stack vertically under 600 pixels.",
                 "have them stack vertically under 600 pixels"
               )
    end

    test "a genuine ask that names a taxonomy label but carries no frame survives" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "Scribe, log an action item for Chris to stand up the podcast control center.",
                 "log an action item for Chris to stand up the podcast control center"
               )
    end
  end

  # M4's target. Without word boundaries "scribe" matches inside
  # "transcriber", and one of the 94 correct declines
  # ("as transcriber and we should probably also shrink it …") turns
  # into a label mention — which is how the "0 of 94" signal would stop
  # being true without anyone touching the gate.
  describe "mentions_taxonomy_label?/1" do
    test "recognises the enum labels as a person says them" do
      assert IntentFrames.mentions_taxonomy_label?("as an action item, Chris needs to")
      assert IntentFrames.mentions_taxonomy_label?("is this really briefworthy")
      assert IntentFrames.mentions_taxonomy_label?("the brief-worthy stuff")
      assert IntentFrames.mentions_taxonomy_label?("the interaction design part")
      assert IntentFrames.mentions_taxonomy_label?("that is an open question")
    end

    test "does not match a label spelled inside a longer word" do
      refute IntentFrames.mentions_taxonomy_label?(
               "as transcriber and we should probably also shrink it and all kinds of other shit too"
             )
    end

    test "an ordinary ask names no label" do
      refute IntentFrames.mentions_taxonomy_label?("make that primary button teal")
      refute IntentFrames.mentions_taxonomy_label?("we're shipping Tuesday")
    end

    test "a non-binary input is not a label mention" do
      refute IntentFrames.mentions_taxonomy_label?(nil)
      refute IntentFrames.mentions_taxonomy_label?(42)
    end
  end

  describe "the verdicts this gate refuses to restate" do
    # `:blank` and `:not_in_chunk` belong to the evidence gate. If this
    # function answered them too, one defect would carry two names and
    # the telemetry stream would stop being able to tell them apart —
    # which is the failure mode the classifier's moduledoc is built
    # around.
    test "a blank quote is not this gate's business" do
      assert :ok = IntentFrames.cancelling_frame("never mind, forget it", "")
      assert :ok = IntentFrames.cancelling_frame("never mind, forget it", "   ")
    end

    test "a quote that is not a verbatim span is not this gate's business" do
      assert :ok =
               IntentFrames.cancelling_frame(
                 "No, actually, never mind. Chris needs to start the podcast.",
                 "ship the redesign by friday"
               )
    end

    test "non-binary arguments are :ok, never a crash" do
      assert :ok = IntentFrames.cancelling_frame(nil, "anything")
      assert :ok = IntentFrames.cancelling_frame("never mind, do the thing", nil)
      assert :ok = IntentFrames.cancelling_frame(42, 42)
    end
  end

  describe "matching details that are easy to get wrong" do
    test "the match is case-insensitive on both the chunk and the quote" do
      assert {:cancelled, :frame_retraction} =
               IntentFrames.cancelling_frame(
                 "NEVER MIND. As an action item, Chris owns the podcast.",
                 "as AN action ITEM, Chris owns the podcast."
               )
    end

    test "a repeated quote is scoped from its FIRST occurrence" do
      # "do it" occurs twice; the retraction sits between them. Scoping
      # from the first (narrowest window) declines to cancel — the
      # conservative direction, and the one that under-suppresses rather
      # than over-suppresses.
      assert :ok = IntentFrames.cancelling_frame("do it — no, actually, do it later", "do it")
    end

    test "classes/0 lists every class the gate can return" do
      assert IntentFrames.classes() == [
               :frame_retraction,
               :frame_delegation,
               :frame_epistemic,
               :frame_perception,
               :frame_evaluative
             ]
    end
  end

  # ── THE ACCEPTED COST ──────────────────────────────────────────────
  #
  # Standing requirement on this task: a frame rule WILL suppress some
  # genuine asks, so find one and pin it rather than letting production
  # discover it.
  #
  # This is not a bug report and must not be "fixed" by weakening the
  # gate — it is the price, recorded. A lexical rule has no semantics,
  # so it cannot tell a retraction OF an ask from a retraction INSIDE
  # one. Both examples below are real asks a scribe should have
  # actioned, and both demote.
  #
  # Why the price is payable: a demotion is not a drop. The row still
  # reaches the queue as `off_topic` carrying `demoted_from`, so it is
  # visible in the intent rail, and a producer taking it back is exactly
  # the correction row the few-shot exemplar slot currently has none of.
  describe "the accepted cost — genuine asks this gate sacrifices" do
    test "a retraction of the SUBJECT, followed by a real ask, is suppressed" do
      assert {:cancelled, :frame_retraction} =
               IntentFrames.cancelling_frame(
                 "Scribe, never mind the colour — log an action item for Chris to fix the nav.",
                 "log an action item for Chris to fix the nav"
               )
    end

    test "an ask delegated through a pronoun the speaker meant as the agent is suppressed" do
      assert {:cancelled, :frame_delegation} =
               IntentFrames.cancelling_frame(
                 "The designer is in this meeting — ask them to darken the sidebar.",
                 "darken the sidebar"
               )
    end
  end
end
