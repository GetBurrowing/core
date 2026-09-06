defmodule PlatformWeb.Components.Meetings.CandidateDisplay do
  @moduledoc """
  What a meeting candidate SAYS OUT LOUD (task 01a03f4e-78b1).

  `Platform.Meetings.MeetingCandidate` stores two vocabularies — `state`
  (`heard → thinking → shaping → acting → closed`) and `closed_reason`
  (`retracted / duplicate / vetoed / done / dismissed`). Both are the
  Architect's remit and neither is in question here. This module is the
  *other* half: the explicit mapping from a stored atom to the words a
  participant reads.

  ## Why a mapping and not `to_string/1`

  Two reasons, and the second is the one that matters.

  1. **The stored names fail our own naming rule.** "Shaping" is
     anthropomorphic, not descriptive: a participant who sees a card
     marked *shaping* cannot tell what the system is doing or how long
     it will take. The mockup's word is **"taking shape"**, and that
     divergence is the proof the two vocabularies are genuinely
     different things rather than the same string with different
     casing.

  2. **`vetoed` versus `dismissed` is a sentence about a person's
     idea.** Printed raw, one of them tells a colleague in the meeting
     that their suggestion was *vetoed*. Distinguishing them in the data
     is correct. Saying it in that word is a choice somebody should make
     deliberately rather than inherit from a column name.

  So the raw vocabulary must not reach the DOM at all — not as text, and
  not as a class name or a `data-` attribute either, because a class is
  as readable as a label to anyone with an inspector open and a
  screen-reader user can be handed either. `slug/1` and
  `closed_reason_slug/1` therefore emit DISPLAY slugs
  (`"taking-shape"`, `"not-taken-up"`), never the column value. The
  regression that guards this is a `refute rendered =~ "shaping"` /
  `refute rendered =~ "vetoed"` pair, which only means anything because
  those two strings appear in NO other spelling of the display copy.

  ## Exhaustiveness is the point

  Every public mapping here is a total function over the enum it maps,
  written as one clause per member with no catch-all fallback to
  `to_string/1`. A fallback is what turns "somebody added a sixth
  closed_reason" from a compile-or-test failure into a card that quietly
  prints a column name at a client. The tests walk
  `MeetingCandidate.closed_reasons/0` and `states/0` so a new member
  fails loudly rather than leaking.
  """

  alias Platform.Meetings.MeetingCandidate

  @doc """
  How long ago the words behind this card were spoken.

  The mockup's `— Dalton, just now` / `— Mycroft, 2m`, and the target
  screen commits to it explicitly: *"Cards land as they're made, and say
  who made them and when."* Until this existed the byline said who and
  never when, so a card that arrived thirty seconds ago and one that had
  been sitting there for ten minutes read identically — the same
  can't-tell-fresh-from-stale problem the `Couldn't` state fixes on the
  agent dock.

  Reads `last_utterance_at`, not `inserted_at`: the card is about
  something a person SAID, and a threaded follow-up moves the utterance
  forward while the row keeps its original insert time. "2m ago" should
  mean "they said it two minutes ago", which is the only reading a
  participant will give it.

  ## Why it takes `now` instead of calling `DateTime.utc_now/0`

  `PlatformWeb.Components.ChatHelpers.relative_time/1` says the same
  words and reads its own clock. That is right for a chat line and wrong
  here: this card also draws a countdown ring computed from the rail's
  `now` assign, and a byline reading a *different* clock could say "just
  now" beside a ring that has already expired. One render, one clock.

  Same vocabulary as `relative_time/1` deliberately — two spellings of
  "2m ago" on one screen is its own small lie about whether they mean
  the same thing.

  `nil` for a candidate with no utterance timestamp, so the caller omits
  the element rather than printing an empty separator.
  """
  @spec said_ago(map(), DateTime.t()) :: String.t() | nil
  def said_ago(%{last_utterance_at: %DateTime{} = at}, %DateTime{} = now) do
    case DateTime.diff(now, at, :second) do
      diff when diff < 0 -> "just now"
      diff when diff < 60 -> "just now"
      diff when diff < 3600 -> "#{div(diff, 60)}m ago"
      diff when diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff -> "#{div(diff, 86_400)}d ago"
    end
  end

  def said_ago(_candidate, _now), do: nil

  @doc """
  What this card actually produced, or `nil` while it has produced
  nothing.

  The mockup's `✓ added to Tasks`. It is drawn ONLY from a stored id —
  `task_id` or `canvas_id`, both written by `Platform.Meetings.Candidates.graduate/2`
  — never from `state == :acting`, and that distinction is the whole
  value of the line. `graduate/2` can fail against an archived project
  and leave the row `:acting` and disarmed with no deliverable
  (`candidates.ex:1117`), which its own docs call "the truthful reading
  of what happened". A label keyed on the state would announce a task
  that was never created.

  So: present id, present claim. No id, no claim.

  `outcome_kind` is deliberately NOT consulted. It declares what the
  card was *aiming* at; the ids record what it *reached*, and this line
  is about the second.
  """
  @spec outcome_label(map()) :: String.t() | nil
  def outcome_label(%{task_id: task_id}) when is_binary(task_id), do: "Added to Tasks"
  def outcome_label(%{canvas_id: canvas_id}) when is_binary(canvas_id), do: "Added to Canvas"
  def outcome_label(_candidate), do: nil

  @doc """
  The stage tag drawn at the top of a card — the mockup's `1 · heard`.

  The ordinal is part of the copy rather than derived, because the
  mockup's organising claim ("colour is earned") is a claim about
  progression and the number is how a reader sees it without reading
  the word.
  """
  @spec stage_label(atom()) :: String.t()
  def stage_label(:heard), do: "1 · heard"
  def stage_label(:thinking), do: "2 · thinking"
  def stage_label(:shaping), do: "3 · taking shape"
  def stage_label(:acting), do: "4 · acting"
  def stage_label(:closed), do: "Closed"

  @doc """
  The target chip's text — who an intent was aimed at, in words.

  `Platform.Meetings.IntentClassifier` lands the SENTINEL STRING
  `"null"` (`@no_target_role`) in `target_role` for an unrouted intent,
  not a real `nil`. That representation is pinned by an invariant test
  — a real nil crashes `build_dedupe_key/3`, and changing it would fork
  every historical dedupe key — so the sentinel is not going anywhere
  and the READ path is where it has to be absorbed.

  This function is the ONLY place in `platform_web` that is allowed to
  know that. A grep-style containment test asserts no other rendering
  position touches `target_role`, because a magic string standing for
  absence reproduces its bug in the next renderer that has not heard of
  it.

  The unassigned affordance is a plain `"unassigned"` with NO `"@"`
  prefix — which is what the old dead `|| "unassigned"` third term
  always intended. The prefix lives in here rather than in the heex so
  a ROLE label (`"Triage officer"`) never reads as an at-mention of a
  person; only a real agent slug gets an `@`.

  ## Examples

      iex> alias PlatformWeb.Components.Meetings.CandidateDisplay
      iex> CandidateDisplay.target_label("octavius", "null")
      "@octavius"
      iex> CandidateDisplay.target_label(nil, "null")
      "unassigned"
      iex> CandidateDisplay.target_label(nil, "triage_officer")
      "Triage officer"

  """
  @spec target_label(String.t() | nil, String.t() | nil) :: String.t()
  def target_label(target_agent_slug, target_role) do
    case normalize(target_agent_slug) do
      nil -> role_label(normalize(target_role))
      slug -> "@" <> slug
    end
  end

  # The known role keys are enumerated so a rename fails a test rather
  # than silently changing the copy. The final clause is NOT the usual
  # `to_string/1` escape hatch — see `humanise/1`: `target_role` is
  # whatever binary the model emitted (`normalise_target_role/1` in
  # `IntentClassifier` accepts ANY string), so a total function over a
  # closed set would crash the whole rail on a novel model output. That
  # is a worse failure than the bug this fixes.
  defp role_label(nil), do: "unassigned"
  defp role_label("null"), do: "unassigned"
  defp role_label("designer"), do: "Designer"
  defp role_label("meeting_scribe"), do: "Meeting scribe"
  defp role_label("historian"), do: "Historian"
  defp role_label("triage_officer"), do: "Triage officer"
  defp role_label(other), do: humanise(other)

  @doc """
  What the classifier decided, in words a participant reads.

  Same discipline as `stage_label/1`: the stored enum token is a column
  value, not copy. `brief_worthy` printed raw is a schema detail on
  screen; one clause per known value with no catch-all is what makes a
  sixth intent a change to this list rather than a leak.

  `classified_intent` is NOT a closed enum — `IntentClassifier` stores
  whatever binary the model returned. So the final clause humanises an
  unrecognised value (`"brief_worthy"` -> `"Brief worthy"`) instead of
  crashing the rail. The raw token still never reaches the DOM, which
  is the property that matters.

  ## Examples

      iex> alias PlatformWeb.Components.Meetings.CandidateDisplay
      iex> CandidateDisplay.intent_label("off_topic")
      "Off topic"
      iex> CandidateDisplay.intent_label(nil)
      "—"

  """
  @spec intent_label(String.t() | nil) :: String.t()
  def intent_label(nil), do: "—"
  def intent_label("off_topic"), do: "Off topic"
  def intent_label("action_items"), do: "Action items"
  def intent_label("brief_worthy"), do: "Brief-worthy"
  def intent_label("visual_adjust"), do: "Visual adjustment"
  def intent_label("decision_recorded"), do: "Decision recorded"
  def intent_label(other) when is_binary(other), do: humanise(other)

  # A stored value nobody wrote copy for, made readable rather than
  # printed raw. `"brief_worthy"` is a schema detail on screen;
  # `"Brief worthy"` is at least a sentence. The known values above are
  # still enumerated, so a rename is caught by the mapping test.
  defp humanise(value) do
    case value |> String.replace("_", " ") |> String.trim() do
      "" -> "unassigned"
      words -> String.capitalize(words)
    end
  end

  @doc """
  The DISPLAY slug for a state — for `data-stage` and the stage class.

  Deliberately not `Atom.to_string/1`: see the moduledoc. `:shaping`
  answers `"taking-shape"`, and that is the whole reason this function
  exists rather than being inlined.
  """
  @spec slug(atom()) :: String.t()
  def slug(:heard), do: "heard"
  def slug(:thinking), do: "thinking"
  def slug(:shaping), do: "taking-shape"
  def slug(:acting), do: "acting"
  def slug(:closed), do: "closed"

  @doc """
  The user-facing sentence for a closed card's reason.

  These are the words the Closed section exists to retain. The mockup's
  own examples are all of the form *what was checked* — "Already on the
  backlog — 01a03f57" — never a bare verdict, because the section's
  value is that a reason is *retrievable and checkable*, not that a card
  carries a label.
  """
  @spec closed_reason_label(atom()) :: String.t()
  def closed_reason_label(:retracted), do: "Retracted"
  def closed_reason_label(:duplicate), do: "Already on the backlog"
  def closed_reason_label(:vetoed), do: "Not taken up"
  def closed_reason_label(:done), do: "Done"
  def closed_reason_label(:dismissed), do: "Stopped"

  @doc """
  The DISPLAY slug for a closed reason. `:vetoed` answers
  `"not-taken-up"` — the stored word never reaches the DOM.
  """
  @spec closed_reason_slug(atom() | nil) :: String.t() | nil
  # A row can sit in the board's closed set on the strength of `state`
  # alone. `nil` answers nil rather than a made-up slug — the card then
  # carries no `data-closed-reason` at all, which is the honest
  # rendering of "closed, reason unrecorded" and is distinguishable from
  # every real reason.
  def closed_reason_slug(nil), do: nil
  def closed_reason_slug(:retracted), do: "retracted"
  def closed_reason_slug(:duplicate), do: "already-tracked"
  def closed_reason_slug(:vetoed), do: "not-taken-up"
  def closed_reason_slug(:done), do: "done"
  def closed_reason_slug(:dismissed), do: "stopped"

  @doc """
  The full reason line: the label, plus `closed_note` when the close
  path wrote one.

  The note is where the checkable part lives (`Stopped by Harper
  Parker`, a retraction quote, a duplicate's task id), so it is joined
  with an em dash exactly as the mockup draws it rather than dropped.
  A nil or blank note degrades to the label alone — never to a dangling
  dash, which reads as a truncation bug.
  """
  @spec closed_reason_line(atom() | nil, String.t() | nil) :: String.t() | nil
  def closed_reason_line(nil, _note), do: nil

  def closed_reason_line(reason, note) when is_atom(reason) do
    label = closed_reason_label(reason)

    case normalize(note) do
      nil -> label
      note -> label <> " — " <> note
    end
  end

  @doc """
  The second half of a card's byline — the `drafting` in
  `Octavius · drafting`.

  `:acting` is answered from what the card actually PRODUCED, not from
  its state: a card is `:acting` from the moment the sweeper claims it,
  and saying "task created" before `task_id` is set would be the timer
  that lies in byline form. Returns nil for the two pre-colour stages,
  where the mockup deliberately draws no byline because no agent has
  been chosen and a byline would be a claim the card cannot back up.
  """
  @spec byline_state(map()) :: String.t() | nil
  def byline_state(%{state: :shaping}), do: "drafting"

  def byline_state(%{state: :acting} = candidate) do
    cond do
      is_binary(Map.get(candidate, :task_id)) -> "task created"
      is_binary(Map.get(candidate, :canvas_id)) -> "canvas created"
      true -> "getting started"
    end
  end

  def byline_state(_candidate), do: nil

  @doc """
  The agent's display name for a byline, or nil when no agent has been
  assigned.

  Reads `assigned_agent_slug`, which `mirror_enqueue/3` denormalizes
  onto the row — so the byline survives the agent being renamed or the
  meeting ending, which a join would not.
  """
  @spec agent_name(map()) :: String.t() | nil
  def agent_name(candidate) do
    candidate |> Map.get(:assigned_agent_slug) |> normalize()
  end

  @doc """
  WHO SAID IT — the transcript's attribution for the utterance behind
  this card, or `nil` when the transcript did not attribute it.

  This is the byline's subject, and it is deliberately NOT
  `agent_name/1`. The assigned agent is who the system pointed the work
  AT; the speaker is who said the words in `evidence_quote`. Printing
  the assignee where the author belongs is the defect this exists to
  make impossible — it credits a sentence to an agent that was not in
  the room when it was spoken.

  `nil` means UNATTRIBUTED and the caller must render nothing at all.
  There is no placeholder and no fallback to the assignee: a guessed
  name on a verbatim quote is a claim the data cannot back. The
  classifier answers `""` for an unknown speaker and the mirror
  normalises `""` to nil on the way in (`meeting_candidate.ex:45`), so a
  blank is normalised here too rather than rendering an empty byline.
  """
  @spec speaker_name(map()) :: String.t() | nil
  def speaker_name(candidate) do
    candidate |> Map.get(:speaker) |> normalize()
  end

  @doc """
  One activity-log line for one real `meeting_candidate_events` row.

  There is exactly one clause per `MeetingCandidateEvent.kinds/0` member
  and no catch-all. The ticket is explicit that a hardcoded log is a
  progress bar that lies, so every line a card shows must be here
  because a write returned `{:ok, _}` — the renderer never invents a
  line and never derives one from a state.
  """
  @spec event_line(atom(), map()) :: String.t()
  def event_line(:heard, _detail), do: "Heard it in the transcript"
  def event_line(:threaded, _detail), do: "Attached what was said next"
  def event_line(:classified, _detail), do: "Worked out what it is"
  def event_line(:advanced, detail), do: advanced_line(detail)
  def event_line(:disposition_recorded, _detail), do: "Recorded the outcome"
  def event_line(:closed, detail), do: closed_line(detail)
  def event_line(:countdown_stopped, _detail), do: "Stopped by a participant"
  def event_line(:countdown_fired, _detail), do: "Went ahead on its own"
  def event_line(:countdown_undone, _detail), do: "Stop taken back — waiting on a decision"

  # `detail["to"]` is the state the write moved TO. It comes back from
  # jsonb as a string, so it is mapped through the same display table as
  # everything else rather than printed — otherwise the log line is the
  # one place the raw vocabulary would still leak.
  defp advanced_line(detail) when is_map(detail) do
    case display_state(Map.get(detail, "to")) do
      nil -> "Moved on"
      label -> "Moved on to " <> label
    end
  end

  defp advanced_line(_detail), do: "Moved on"

  defp closed_line(detail) when is_map(detail) do
    case display_closed_reason(Map.get(detail, "reason")) do
      nil -> "Closed"
      label -> "Closed — " <> label
    end
  end

  defp closed_line(_detail), do: "Closed"

  # String -> atom WITHOUT `String.to_atom/1`. The value arrives from
  # jsonb, which is to say from a column, and the enum is the only set
  # of answers that may be honoured.
  defp display_state(value) when is_binary(value) do
    Enum.find_value(MeetingCandidate.states(), fn state ->
      if Atom.to_string(state) == value, do: stage_word(state)
    end)
  end

  defp display_state(_value), do: nil

  defp display_closed_reason(value) when is_binary(value) do
    Enum.find_value(MeetingCandidate.closed_reasons(), fn reason ->
      if Atom.to_string(reason) == value, do: closed_reason_label(reason)
    end)
  end

  defp display_closed_reason(_value), do: nil

  # The stage word with the ordinal stripped — a log line reads
  # "Moved on to taking shape", never "Moved on to 3 · taking shape".
  defp stage_word(state) do
    state |> stage_label() |> String.split(" · ") |> List.last()
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
