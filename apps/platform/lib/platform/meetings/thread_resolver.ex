defmodule Platform.Meetings.ThreadResolver do
  @moduledoc """
  Decides whether an incoming utterance CONTINUES an open candidate or
  starts a new one (task `01a03fb9` stage 3).

  Pure. No database, no model call, no clock of its own — every input
  arrives as an argument so the whole decision is testable without a
  meeting, and so a wrong answer can be reproduced from the two values
  that produced it.

  ## Why not embeddings

  The ticket says "`embeddings` already exists for corpus retrieval".
  Checked before writing this: it is `Platform.Memory.search/3`, an
  external HTTP call against `MEMORY_SERVICE_URL` with a 5s timeout,
  which falls back to a **Noop provider when the variable is unset**,
  and there is no pgvector dependency in the tree. A semantic threader
  on the Noop path returns nothing and therefore SILENTLY NEVER
  THREADS — a feature that appears to work, emits no error, and quietly
  does nothing. That is precisely the invisible failure the ticket's own
  "Careful" section warns about, so the cheap tier is the whole of this
  stage and the escalation to a stateful classifier prompt stays the
  ticket's third option.

  ## The rule

  A candidate is *eligible* only if all three hold:

    1. **Same speaker.** Both sides non-nil and equal. `nil` NEVER
       matches, not even another `nil` — see below.
    2. **Inside the window.** The utterance is at or after the
       candidate's `last_utterance_at` and no more than
       **60** seconds after it. A candidate with a nil
       `last_utterance_at` has no clock and is never eligible.
    3. **Related.** One of the two relatedness paths below fires.

  Among eligible candidates the highest-scoring one wins, and it must
  win OUTRIGHT: a tie at the top resolves to `:new`. Attaching to the
  wrong candidate silently extends the wrong timer, so an ambiguous
  answer is refused rather than guessed.

  ## `nil` speaker never threads

  `IntentClassifier.segment_speaker/2` answers `""` for an unattributed
  segment and stage 1 stores that as `nil` on purpose. Two unattributed
  utterances are not evidence of one person continuing a thought — they
  are two strangers. A rule that compared `"" == ""`, or that treated
  `nil == nil` as a match, would thread them together. So the speaker
  test is "both known AND equal", and every nil-speaker case answers
  `:new`.

  ## Two relatedness paths, because one number cannot do it

  Measured while writing this stage: the spec's own proves-it-works
  case, `"make that mobile only"` following `"we should make the
  dashboard load faster"`, shares exactly ONE token with its
  antecedent — `make` — and `make` is a generic action verb that
  unrelated asks share constantly. Strip generic verbs and function
  words and the topic overlap is **zero**. A pure lexical threader
  therefore answers `:new` on the one case that must thread. The signal
  a human actually reads there is not vocabulary, it is the dangling
  `that`.

  Hence:

    * `:topic_overlap` — the overlap coefficient over *topic tokens*
      (`|A ∩ B| / min(|A|, |B|)`, everything in `@stopwords` removed)
      is at least **0.55**. Overlap coefficient rather than
      Jaccard because a four-word follow-up onto a twelve-word ask is
      the normal shape here, and Jaccard penalises exactly that.

    * `:anaphoric_fragment` — the utterance is a short fragment
      (at most **6** tokens) containing a deictic with no
      antecedent of its own (`that`, `it`, `those`, ...), there is
      exactly ONE candidate through the speaker and time gates, AND
      the fragment shares at least **1** *lexical* token with that
      candidate.

  The single-candidate clause stops this degenerating into "attach to
  the most recent open candidate". A bare anaphor says "something
  already said", never WHICH thing; with two open candidates in the
  window a deictic is genuinely ambiguous, so the path switches itself
  off.

  ## Why the anaphoric path has a relatedness floor of its OWN

  The single-candidate clause is not enough on its own, and the first
  cut of this module shipped without anything more. Measured on the
  proves-it-works setup — speaker `alice`, +8s, one open candidate
  about *"we should make the dashboard load faster"*:

  | fragment | topic overlap | should thread? |
  |---|---|---|
  | `"make that mobile only"` | 0.0 | yes |
  | `"let's cancel that meeting"` | 0.0 | **no** |
  | `"assign that to bruno"` | 0.0 | **no** |

  All three are short, all three carry `that`, all three clear
  `IntentClassifier.content_bearing?/1`, and all three had exactly one
  thing to attach to. With no relatedness test on this path all three
  threaded, so proximity plus speaker identity plus a bare pronoun was
  sufficient — and *"let's cancel that meeting"* silently swallowed a
  dashboard candidate's timer.

  A floor on `relatedness/2` cannot fix it: the case that MUST thread
  scores 0.0 too. Any non-zero topic floor kills the one case the path
  exists for. The separation is not in the topic vocabulary at all, it
  is in the verb:

      "make that mobile only"     ∩ candidate = ["make"]
      "let's cancel that meeting" ∩ candidate = []
      "assign that to bruno"      ∩ candidate = []

  `make` is in `@stopwords`, deliberately, so it contributes nothing to
  `:topic_overlap` — two unrelated asks share `make` constantly and a
  topic measure must not read it. But this path has no topic overlap
  left to read, and a fragment that reuses the candidate's own verb is
  doing something a fragment that brings a NEW verb is not. So
  `:anaphoric_fragment` reads a wider vocabulary than `:topic_overlap`
  does — `lexical_tokens/1`, which is the topic tokens plus the generic
  action verbs in `@generic_verbs` — and requires the fragment and the
  candidate to share at least one of them. The topic path is untouched:
  `@stopwords`, `@overlap_floor` and `relatedness/2` all mean exactly
  what they meant before.

  ### Why a COUNT and not a coefficient

  `@overlap_floor` is a ratio because both sides of a topic comparison
  carry several topic words. A fragment does not: *"make that mobile
  only"* has two lexical tokens in total, so a coefficient over it is
  quantised to `{0.0, 0.5, 1.0}` and the same fragment with one more
  word in it scores 0.33. That makes the decision depend on the
  fragment's length rather than on its evidence, which is the opposite
  of what a fragment rule wants. One shared token is a floor of
  *evidence*, and the point is that it is not zero.

  ## Why the floor is 0.55

  Principle first, corpus second. The overlap coefficient is the
  fraction of the SHORTER utterance's topic vocabulary the candidate
  already contains, so a floor above 0.5 says "more than half of what
  this utterance is about is already on that candidate". Below half,
  the majority of the utterance is new topic, which is a new candidate
  by definition. 0.55 is that principle expressed as one comparable
  number.

  The labelled `intent_eval` corpus was then used to CHECK the value,
  not to pick it. Replaying the 72 positive rows through `resolve/2`
  with the speaker and time gates held permanently open yields 60
  distinct candidates at every floor from 0.55 to 0.70 — a flat
  plateau, so the choice is not knife-edge. It falls to 56 at 0.50 and
  49 at 0.34. The measurement and the floor it justifies both live in
  `ThreadResolverTest` as assertions rather than as prose, so they
  break loudly if the tokenizer drifts.

  ## Known, accepted costs

    * An anaphoric follow-up while two candidates are open does not
      thread. That is a recall loss taken deliberately: the ticket
      states wrong threading is worse than none. Recovering those is
      the ticket's third tier (give the classifier the open candidates
      and let it say), not this one.
    * An anaphoric follow-up that shares NO vocabulary with its
      antecedent — `"drop that too"` after a dashboard ask — does not
      thread either. Same trade, same direction. One shared token is
      the weakest evidence this module is willing to act on, and it is
      still evidence; zero is not.
    * One shared token is a low bar and it does admit some wrong
      attachments. Measured over the labelled corpus: replaying four
      unrelated short deictic fragments against all 72 positive rows,
      one row at a time, attaches on **14 of 288** pairs — every one of
      them on a genuinely shared word (`meeting` against a row
      addressed to *"Meeting scribe"*, `put` against a row that says
      *"put the logo in the top left"*). Without the floor the same
      replay attaches on **288 of 288**. The residual is a known cost
      of the cheap tier; the ticket's third tier is what removes it.
    * `@stopwords` strips generic verbs, so a word that is BOTH a
      generic verb and this meeting's topic noun — `release` is the
      obvious one — stops contributing to overlap. It costs recall,
      never precision, which is the direction this stage errs in.

  ## Tokenizer is deliberately not shared with `IntentClassifier`

  `IntentClassifier` has its own private tokenizer and its own filler
  and action-verb sets, and this module does NOT reach for them. They
  answer a different question — "is this worth a model call" — and the
  lists are tuned for that. Wiring them together would mean retuning
  the content gate silently retunes threading, which is a coupling
  nobody would predict from either file. The duplication is the
  cheaper of the two.
  """

  alias Platform.Meetings.MeetingCandidate

  @typedoc """
  The incoming utterance. A plain map so the caller never has to build a
  struct, and so this stays trivially constructible in a test.
  """
  @type utterance :: %{
          required(:speaker) => String.t() | nil,
          required(:text) => String.t() | nil,
          required(:at) => DateTime.t()
        }

  @type reason :: %{required(:rule) => atom(), optional(atom()) => term()}

  @type result :: {:thread, MeetingCandidate.t(), reason()} | :new

  # How long after a candidate's last utterance a continuation is still
  # plausible. The classifier holds a chunk at most
  # `IntentClassifier.@default_max_hold_ms` (4_000) before emitting, so
  # 60s is roughly fifteen consecutive classified chunks from one
  # speaker — comfortably more than the 8s the stage spec exercises,
  # and short enough to stay inside one topic rather than one agenda
  # item. It is a plausibility bound, NOT the discriminating signal:
  # the tests prove separation comes from the relatedness floor, since
  # every negative case in the suite sits well inside this window.
  @window_seconds 60

  # Overlap coefficient a topic match must clear. See the test module
  # for the measurement this was chosen from.
  @overlap_floor 0.55

  # An utterance longer than this carries its own subject and is not a
  # fragment leaning on an antecedent, whatever pronouns it contains.
  @fragment_max_tokens 6

  # Words that point at something already said instead of naming it.
  # These are what makes a short utterance a continuation rather than a
  # statement.
  @deictics MapSet.new(~w(
    it its it's that that's thats their them themselves these they this
    those
  ))

  # Generic action verbs. Every one of these is ALSO in `@stopwords`,
  # so none of them contributes to `:topic_overlap` — a shared `make`
  # must never make two unrelated asks look like one topic. But a
  # fragment that reuses the candidate's own verb is doing something a
  # fragment that brings a new verb is not, and `:anaphoric_fragment`
  # is the one path with no topic overlap left to read, so it reads
  # these where the topic path cannot.
  #
  # Deliberately EXCLUDES modals (`should`, `must`, `will`), auxiliaries
  # (`be`, `have`, `do`) and perception/state verbs (`see`, `think`,
  # `mean`, `say`, `like`). Two unrelated asks share `should` or `is`
  # constantly; sharing one of those is evidence of English, not of a
  # common subject. Same exclusion `IntentClassifier.@action_tokens`
  # makes, arrived at for the same reason, and still not shared with it
  # — see the moduledoc.
  @generic_verbs MapSet.new(~w(
    get gets getting give given go goes going gonna got
    keep kept
    let let's lets
    make makes making move moves moving
    need needs
    put puts putting
    set sets setting
    take takes taking try trying
    use used uses using
    want wants
  ))

  # How many tokens an anaphoric fragment must share with the candidate
  # it leans on. See the moduledoc for why this is a COUNT and not a
  # ratio, and `ThreadResolverTest` for the measurement.
  @anaphoric_shared_floor 1

  # Function words and generic verbs: tokens that appear in asks about
  # anything at all and so carry no topic. Everything left after these
  # are removed is a "topic token". Deliberately purpose-built for a
  # similarity measure and NOT copied from the classifier's gate lists —
  # see the moduledoc.
  @stopwords MapSet.new(~w(
    a about actually after again all also am an and another any anyway
    are as at
    back be because been before being both but by
    can cant can't could couldnt couldn't
    did didnt didn't do does doesnt doesn't doing done dont don't down
    each either else even ever every
    few for from
    get gets getting give given go goes going gonna got
    had has have having he her here hers herself him himself his how
    i i'd i'll i'm i've id ill im ive if in into is isnt isn't it it's
    its itself
    just
    keep kept kind
    let let's lets like ll
    make makes making many may maybe me mean might mine more most move
    moves moving much must my myself
    need needs never new no nor not now
    of off oh ok okay on once one only or other others otherwise ought
    our ours ourselves out over own
    per put puts putting
    quite
    re really right
    said same say says see seeing seen set sets setting shall she should
    shouldnt shouldn't so some something sort still such sure
    take takes taking than that that's thats the their theirs them
    themselves then there there's theres these they thing things think
    this those though through to too try trying
    uh um under until up us use used uses using
    ve very
    want wants was wasnt wasn't way we well were weren't werent what
    when where whether which while who whom whose why will with within
    without wont won't would wouldnt wouldn't
    yeah yep yes yet you you're your yours yourself youre yup
  ))

  @doc """
  Resolve an utterance against the meeting's open candidates.

  Returns `{:thread, candidate, reason}` when the utterance continues
  that candidate, or `:new` when it starts one. `reason` is a map — it
  is written verbatim into the candidate's `threading_events` by stage
  4, and a bare atom would record THAT a rule fired without recording
  what it saw.

  ## Examples

      iex> alias Platform.Meetings.ThreadResolver
      iex> ThreadResolver.resolve(%{speaker: "alice", text: "make that mobile only", at: ~U[2026-08-28 10:00:08Z]}, [])
      :new
  """
  @spec resolve(utterance(), [MeetingCandidate.t()]) :: result()
  def resolve(utterance, open_candidates)

  def resolve(_utterance, []), do: :new

  def resolve(%{} = utterance, open_candidates) when is_list(open_candidates) do
    speaker = normalize_speaker(Map.get(utterance, :speaker))
    text = Map.get(utterance, :text)
    at = Map.get(utterance, :at)

    with true <- is_binary(speaker),
         true <- is_binary(text),
         true <- match?(%DateTime{}, at),
         [_ | _] = raw <- tokenize(text),
         [_ | _] = gated <- gate(open_candidates, speaker, at) do
      score_and_pick(raw, gated, at)
    else
      _ -> :new
    end
  end

  def resolve(_utterance, _open_candidates), do: :new

  @doc "The time window, in seconds, exposed so a test can state it rather than guess it."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc "The topic-overlap floor, exposed for the same reason."
  @spec overlap_floor() :: float()
  def overlap_floor, do: @overlap_floor

  @doc """
  How many tokens an `:anaphoric_fragment` must share with the
  candidate it attaches to. Exposed so a test can state it.
  """
  @spec anaphoric_shared_floor() :: pos_integer()
  def anaphoric_shared_floor, do: @anaphoric_shared_floor

  @doc """
  The tokens the anaphoric path reads: topic tokens plus the generic
  action verbs `topic_tokens/1` strips. Public so the guard and the
  negative cases can state the shared set by value rather than assert
  the rule against itself.
  """
  @spec lexical_tokens(String.t()) :: MapSet.t(String.t())
  def lexical_tokens(text) when is_binary(text), do: text |> tokenize() |> lexical_of()

  def lexical_tokens(_), do: MapSet.new()

  @doc """
  The sorted tokens two strings share over `lexical_tokens/1`. This is
  the anaphoric path's relatedness measure, and the thing it must have
  at least `anaphoric_shared_floor/0` of.
  """
  @spec shared_lexical(String.t(), String.t()) :: [String.t()]
  def shared_lexical(left, right) do
    left |> lexical_tokens() |> MapSet.intersection(lexical_tokens(right)) |> Enum.sort()
  end

  @doc """
  The topic tokens of a string: everything that survives stopword
  removal. Public because the recall guard and the floor measurement
  both need to show their working.
  """
  @spec topic_tokens(String.t()) :: MapSet.t(String.t())
  def topic_tokens(text) when is_binary(text) do
    text |> tokenize() |> topic_of()
  end

  def topic_tokens(_), do: MapSet.new()

  @doc """
  Overlap coefficient between two strings' topic tokens:
  `|A ∩ B| / min(|A|, |B|)`, and `0.0` when either side has no topic
  tokens at all. Public so the floor can be justified by measurement.
  """
  @spec relatedness(String.t(), String.t()) :: float()
  def relatedness(left, right) do
    a = topic_tokens(left)
    b = topic_tokens(right)
    overlap_coefficient(a, b)
  end

  # ── gates ─────────────────────────────────────────────────────────────────

  # Same speaker AND inside the window. Both are hard filters: nothing
  # downstream can rescue a candidate that fails either.
  defp gate(candidates, speaker, at) do
    Enum.filter(candidates, fn candidate ->
      same_speaker?(candidate, speaker) and in_window?(candidate, at)
    end)
  end

  # Both sides must be KNOWN and equal. `nil == nil` is explicitly not a
  # match — an unattributed utterance following an unattributed
  # candidate is two strangers, not one person continuing.
  defp same_speaker?(%{speaker: candidate_speaker}, speaker) do
    case normalize_speaker(candidate_speaker) do
      nil -> false
      known -> known == speaker
    end
  end

  defp same_speaker?(_, _), do: false

  defp in_window?(%{last_utterance_at: %DateTime{} = last}, %DateTime{} = at) do
    elapsed = DateTime.diff(at, last, :second)
    elapsed >= 0 and elapsed <= @window_seconds
  end

  # No clock on the candidate means no window can be evaluated. Not
  # threading is the safe answer.
  defp in_window?(_, _), do: false

  # ── scoring ───────────────────────────────────────────────────────────────

  defp score_and_pick(raw, gated, at) do
    tokens = topic_of(raw)

    scored =
      gated
      |> Enum.map(fn candidate ->
        {candidate, overlap_coefficient(tokens, candidate_tokens(candidate))}
      end)
      |> Enum.filter(fn {_candidate, score} -> score >= @overlap_floor end)

    case best(scored) do
      {:ok, candidate, score} ->
        {:thread, candidate, topic_reason(candidate, tokens, score, at, length(gated))}

      :ambiguous ->
        :new

      :none ->
        anaphoric(raw, gated, at)
    end
  end

  defp topic_reason(candidate, tokens, score, at, gated_count) do
    %{
      rule: :topic_overlap,
      score: Float.round(score, 4),
      shared: tokens |> MapSet.intersection(candidate_tokens(candidate)) |> Enum.sort(),
      elapsed_seconds: elapsed_seconds(candidate, at),
      open_candidates_in_window: gated_count
    }
  end

  # The unique maximum, or nothing. A tie at the top is refused rather
  # than broken by recency: recency is the exact heuristic that makes a
  # wrong attachment look reasonable.
  defp best([]), do: :none

  defp best(scored) do
    {_candidate, top} = Enum.max_by(scored, fn {_candidate, score} -> score end)

    case Enum.filter(scored, fn {_candidate, score} -> score == top end) do
      [{candidate, score}] -> {:ok, candidate, score}
      _ -> :ambiguous
    end
  end

  # A short fragment leaning on a deictic, and ONLY when there is
  # exactly one thing it could be leaning on. See the moduledoc: with
  # two candidates in the window a bare "that" names neither, so this
  # path switches itself off rather than guess.
  defp anaphoric(raw, [candidate], at) do
    deictic = Enum.find(raw, &MapSet.member?(@deictics, &1))

    shared =
      raw
      |> lexical_of()
      |> MapSet.intersection(candidate_lexical(candidate))
      |> Enum.sort()

    if length(raw) <= @fragment_max_tokens and deictic != nil and
         length(shared) >= @anaphoric_shared_floor do
      {:thread, candidate,
       %{
         rule: :anaphoric_fragment,
         deictic: deictic,
         shared: shared,
         token_count: length(raw),
         elapsed_seconds: elapsed_seconds(candidate, at),
         open_candidates_in_window: 1
       }}
    else
      :new
    end
  end

  defp anaphoric(_raw, _gated, _at), do: :new

  defp elapsed_seconds(%{last_utterance_at: %DateTime{} = last}, %DateTime{} = at),
    do: DateTime.diff(at, last, :second)

  defp elapsed_seconds(_, _), do: nil

  # ── tokens ────────────────────────────────────────────────────────────────

  defp overlap_coefficient(%MapSet{} = a, %MapSet{} = b) do
    smaller = min(MapSet.size(a), MapSet.size(b))

    if smaller == 0 do
      0.0
    else
      MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(smaller)
    end
  end

  defp topic_of(raw), do: raw |> Enum.reject(&MapSet.member?(@stopwords, &1)) |> MapSet.new()

  # Topic tokens PLUS the generic action verbs `@stopwords` strips.
  # Everything else stopworded stays stopworded — articles, pronouns,
  # modals, auxiliaries and, crucially, the deictics themselves, so a
  # shared `that` can never be the evidence that a `that` points here.
  defp lexical_of(raw) do
    raw
    |> Enum.filter(fn token ->
      not MapSet.member?(@stopwords, token) or MapSet.member?(@generic_verbs, token)
    end)
    |> MapSet.new()
  end

  defp candidate_tokens(%{evidence_quote: evidence}) when is_binary(evidence),
    do: topic_tokens(evidence)

  defp candidate_tokens(_), do: MapSet.new()

  defp candidate_lexical(%{evidence_quote: evidence}) when is_binary(evidence),
    do: lexical_tokens(evidence)

  defp candidate_lexical(_), do: MapSet.new()

  # Lowercase, fold curly apostrophes so `didn't` and `didn’t` tokenize
  # identically, then split on anything that is not a letter, digit or
  # apostrophe.
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[\x{2018}\x{2019}]/u, "'")
    |> String.replace(~r/[^\p{L}\p{N}']+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.trim(&1, "'"))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_speaker(nil), do: nil

  defp normalize_speaker(speaker) when is_binary(speaker) do
    case String.trim(speaker) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_speaker(_), do: nil
end
