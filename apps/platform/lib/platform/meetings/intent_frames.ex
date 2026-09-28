defmodule Platform.Meetings.IntentFrames do
  @moduledoc """
  The **frame gate**: a deterministic use/mention check over the
  classifier's own `evidence_quote` (task `01a04b6b`).

  ## The failure this exists to catch

  Task `01a03fb9` measured the false-positive budget of the shipped
  `off_topic_default` prompt: **8 of 102 recorded negatives fire**. Exactly
  one of the eight is a severed fragment. The rest share a single shape —
  the utterance *mentions* a task-shaped predicate inside a frame that
  cancels it, and the model lifts the predicate out as its
  `evidence_quote` while dropping the frame:

      "No, actually, never mind. As an action item, Chris needs to …"
        -> action_items, quote "As an action item, Chris needs to …"

      "I wonder if this is really briefworthy."
        -> brief_worthy,  quote "I wonder if this is really briefworthy"

      "Yeah, but the interaction design part is probably wrong."
        -> interaction_design, quote "the interaction design part is probably wrong"

  Every one of those quotes is a **valid verbatim span of its chunk**, so
  the existing evidence gate (`:blank` / `:not_in_chunk`) passes all eight
  — it fired 0 of 174 on this cassette. The citation is honest; the
  *reading* is not.

  ## Why a lexical rule and not a prompt change

  Two prompt-side levers were measured and rejected before this one:

    * **Confidence threshold** — the model emits `0.95` on all 174 rows,
      declines included. No threshold separates them.
    * **Few-shot correction exemplars** — the mechanism is wired and
      tested end to end, but `"Promote to prod. Yeah, I know, me too.
      Okay, so let's go."` is **already a verbatim negative exemplar in
      the shipped prompt** and still fires at 0.95. One of the eight is
      demonstrably immune to being shown itself as a labelled negative.

  A lexical gate is also the only lever that can be *measured offline*:
  it runs against the recorded responses in
  `priv/intent_eval/cassettes/` with no model call and no route to the
  classifier host.

  ## Forward scope — the one structural rule

  English frame operators scope **forward**. So an operator cancels the
  quote iff it **begins before the quote ends**:

      operator_start < quote_start + quote_length

  That single rule, and not a per-row exception list, is what decides
  each case:

      "Promote to prod. No, actually, never mind."
        -> :ok            (the retraction begins after the quote ends)
      "No, actually, never mind. Promote to prod."
        -> {:cancelled, :frame_retraction}

  Both are pinned in `intent_frames_test.exs`, "a retraction AFTER the
  quote does not scope backwards over it". Note that the second half is
  what stops the first from passing on a gate that never cancels at all.

  **Do not read forward scope as the reason the measured row**

      "Promote to prod. Yeah, I know, me too. Okay, so let's go."

  **survives.** It is not. That row survives *for want of an operator,
  not for want of scope*: the peer-agreement run "Yeah, I know, me too"
  is in none of the five lexicons below, at any position, so dropping
  the scope guard entirely still leaves the row firing. Mutation M2 in
  the test moduledoc is what established that. Anyone reaching for
  backward scope to catch this row would be fixing the wrong thing —
  see "What this does not reach" below.

  ## Backward scope — the quoted-label exception

  `:frame_quoted_label` (task `01a0e58f`) is the one class exempt from
  forward scope, because its construction modifies BACKWARDS: the head
  noun FOLLOWS the quote it labels.

      We keep getting the "can we ship it?" kind of comments
                          ^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^
                          quoted question   head noun

  The question is not being asked; it names a kind of remark. So the
  class has its own rule, applied to every `?` in the chunk: it cancels
  iff

      quote_start <= question_mark_offset <= quote_end + 1

  and ONLY whitespace or a closing quote mark (`"` `”` `'` `’`) separates
  that `?` from a head noun — `(kind|sort|type|style) of <word>`, or one
  of `comment(s)`, `question(s)`, `remark(s)`, `energy`, `vibe`,
  `moment`, `conversation(s)`, `thing`, `stuff`. Adjacency is the whole
  rule: "Is this a demo? No, this is the…" is a question followed by its
  answer, and "Can we ship it? Dana, decide by Friday." a question
  followed by an instruction; neither `?` is followed by a head noun, so
  neither cancels. A labelled question outside the quote's window does
  not reach an ask that does not contain it.

  ## The utterance-gate seam

  `:frame_speech_act` and `:frame_quoted_label` are the utterance gates.
  `utterance_gates_enabled?/1` reads the `decide/1` args map (key
  `:utterance_gates`, else the `:meeting_utterance_gates` application
  env, default `:enabled`); when it answers false,
  `IntentClassifier.evidence_verdict` skips those two classes ONLY and
  the five older classes keep firing. The seam exists so a falsifier can
  measure the same row with and without the new gates.

  When a quote occurs more than once in the chunk, the FIRST occurrence
  is used. That is the conservative direction: the earliest occurrence
  gives the smallest `quote_end`, hence the narrowest window in which an
  operator can cancel, hence the fewest suppressions.

  ## Two tiers, and why the second one is narrower

  `4 of 4` negatives containing one of the classifier's own taxonomy
  labels fire; `0 of 94` correct declines contain one. The classifier
  keys on the *label*, not the meaning — so operator classes that would
  be reckless in general are safe when the quote is talking *about* a
  label.

    * **Unconditional** (`:frame_retraction`, `:frame_delegation`) — the
      frame cancels any ask, label or no label. A retraction takes back
      what follows it whatever follows it; "we can ask him to …" hands
      the work to an unnamed person, which is `off_topic` by the
      prompt's own definition.

    * **Label-scoped** (`:frame_epistemic`, `:frame_perception`,
      `:frame_evaluative`) — cancels only when the quote also names a
      taxonomy label. These would be far too broad unconditionally:
      *"I wonder if the designer could make that button teal"* is a
      genuine polite ask, and *"Designer, the spacing is wrong, tighten
      it"* is a genuine visual_adjust. Both survive, because neither
      quote names a label. Only remarks *about* the taxonomy —
      "I do see the action items", "is this really briefworthy",
      "the interaction design part is probably wrong" — are cancelled.

  ## Accepted cost — this gate DOES suppress genuine asks

  It is a lexical rule with no semantics, so it cannot tell a retraction
  of an ask from a retraction *inside* one:

      "Scribe, never mind the colour — log an action item for Chris."

  is a real ask and this gate demotes it. That cost is pinned as a test
  (`intent_frames_test.exs`, "the accepted cost"), not left to be
  discovered in production. A demotion is recoverable: the row still
  lands in the queue as `off_topic` with `demoted_from` set, so it is
  visible in the intent rail and in the corrections corpus, and a
  producer correction of it is exactly the few-shot data the exemplar
  slot has none of.

  ## What this does not reach

  Of the 8 measured false positives it removes 5. The three it leaves:

    * `"and assign them."` — a severed fragment, not a frame failure.
      In production `IntentClassifier.content_bearing?/1` already drops
      it before any model call; the eval harness calls `decide/1`
      directly and so bypasses that gate.
    * `"Promote to prod. Yeah, I know, me too. Okay, so let's go."` —
      no operator in any of the five lexicons matches this chunk at any
      position. Catching it needs a *new class* (peer agreement), not a
      scope change. That class is refused on the same grounds as the
      hortative below: `0` rows in `control_60` and `0` in
      `unaddressed_probe_12` contain peer-agreement material, so the
      corpus cannot price it — and agreement does not cancel an ask in
      general ("Designer, make it teal. Yeah, I know, me too.").
    * `"Let's put together some kind of plan here."` — a hortative.
      A `let's` class would catch it and costs nothing *on this corpus*,
      but the shipped prompt's own worked example makes
      `"let's make that button teal"` a genuine `visual_adjust`
      (`off_topic_default.txt` line 81, evidence_quote
      `"make that button teal"` — the same quote shape as this row's,
      with the `let's` outside the quote in both).
      The corpus cannot see that cost because every control row is
      constructed to name a role, so no positive hortative is in it:
      `control_60` carries the *addressed* rewrite,
      `"Designer, make that primary button teal instead of the blue."`,
      and not the prompt's hortative original.
      Deliberately excluded rather than bought with a number.

  Re-measured independently under task `01a04b6b` against the same
  cassette: `3` / `59` / `11`, unchanged. Both refusals were re-derived
  and upheld, and the corpus blindness they rest on is now asserted
  directly — see `intent_frames_test.exs`, "the corpus cannot price the
  refused classes". That block turns red the moment a recording run puts
  a positive hortative or peer-agreement row in either positive slice,
  which is the point at which these two refusals must be revisited.
  """

  @typedoc "The frame class that cancelled an ask."
  @type class ::
          :frame_retraction
          | :frame_delegation
          | :frame_speech_act
          | :frame_quoted_label
          | :frame_epistemic
          | :frame_perception
          | :frame_evaluative

  # The classifier's own intent enum, written the way a person says it.
  # Word-bounded: without `\b`, "as transcriber" matches "scribe" and one
  # correct decline turns into a spurious label hit.
  @taxonomy_label ~r/\b(action items?|brief[- ]?worthy|decisions? recorded|open questions?|visual adjusts?|interaction design|off[- ]topic)\b/i

  # Cancels ANY ask that starts before it ends.
  #
  # `:frame_retraction` — the speaker takes it back. Forward-scoping by
  # definition: everything after "never mind" is withdrawn.
  #
  # `:frame_delegation` — the work is handed to an unnamed PERSON.
  #
  # Both halves are narrowed on purpose, and both narrowings cost
  # nothing measurable — they are here because this corpus cannot see
  # the cost of the wider version, which is not the same as there not
  # being one:
  #
  #   * the OBJECT is bare pronouns and indefinites only. "have the
  #     designer add a confirm step" and "ask the designer to tighten
  #     the spacing" are genuine control rows, so a named role must
  #     never be able to appear in this position.
  #   * the VERB is `ask` / `tell` only, NOT `get` / `have`. "ask" and
  #     "tell" take an animate object, so "ask them" is always a person.
  #     "get them aligned on the left" and "have them stack vertically"
  #     are ordinary design speech about OBJECTS, and a `get|have` verb
  #     set would demote both. No control row happens to use that
  #     phrasing, which is exactly why the restriction has to be
  #     reasoned rather than measured.
  @unconditional_frames [
    frame_retraction:
      ~r/\b(never ?mind|forget (it|that)|scratch that|strike that|disregard that|ignore that|cancel that|belay that|on second thought)\b|\b(no|wait),?\s+actually\b|\bactually,?\s+no\b/i,
    frame_delegation: ~r/\b(ask|tell)\s+(him|her|them|someone|somebody)\b/i,
    # Task 01a0e58f, acceptance 1(b). The speaker labels their own speech
    # act: what follows is a position, a remark, or a thought out loud,
    # not an ask. Closed lexicon; forward-scoped like the rest of the tier.
    frame_speech_act:
      ~r/\bmy (contention|point|argument|position|view) is\b|\b(all )?i'?m (just )?saying\b|\bi'?d argue\b|\bi would argue\b|\bfor the record,? i think\b|\bi'?m just thinking out loud\b|\bto play devil'?s advocate\b/i
  ]

  # Task 01a0e58f, acceptance 1(c). An unconditional class with its OWN
  # scope rule, so it is not in `@unconditional_frames` (whose members
  # are all read by the forward-scope `first_hit/3`). Each match starts
  # at a `?`; the class cancels iff that `?` lies in
  # [quote_start, quote_end + 1] and — enforced by the regex itself —
  # only whitespace or a closing quote mark stands between it and a head
  # noun. See "Backward scope" in the moduledoc.
  @quoted_label ~r/\?[\s"”'’]*(?:(?:kind|sort|type|style) of \w+|comments?|questions?|remarks?|energy|vibe|moment|conversations?|thing|stuff)\b/iu

  # The classes `utterance_gates_enabled?/1` switches. Nothing else reads it.
  @utterance_gate_classes [:frame_speech_act, :frame_quoted_label]

  # Cancels only when the quote NAMES one of our taxonomy labels, i.e.
  # the quote is talking about the category rather than issuing an ask
  # in it. See the moduledoc for why each of these is unsafe on its own.
  #
  # `:frame_epistemic`  — first-person doubt: "I wonder if …".
  # `:frame_perception` — a report of noticing: "I do see the action items".
  # `:frame_evaluative` — a quality predicated of the label rather than
  #   an ask made in it: "the interaction design part is probably wrong".
  @label_scoped_frames [
    frame_epistemic:
      ~r/\bi wonder (if|whether)\b|\bi'?m not sure\b|\bi am not sure\b|\bnot sure (if|whether)\b|\bi don'?t know (if|whether)\b|\bi doubt\b|\bis (this|that) really\b/i,
    frame_perception:
      ~r/\b(i|we) (do |can |could |just )?(see|saw|notice|noticed)\b|\bi'?m (seeing|looking at)\b/i,
    frame_evaluative:
      ~r/\b(is|are|was|were|seems?|feels?|looks?)\s+(probably\s+|maybe\s+|kind of\s+|sort of\s+|really\s+)?(wrong|off|right|weird|broken|bad|confusing|unclear|questionable|fine)\b/i
  ]

  @doc """
  Does a frame in `chunk_text` cancel the ask the model quoted?

  Returns `{:cancelled, class}` or `:ok`. Pure — no state, no I/O — so
  the whole gate is replayable against a recorded corpus with no model
  call, which is the entire reason it is the lever this task could
  actually measure.

  `:ok` for a blank quote and for a quote that is not a verbatim span of
  the chunk: those are the existing evidence gate's `:blank` and
  `:not_in_chunk` verdicts and this function must not restate them under
  a second name.

  `opts` takes `:skip` — a list of classes never to return. The
  classifier passes `utterance_gate_classes/0` here when
  `utterance_gates_enabled?/1` is false; a skipped class is removed from
  the scan rather than filtered from its result, so a skipped class that
  would have matched first cannot hide an older class behind it.
  """
  @spec cancelling_frame(term(), term(), keyword()) :: {:cancelled, class()} | :ok
  def cancelling_frame(chunk_text, quote_text, opts \\ [])

  def cancelling_frame(chunk_text, quote_text, opts)
      when is_binary(chunk_text) and is_binary(quote_text) do
    skip = Keyword.get(opts, :skip, [])

    # Offsets are taken in the DOWNCASED string and compared only against
    # offsets from that same string, so a case fold that changes byte
    # length cannot shift one relative to the other.
    chunk = String.downcase(chunk_text)
    needle = quote_text |> String.trim() |> String.downcase()

    if needle == "" do
      :ok
    else
      case :binary.match(chunk, needle) do
        :nomatch -> :ok
        {start, length} -> scan(chunk, needle, start, start + length, skip)
      end
    end
  end

  def cancelling_frame(_chunk_text, _quote_text, _opts), do: :ok

  defp scan(chunk, quote, quote_start, quote_end, skip) do
    forward = Keyword.drop(@unconditional_frames, skip)

    cond do
      class = first_hit(forward, chunk, quote_end) ->
        {:cancelled, class}

      :frame_quoted_label not in skip and
          quoted_label?(chunk, quote_start, quote_end) ->
        {:cancelled, :frame_quoted_label}

      true ->
        label_scoped(chunk, quote, quote_end)
    end
  end

  # The backward-scope rule. Every match of `@quoted_label` begins at its
  # `?`, and the regex has already required that only whitespace or a
  # closing quote mark separates that `?` from the head noun; what is
  # left is the window test.
  defp quoted_label?(chunk, quote_start, quote_end) do
    @quoted_label
    |> Regex.scan(chunk, return: :index)
    |> Enum.any?(fn [{mark, _length} | _] ->
      mark >= quote_start and mark <= quote_end + 1
    end)
  end

  defp label_scoped(chunk, quote, quote_end) do
    if mentions_taxonomy_label?(quote) do
      case first_hit(@label_scoped_frames, chunk, quote_end) do
        nil -> :ok
        class -> {:cancelled, class}
      end
    else
      :ok
    end
  end

  # `Regex.run/3` returns the FIRST match, which has the smallest start
  # offset — so if it does not begin before the quote ends, no later
  # match can either.
  defp first_hit(frames, chunk, quote_end) do
    Enum.find_value(frames, fn {class, regex} ->
      case Regex.run(regex, chunk, return: :index) do
        [{start, _length} | _] when start < quote_end -> class
        _ -> nil
      end
    end)
  end

  @doc """
  Does this text name one of the classifier's own intent labels in
  ordinary English?

  Exposed because it is the measured signal the label-scoped tier rests
  on — `4 of 4` negatives containing a label fire, `0 of 94` correct
  declines contain one — and a claim that sharp should be checkable
  directly rather than only through the gate that consumes it.
  """
  @spec mentions_taxonomy_label?(term()) :: boolean()
  def mentions_taxonomy_label?(text) when is_binary(text),
    do: Regex.match?(@taxonomy_label, text)

  def mentions_taxonomy_label?(_text), do: false

  @doc "Every frame class this gate can return, in tier then check order."
  @spec classes() :: [class()]
  def classes,
    do:
      Keyword.keys(@unconditional_frames) ++
        [:frame_quoted_label] ++ Keyword.keys(@label_scoped_frames)

  @doc """
  The classes the utterance-gate seam switches: `:frame_speech_act` and
  `:frame_quoted_label`. The five older classes are never in this list.
  """
  @spec utterance_gate_classes() :: [class()]
  def utterance_gate_classes, do: @utterance_gate_classes

  @doc """
  Are the utterance gates on for this `IntentClassifier.decide/1` call?

  False iff `args[:utterance_gates] == :disabled`, or the key is absent
  and `Application.get_env(:platform, :meeting_utterance_gates, :enabled)`
  is `:disabled`. The key, when present, wins over the env either way.
  This is the falsifier's seam; the privacy gate must never read it.
  """
  @spec utterance_gates_enabled?(map()) :: boolean()
  def utterance_gates_enabled?(args) when is_map(args) do
    setting =
      case Map.fetch(args, :utterance_gates) do
        {:ok, value} -> value
        :error -> Application.get_env(:platform, :meeting_utterance_gates, :enabled)
      end

    setting != :disabled
  end

  def utterance_gates_enabled?(_args), do: true
end
