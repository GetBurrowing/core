defmodule Platform.Meetings.ThreadResolverTest do
  @moduledoc """
  `ThreadResolver.resolve/2` is pure, so every test here is a plain
  `async: true` unit test with no database and no meeting.

  Two things this file deliberately does that a naive suite would not:

    * every utterance used in a scenario is first asserted to clear
      `IntentClassifier.content_bearing?/1`. That gate drops short
      utterances with no action verb, and a scenario built from a
      chunk that fails it would be testing a code path the classifier
      never reaches in production — green, and meaningless.

    * the relatedness numbers the floor was chosen from are asserted
      by value, not described in a comment. If the tokenizer or the
      stopword list drifts, the justification for the floor breaks
      loudly instead of quietly becoming false.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.{IntentClassifier, IntentEval, MeetingCandidate, ThreadResolver}

  doctest ThreadResolver

  @t0 ~U[2026-08-28 10:00:00Z]

  # The two candidates every scenario is built from. `c1` is about
  # dashboard performance, `c2` about the release date — no shared topic
  # vocabulary at all, which is what makes (c) a real discrimination
  # test rather than a coin flip.
  defp c1 do
    %MeetingCandidate{
      id: "11111111-1111-7111-8111-111111111111",
      speaker: "alice",
      evidence_quote: "we should make the dashboard load faster",
      last_utterance_at: @t0
    }
  end

  defp c2 do
    %MeetingCandidate{
      id: "22222222-2222-7222-8222-222222222222",
      speaker: "alice",
      evidence_quote: "the release date should slip to the fifteenth",
      last_utterance_at: @t0
    }
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp utterance(speaker, text, seconds), do: %{speaker: speaker, text: text, at: at(seconds)}

  @follow_up "make that mobile only"
  @unrelated "can someone book the offsite room"
  @release_follow_up "let's move that release date to the twentieth"

  # The two fragments the first cut of this module threaded onto an
  # unrelated candidate. Short, deictic, content-bearing, zero topic
  # overlap with the dashboard ask — every gate except relatedness was
  # satisfied, and relatedness was not consulted on that path at all.
  @unrelated_fragments ["let's cancel that meeting", "assign that to bruno"]

  describe "reachability — the scenarios are things the classifier would actually see" do
    test "every utterance in this suite clears the classifier's content gate" do
      # If any of these were false the classifier would never run on the
      # chunk, and every scenario below would be exercising a path
      # production cannot reach.
      for text <-
            [
              c1().evidence_quote,
              c2().evidence_quote,
              @follow_up,
              @unrelated,
              @release_follow_up
            ] ++ @unrelated_fragments do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} does not clear the content gate, so the classifier never runs on it"
      end

      # Positive control on the gate itself, same call shape: it is
      # capable of answering false, so the assertions above are not
      # true of every string.
      refute IntentClassifier.content_bearing?("yeah")
    end
  end

  describe "resolve/2 — proves it works" do
    test "same speaker, 8s later, a follow-up threads to the open candidate" do
      assert {:thread, threaded, reason} =
               ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])

      assert threaded.id == c1().id
      assert reason.rule == :anaphoric_fragment
      assert reason.deictic == "that"
      assert reason.elapsed_seconds == 8
      assert reason.open_candidates_in_window == 1
    end

    test "the follow-up threads on the anaphor, NOT on shared vocabulary" do
      # This is the measurement that forced two relatedness paths rather
      # than one number. "make that mobile only" and "we should make the
      # dashboard load faster" share exactly one token — `make` — and
      # `make` is a generic verb, so their TOPIC overlap is zero. A
      # purely lexical threader answers :new on the case the stage spec
      # says must thread.
      assert ThreadResolver.relatedness(@follow_up, c1().evidence_quote) == 0.0
      assert Enum.sort(ThreadResolver.topic_tokens(@follow_up)) == ["mobile"]

      assert Enum.sort(ThreadResolver.topic_tokens(c1().evidence_quote)) ==
               ["dashboard", "faster", "load"]
    end
  end

  describe "resolve/2 — catches the vacuous version" do
    test "(a) a DIFFERENT speaker saying the same thing does not thread" do
      assert ThreadResolver.resolve(utterance("bruno", @follow_up, 8), [c1()]) == :new

      # Positive control: identical call, matching speaker, threads. The
      # :new above is the speaker gate, not a broken scenario.
      assert {:thread, _, _} = ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])
    end

    test "(b) the SAME speaker 8s later on an unrelated topic does not thread" do
      assert ThreadResolver.resolve(utterance("alice", @unrelated, 8), [c1()]) == :new

      # The relatedness this rests on, by value.
      assert ThreadResolver.relatedness(@unrelated, c1().evidence_quote) == 0.0

      # Positive control that proximity and speaker identity were both
      # satisfied — only relatedness rejected it. Same speaker, same 8s,
      # and it threads when the content is a continuation.
      assert {:thread, _, _} = ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])
    end

    test "(d) a SHORT UNRELATED fragment carrying a bare deictic does not thread" do
      # The assertion that was missing. Each of these is <= 6 tokens,
      # carries `that`, is content-bearing, arrives from the SAME
      # speaker at the SAME 8s offset with EXACTLY ONE open candidate —
      # every condition `:anaphoric_fragment` fires on. Without a
      # relatedness floor of its own that path attaches all of them to
      # a dashboard candidate at relatedness 0.0, which is the wrong
      # threading the ticket calls worse than none.
      for text <- @unrelated_fragments do
        assert ThreadResolver.relatedness(text, c1().evidence_quote) == 0.0,
               "#{inspect(text)} was supposed to have ZERO topic overlap with the antecedent"

        assert ThreadResolver.shared_lexical(text, c1().evidence_quote) == [],
               "#{inspect(text)} shares vocabulary with the antecedent, so it is not " <>
                 "the zero-evidence case this test exists for"

        assert length(String.split(text)) <= 6
        assert Enum.any?(String.split(text), &(&1 == "that"))
      end

      # Both by value, and collected rather than asserted one at a time
      # so a regression names EVERY fragment it broke instead of
      # stopping at the first.
      threaded =
        Enum.filter(@unrelated_fragments, fn text ->
          match?({:thread, _, _}, ThreadResolver.resolve(utterance("alice", text, 8), [c1()]))
        end)

      assert threaded == [],
             "#{inspect(threaded)} threaded onto an unrelated candidate at zero relatedness"

      # POSITIVE CONTROL, and it is the whole difficulty of this fix:
      # the case that MUST thread also scores 0.0 on topic overlap, so
      # the :new answers above cannot come from a topic floor. They come
      # from the shared-token floor, and this one clears it on `make`.
      assert ThreadResolver.relatedness(@follow_up, c1().evidence_quote) == 0.0
      assert ThreadResolver.shared_lexical(@follow_up, c1().evidence_quote) == ["make"]

      assert {:thread, threaded, %{rule: :anaphoric_fragment, shared: ["make"]}} =
               ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])

      assert threaded.id == c1().id
    end

    test "(e) the anaphoric path's vocabulary is wider than the topic path's, and by how much" do
      # Why a floor on relatedness/2 could not have fixed (d): the case
      # that must thread scores 0.0 there too, so ANY non-zero topic
      # floor kills it. The separation lives in `make` — a generic verb
      # `@stopwords` strips from the topic measure on purpose.
      assert Enum.sort(ThreadResolver.topic_tokens(@follow_up)) == ["mobile"]
      assert Enum.sort(ThreadResolver.lexical_tokens(@follow_up)) == ["make", "mobile"]

      assert Enum.sort(ThreadResolver.topic_tokens(c1().evidence_quote)) ==
               ["dashboard", "faster", "load"]

      assert Enum.sort(ThreadResolver.lexical_tokens(c1().evidence_quote)) ==
               ["dashboard", "faster", "load", "make"]

      # The wider vocabulary is strictly wider — it never removes a
      # topic token, so it cannot weaken the topic path.
      for text <- [@follow_up, @unrelated, @release_follow_up | @unrelated_fragments] do
        assert MapSet.subset?(
                 ThreadResolver.topic_tokens(text),
                 ThreadResolver.lexical_tokens(text)
               )
      end

      # And the deictic itself is NOT lexical vocabulary. If it were, a
      # shared `that` would be the evidence that a `that` points here,
      # which is the circular version of this whole rule.
      refute MapSet.member?(ThreadResolver.lexical_tokens(@follow_up), "that")

      assert ThreadResolver.anaphoric_shared_floor() == 1
    end

    test "(c) with TWO open candidates a follow-up threads to the RIGHT one" do
      # Newest-first, the order `Candidates.open_for_meeting/1` returns.
      # c1 is deliberately the HEAD and the WRONG answer, so an
      # implementation that reaches for the most recent open candidate
      # fails here rather than passing by luck.
      open = [c1(), c2()]
      assert hd(open).id == c1().id

      assert {:thread, threaded, reason} =
               ThreadResolver.resolve(utterance("alice", @release_follow_up, 8), open)

      assert threaded.id == c2().id
      refute threaded.id == c1().id
      assert reason.rule == :topic_overlap
      assert reason.shared == ["date", "release"]
      assert reason.open_candidates_in_window == 2

      # The other candidate is untouched. resolve/2 is pure, so this is
      # the strongest form the assertion can take here: nothing about c1
      # changed and c1 is not what came back. The persisted version of
      # "untouched" — that no write lands on the dashboard row — belongs
      # to stage 4, which is what does the writing.
      [_, other] = open
      assert other.id == c2().id
      assert Enum.at(open, 0).last_utterance_at == @t0
      assert Enum.at(open, 0).evidence_quote == "we should make the dashboard load faster"

      # And it discriminates by score, not by position: the follow-up is
      # unrelated to c1 and strongly related to c2.
      assert ThreadResolver.relatedness(@release_follow_up, c1().evidence_quote) == 0.0
      assert ThreadResolver.relatedness(@release_follow_up, c2().evidence_quote) > 0.66
    end
  end

  describe "resolve/2 — a nil speaker never threads" do
    test "an unattributed utterance does not attach to an unattributed candidate" do
      # Stage 1 stores an unattributed speaker as nil, precisely so this
      # cannot happen: `"" == ""` or `nil == nil` would read two
      # strangers as one person continuing a thought.
      unattributed = %{c1() | speaker: nil}

      assert ThreadResolver.resolve(%{speaker: nil, text: @follow_up, at: at(8)}, [unattributed]) ==
               :new

      # Every combination of unknown, not just the symmetric one.
      assert ThreadResolver.resolve(%{speaker: nil, text: @follow_up, at: at(8)}, [c1()]) == :new

      assert ThreadResolver.resolve(utterance("alice", @follow_up, 8), [unattributed]) == :new

      # `""` is normalised to unknown too, in case a caller bypasses
      # stage 1's `speaker_or_nil/1` and hands the raw classifier value
      # straight through.
      assert ThreadResolver.resolve(%{speaker: "", text: @follow_up, at: at(8)}, [
               %{c1() | speaker: ""}
             ]) == :new

      # POSITIVE CONTROL: the identical utterance and candidate with the
      # speaker KNOWN on both sides threads. The four :new answers above
      # are the nil rule, not a scenario that never threads.
      assert {:thread, _, _} = ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])
    end
  end

  describe "resolve/2 — the time window" do
    test "a continuation past the window starts a new candidate" do
      window = ThreadResolver.window_seconds()

      assert {:thread, _, _} =
               ThreadResolver.resolve(utterance("alice", @follow_up, window), [c1()])

      assert ThreadResolver.resolve(utterance("alice", @follow_up, window + 1), [c1()]) == :new
    end

    test "an utterance BEFORE the candidate's last utterance never threads" do
      assert ThreadResolver.resolve(utterance("alice", @follow_up, -1), [c1()]) == :new
    end

    test "a candidate with no last_utterance_at has no clock and never threads" do
      clockless = %{c1() | last_utterance_at: nil}
      assert ThreadResolver.resolve(utterance("alice", @follow_up, 8), [clockless]) == :new
      assert {:thread, _, _} = ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])
    end
  end

  describe "resolve/2 — refuses to guess" do
    test "no open candidates" do
      assert ThreadResolver.resolve(utterance("alice", @follow_up, 8), []) == :new
    end

    test "a bare anaphor with two candidates in the window is ambiguous, so it does not thread" do
      # The clause that stops this degenerating into "attach to the most
      # recent open candidate". With one candidate the deictic threads;
      # add a second and the same utterance refuses, because "that"
      # names neither of them.
      assert {:thread, _, %{rule: :anaphoric_fragment}} =
               ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])

      assert ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1(), c2()]) == :new
    end

    test "a LONG utterance containing a deictic is not a fragment and does not thread on it" do
      # The anaphor path is a FRAGMENT rule: a short clause leaning on
      # an antecedent. An utterance long enough to carry its own subject
      # is not leaning on anything, whatever pronouns it happens to
      # contain — and without the length cap, every same-speaker
      # in-window utterance containing "that" or "it" would thread,
      # which is the vacuous version wearing a different hat.
      long =
        "we should probably revisit that whole approach to onboarding at some point next quarter"

      assert length(String.split(long)) > 6
      assert IntentClassifier.content_bearing?(long)
      # No topic overlap either, so the anaphor is the ONLY thing that
      # could attach it.
      assert ThreadResolver.relatedness(long, c1().evidence_quote) == 0.0
      assert "that" in String.split(long)

      assert ThreadResolver.resolve(utterance("alice", long, 8), [c1()]) == :new

      # POSITIVE CONTROL: a SHORT utterance with the same deictic, same
      # speaker, same instant, same single candidate, does thread. The
      # :new above is the length cap and nothing else.
      assert {:thread, _, %{rule: :anaphoric_fragment}} =
               ThreadResolver.resolve(utterance("alice", @follow_up, 8), [c1()])
    end

    test "a tie at the top of the scores resolves to :new rather than to whichever came first" do
      twin_a = %{c1() | id: "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"}
      twin_b = %{c1() | id: "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb"}
      text = "the dashboard load is still slow"

      # Both candidates carry the same evidence, so both score
      # identically; there is no honest answer to WHICH one.
      assert ThreadResolver.relatedness(text, twin_a.evidence_quote) ==
               ThreadResolver.relatedness(text, twin_b.evidence_quote)

      assert ThreadResolver.resolve(utterance("alice", text, 8), [twin_a, twin_b]) == :new

      # Positive control: against a single one of them it threads, so
      # the :new above is the tie and not an unrelated failure.
      assert {:thread, _, %{rule: :topic_overlap}} =
               ThreadResolver.resolve(utterance("alice", text, 8), [twin_a])
    end

    test "malformed utterances answer :new instead of raising" do
      assert ThreadResolver.resolve(%{speaker: "alice", text: nil, at: at(8)}, [c1()]) == :new

      assert ThreadResolver.resolve(%{speaker: "alice", text: @follow_up, at: nil}, [c1()]) ==
               :new

      assert ThreadResolver.resolve(%{}, [c1()]) == :new
      assert ThreadResolver.resolve(nil, [c1()]) == :new
    end
  end

  describe "the relatedness floor is where it is for a measured reason" do
    test "the floor is 'more than half the shorter utterance's topic vocabulary'" do
      # The overlap coefficient is |A ∩ B| / min(|A|, |B|) — the
      # fraction of the SHORTER utterance's topic words the candidate
      # already contains. Requiring more than half means the majority of
      # what the new utterance is about is already on the candidate;
      # below half it is mostly introducing new topic, which is a new
      # candidate.
      assert ThreadResolver.overlap_floor() > 0.5
      assert ThreadResolver.overlap_floor() < 0.75
    end

    test "the discriminating scenario clears the floor with real margin" do
      score = ThreadResolver.relatedness(@release_follow_up, c2().evidence_quote)
      assert score > ThreadResolver.overlap_floor() + 0.1
    end
  end

  describe "RECALL GUARD — threading must not swallow the labelled corpus" do
    # The guard no single scenario can replace. Every check above uses
    # one or two candidates; a resolver that quietly absorbs almost
    # everything into one candidate passes all of them and destroys real
    # intents in production. Only a corpus-level count catches that.
    #
    # The corpus carries no speaker and no timestamp — verified: the row
    # schema is id/label/origin/prior/slice/source_file/text, and `prior`
    # is [] on all 174 rows. So this is not a replay of recorded
    # threading; it is a SYNTHESISED worst case. All 72 positive rows are
    # given the SAME speaker at the SAME instant, which holds the speaker
    # gate and the time gate permanently open and leaves the relatedness
    # floor as the only thing standing between 72 candidates and 1.
    #
    # MEASURED 2026-08-28 on this implementation: 60 distinct candidates
    # from 72 positives, ratio 0.8333, all 12 collapses via
    # :topic_overlap. The floor asserted below is 0.80, chosen with the
    # measured 0.8333 in hand. It is not slack: dropping @overlap_floor
    # to 0.50 yields 56/72 = 0.7778 and turns this red, and the mandated
    # `{:thread, hd(open_candidates), :always}` mutation yields 1/72 =
    # 0.0139.
    @recall_floor 0.80

    test "the resolver produces at least #{@recall_floor} of the corpus's distinct candidates" do
      positives = corpus_positives()

      # Positive control on the corpus load itself. An empty or tiny list
      # would sail through the ratio assertion below by having nothing to
      # collapse.
      assert length(positives) == 72,
             "the #{@recall_floor} floor was measured against 72 positive rows; the corpus " <>
               "now has #{length(positives)}, so re-measure the floor rather than moving this"

      assert Enum.all?(positives, &(is_binary(&1) and &1 != ""))

      distinct = replay(positives)

      ratio = distinct / length(positives)

      assert ratio >= @recall_floor,
             "threading collapsed the corpus to #{distinct}/#{length(positives)} " <>
               "(#{Float.round(ratio, 4)}), below the #{@recall_floor} floor"

      # The other direction: threading must actually DO something on this
      # corpus, or the guard is satisfied by a resolver that never
      # threads at all and the number above means nothing.
      assert distinct < length(positives),
             "the resolver threaded nothing across the whole corpus, so this guard proves nothing"
    end

    test "the guard has range — an always-thread resolver would score 1" do
      # Demonstrates the assertion above can fail, by replaying the same
      # corpus through the degenerate rule the mutation applies.
      positives = corpus_positives()

      collapsed =
        Enum.reduce(positives, [], fn text, open ->
          case open do
            [] -> [text]
            [first | _] -> [first]
          end
        end)

      assert length(collapsed) == 1
      assert 1 / length(positives) < @recall_floor
    end
  end

  describe "RECALL GUARD — the anaphoric path, which the corpus alone cannot reach" do
    # The guard above measures `:topic_overlap` and ONLY `:topic_overlap`.
    # It is structurally incapable of exercising `:anaphoric_fragment`,
    # and `:anaphoric_fragment` is the path carrying this stage's
    # proves-it-works case. A guard that cannot exercise a path is not a
    # guard on it, so this block first PROVES the blindness by value and
    # then removes it by synthesising the utterances the corpus lacks.

    # Four short deictic fragments with no relationship to a meeting
    # transcript about agents, briefs and podcasts. Fixed, not sampled,
    # so the numbers below are reproducible.
    @synthetic_unrelated [
      "let's cancel that meeting",
      "assign that to bruno",
      "put that on the invoice",
      "send that to legal"
    ]

    # MEASURED 2026-08-28 on this implementation: 14 of the 288
    # (row, fragment) pairs attach, i.e. 4.86%. The bound below is a
    # round 10%. It is above the measurement rather than on it, and the
    # failure mode it guards — the shared-token floor removed, which is
    # the state this file was written to catch — measures 288/288, so
    # the assertion has an order of magnitude of range either side.
    @synthetic_attach_bound 0.10

    test "the corpus provably cannot reach the anaphoric path" do
      positives = corpus_positives()
      assert length(positives) == 72

      counts = Enum.map(positives, &length(tokens(&1)))
      assert Enum.min(counts) == 6
      assert Enum.max(counts) == 19
      assert Enum.at(Enum.sort(counts), div(length(counts), 2)) == 14

      # The eligibility condition, counted directly on the corpus.
      eligible = Enum.count(positives, &anaphoric_eligible?/1)

      assert eligible == 0,
             "#{eligible} corpus rows are <= 6 tokens with a deictic; the corpus can now " <>
               "reach this path on its own and the synthesis below may be redundant"

      # And the only shape in which the path is eligible at all — at
      # most one candidate open — collapses nothing, at any bound. So
      # no arrangement of this corpus exercises the path.
      for keep <- [1, 2, 3, 5] do
        assert bounded_replay(positives, keep) == 72,
               "bounded-open replay at keep=#{keep} collapsed the corpus, which would mean " <>
                 "the corpus does reach this path"
      end
    end

    test "a synthesised fragment that LEANS on its antecedent threads — the path is exercised" do
      positives = corpus_positives()

      results =
        Enum.map(positives, fn text ->
          {text,
           ThreadResolver.resolve(utterance("same", leaning_fragment(text), 8), [row(text)])}
        end)

      threaded =
        Enum.count(results, fn {_text, result} ->
          match?({:thread, _, %{rule: :anaphoric_fragment}}, result)
        end)

      assert threaded == 72,
             "only #{threaded}/72 synthesised leaning fragments threaded, so this guard is " <>
               "not exercising :anaphoric_fragment across the corpus"

      # Every synthesised fragment is something the classifier would
      # actually hand over: short, deictic, content-bearing. A guard
      # built from unreachable strings guards nothing.
      for text <- positives do
        fragment = leaning_fragment(text)
        assert anaphoric_eligible?(fragment)
        assert IntentClassifier.content_bearing?(fragment)

        # And it reached `:anaphoric_fragment` because `:topic_overlap`
        # DECLINED it, not because the topic path was never consulted.
        # If the ballast word ever appears in the corpus this goes red
        # here rather than silently retargeting the guard.
        assert ThreadResolver.relatedness(fragment, text) < ThreadResolver.overlap_floor(),
               "#{inspect(fragment)} clears the topic floor against its row, so it would " <>
                 "thread on :topic_overlap and prove nothing about the anaphoric path"
      end
    end

    test "a synthesised UNRELATED fragment does not attach to an arbitrary corpus row" do
      positives = corpus_positives()

      pairs = for text <- positives, fragment <- @synthetic_unrelated, do: {text, fragment}
      assert length(pairs) == 288

      attached =
        Enum.filter(pairs, fn {text, fragment} ->
          match?(
            {:thread, _, _},
            ThreadResolver.resolve(utterance("same", fragment, 8), [row(text)])
          )
        end)

      rate = length(attached) / length(pairs)

      assert rate <= @synthetic_attach_bound,
             "#{length(attached)}/#{length(pairs)} unrelated deictic fragments attached " <>
               "(#{Float.round(rate, 4)}), above the #{@synthetic_attach_bound} bound"

      # The load-bearing half: not one attachment happened on zero
      # evidence. Every fragment that did attach shares a real word with
      # the row it attached to. Zero-evidence attachment is the defect
      # this whole block exists for, and it is asserted here over 288
      # real pairs rather than over three hand-picked strings.
      for {text, fragment} <- attached do
        assert ThreadResolver.shared_lexical(fragment, text) != [],
               "#{inspect(fragment)} attached to #{inspect(text)} sharing NOTHING"
      end

      # RANGE. The same 288 pairs under the degenerate rule this floor
      # replaced — a short deictic fragment attaches to the single open
      # candidate, full stop — attach every time. So the bound above is
      # not satisfied by an implementation that never threads either:
      # the previous test threads on all 72 leaning fragments.
      degenerate =
        Enum.count(pairs, fn {_text, fragment} -> anaphoric_eligible?(fragment) end)

      assert degenerate == 288
      assert degenerate / length(pairs) > @synthetic_attach_bound
    end
  end

  # A fragment built to lean on THIS row: short, carries `that`, opens
  # on an action verb so the content gate keeps it, and shares exactly
  # the row's first lexical token so it has evidence to attach on.
  #
  # `tomorrow` is a deliberate ballast word, asserted absent from the
  # corpus in the test below. Without it the fragment's ONLY topic token
  # would be the shared one, the overlap coefficient would be 1.0, and
  # every fragment would thread on `:topic_overlap` — exercising the
  # path this block exists to leave alone.
  defp leaning_fragment(text) do
    token = text |> ThreadResolver.lexical_tokens() |> Enum.sort() |> hd()
    "move that #{token} tomorrow"
  end

  defp row(text) do
    %MeetingCandidate{
      id: "33333333-3333-7333-8333-333333333333",
      speaker: "same",
      evidence_quote: text,
      last_utterance_at: @t0
    }
  end

  defp tokens(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}']+/u, " ")
    |> String.split(" ", trim: true)
  end

  # The `:anaphoric_fragment` eligibility condition, stated here
  # independently of the module so the corpus can be counted against it.
  @deictics ~w(it its it's that that's thats their them themselves these they this those)
  defp anaphoric_eligible?(text) do
    ts = tokens(text)
    length(ts) <= 6 and Enum.any?(ts, &(&1 in @deictics))
  end

  # Replay with at most `keep` candidates open at once — the shape
  # production actually has, and the only shape in which the anaphoric
  # path is eligible.
  defp bounded_replay(texts, keep) do
    {distinct, _open} =
      Enum.reduce(texts, {0, []}, fn text, {distinct, open} ->
        case ThreadResolver.resolve(%{speaker: "same", text: text, at: @t0}, open) do
          :new -> {distinct + 1, Enum.take([row(text) | open], keep)}
          {:thread, _candidate, _reason} -> {distinct, open}
        end
      end)

    distinct
  end

  defp corpus_positives do
    IntentEval.root()
    |> IntentEval.load_slice_rows()
    |> Map.values()
    |> Enum.reject(&(&1["label"] == "off_topic"))
    |> Enum.sort_by(& &1["id"])
    |> Enum.map(& &1["text"])
  end

  # Fold the REAL resolve/2 over the corpus, same speaker, same
  # instant, accumulating candidates exactly as stage 4 will.
  defp replay(texts) do
    texts
    |> Enum.reduce([], fn text, open ->
      case ThreadResolver.resolve(%{speaker: "same", text: text, at: @t0}, open) do
        :new ->
          [
            %MeetingCandidate{
              id: Integer.to_string(length(open)),
              speaker: "same",
              evidence_quote: text,
              last_utterance_at: @t0
            }
            | open
          ]

        {:thread, _candidate, _reason} ->
          open
      end
    end)
    |> length()
  end
end
