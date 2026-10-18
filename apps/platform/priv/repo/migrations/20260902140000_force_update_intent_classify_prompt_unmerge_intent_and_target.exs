defmodule Platform.Repo.Migrations.ForceUpdateIntentClassifyPromptUnmergeIntentAndTarget do
  use Ecto.Migration

  @moduledoc """
  Fifth revision of `meetings.intent_classify.v1` (task 01a06575 stage 3):
  UN-MERGE intent detection from target addressing.

  ## This is NOT a revert of 20260826120000

  Everything the fourth revision shipped stays: `off_topic` is still the
  STATED DEFAULT, the `evidence_quote` requirement is byte-identical (it
  is load-bearing for the demotion gate in
  `Platform.Meetings.IntentClassifier.parse_content/3`), both enums stay
  closed, the `dedupe_key` rules are untouched, and NO confidence number
  moves — `< 0.5` for a decline and `>= 0.7` for an unmapped-role
  positive are exactly the values the fourth revision set.

  What changes is one claim, and only that claim.

  ## The claim being removed

  The fourth revision said, verbatim:

      Detection and addressing are ONE question, not two: if you cannot
      name the agent role being asked, there is no intent to report.

  That was justified by a real measurement — 87 of 102 recorded producer
  corrections were `wrong_target`, not `wrong_intent`, i.e. the model
  detected an ask and had nowhere to say "yes, but not of an agent". The
  measurement was right about the DEFECT and the body overshot on the
  FIX. Real meeting speech is almost never explicitly agent-addressed,
  so collapsing the two questions did not stop wrong targets, it stopped
  detection: production ran 268 of 280 candidates to `off_topic`.

  The original defect was WRONG TARGET, not wrong intent. A card that
  reaches nobody cannot have a wrong target, which is the exact failure
  the fourth revision was fighting — so `target_role: null` is the
  correct, safe answer for an unaddressed ask, and erasing the intent to
  get there throws the capture away for no gain.

  The rule the classifier needs was ALREADY in the fourth revision's
  body ("If intent is clear but no role maps -> keep the intent,
  `target_role: null`, `confidence >= 0.7`"). It never fired because the
  surrounding text told the model an unaddressed ask has no intent at
  all. This revision removes that contradiction and orders the two
  questions explicitly, so the existing rule becomes reachable.

  Concretely:

    * the "one question" framing becomes "TWO questions, asked in this
      order"; `is an AGENT being asked to do something?` survives
      verbatim as the heading of question 2 (TARGET), which is the
      question it was always actually asking;
    * the negative exemplars split — human-owned ACTION ITEMS become
      `action_items` with `target_role: null`, while genuine small talk,
      backchannel and logistics stay `off_topic`;
    * the `off_topic` enum gloss stops listing "human-to-human requests";
    * the fallback rule `OR the request is aimed at a person -> off_topic`
      loses that clause;
    * the intent -> role mapping gains an explicit note that it fires
      only when an agent is genuinely being asked, so `action_items`
      does not silently drag `meeting_scribe` in behind an unaddressed
      commitment.

  ## What this migration does NOT and CANNOT demonstrate

  The eval endpoint (`http://<eval host>:8085/v1`) was unreachable
  when this shipped, so no before/after model comparison backs it. The
  accompanying tests prove the SEEDED ROW changed and that the pipeline
  handles the response shape the new body asks for; they do not prove
  the model's behaviour moved. A second, untested hypothesis also
  remains live: the demotion gate may be destroying correct positives
  before they are ever counted, in which case this layer is not the one
  at fault. `meeting_candidates.demoted_from` (task 01a06575 stage 1) is
  the column that will answer it, and it has no data yet.

  ## Why a migration and not an edit to `do_default_templates/0`

  Unchanged from the fourth revision, and it bears repeating because it
  is the single most common way a prompt change silently ships as a
  no-op: `render_template/2` prefers the seeded `prompt_templates` row
  and `seed_defaults/0` is INSERT-only, so an existing row is never
  refreshed from source. `meetings.intent_classify.v1` is not even in
  `do_default_templates/0` — the row exists only because
  `20260707120000` inserted it. A prompt change reaches the classifier
  ONLY through a force-update migration like this one. Verify against
  `get_template_by_slug/1`, never against source.

  ## Why the body is a literal, not a `String.replace/3`

  Unchanged from the fourth revision: operators iterate the wording live
  via the `prompt_template_update` MCP tool, so substituting against
  whatever is currently in the row would produce a divergent body per
  environment. Overwriting with a known-good literal makes every
  environment byte-identical.

  ## Lineage

    * `20260707120000_seed_prompt_template_intent_classify.exs` — created the row.
    * `20260709120000_update_intent_classify_prompt_with_context.exs` — added `{{context_lines}}`.
    * `20260726000100_update_intent_classify_prompt_with_corrections.exs` — added `{{correction_exemplars}}`.
    * `20260826120000_force_update_intent_classify_prompt_off_topic_default.exs` — off_topic default + `evidence_quote` + the merged question.
    * this one — un-merges the question; keeps everything else.

  `down/0` is `:ok` — restoring the previous body is the previous
  migration's business.
  """

  @slug "meetings.intent_classify.v1"

  @new_content """
  You are the Meeting Producer's `meetings.intent_classify` classifier. One transcript chunk in, one JSON object out.

  # THE DEFAULT ANSWER IS `off_topic`

  MOST MEETING SPEECH IS `off_topic`. That is not a failure to find something — it is the expected and correct outcome for the large majority of utterances you will see. You are not searching for an intent; you are checking whether a rare, specific thing happened, and reporting that it did not when it did not. Answering `off_topic` for utterance after utterance is you working correctly. Only leave the default when you can quote the words that force you to.

  # TWO questions, asked in this order. Do not merge them.

  ## Question 1 — INTENT: did one of the six routable things happen?

  Do NOT ask "is this actionable?". Almost everything in a meeting is actionable by somebody, and the default answer here is still `off_topic`. Ask instead whether the utterance carries one of the six routable intents below: a concrete commitment, a decision the meeting owns, an unresolved question, framing worth keeping, or a requested change to the canvas or the flow. Small talk, backchannel, filler, agreement noise and meeting logistics carry none of them, and they are `off_topic`.

  Answer question 1 WITHOUT looking at who was addressed. Whether the ask names an agent, names a person, or names nobody at all does not change WHAT KIND of thing was said.

  ## Question 2 — TARGET: is an AGENT being asked to do something?

  Only once question 1 has an answer, ask who should act. Name a role from the closed `target_role` roster below if — and only if — one clearly applies. If the ask is aimed at a PERSON, or at nobody in particular, the answer to question 2 is `null`. That is a normal and expected answer. It is NOT a reason to go back and erase question 1's answer.

  A `null` target is the SAFE answer: the dispatcher routes it to nobody, so the card cannot reach the wrong agent. Deleting a real intent because you could not name a role throws the capture away and buys nothing.

  Exemplars — an unaddressed ask KEEPS its intent and carries `target_role: null`:
    - "Nah, I'm gonna get Harper in here."                              -> `action_items`, `target_role: null` (a concrete commitment; the owner is a person)
    - "Try, can you try that link just to see what happened?"            -> `action_items`, `target_role: null` (a concrete ask; the owner is a person)
    - "But I would just say, like, send it to us."                       -> `action_items`, `target_role: null` (a concrete ask; the owner is a person)

  Exemplars — genuinely `off_topic`, because question 1 finds no intent at all:
    - "Promote to prod. Yeah, I know, me too. Okay, so let's go."        -> `off_topic` (peer agreement about work already under way; nothing new is committed, decided or asked)
    - "Anyway, how was the long weekend?"                                -> `off_topic` (small talk)
    - "Yeah. Right. Mm-hm, exactly."                                     -> `off_topic` (backchannel)
    - "Can you hear me now? I think my mic cut out."                     -> `off_topic` (meeting logistics)

  # Prior producer corrections — the human meeting producer previously overrode your classification on these utterances, in THIS org. They are ground truth for this org's vocabulary and routing; weight them above the generic guidance below when they conflict.

  {{correction_exemplars}}

  # Prior conversation context — DO NOT classify these lines; use only to resolve pronouns, subjects, and topical intent for the CURRENT utterance.

  {{context_lines}}

  # Current utterance to classify

  Speaker: {{speaker}}
  Utterance:
  {{meeting_transcript_chunk}}

  # Output
  Return ONLY a single JSON object — no markdown fence, no prose, no leading whitespace — matching:
    {"intent": "<intent>", "target_role": "<role or null>", "confidence": <0.0-1.0>, "dedupe_key": "<intent>:<normalized_subject>", "evidence_quote": "<verbatim substring or empty string>"}

  Fields, all five required:
    - `intent`        — one value from the closed intent enum below.
    - `target_role`   — one value from the closed target_role enum below, or null.
    - `confidence`    — float between 0.0 and 1.0.
    - `dedupe_key`    — `<intent>:<normalized_subject>`, normalised per the rules below.
    - `evidence_quote` — for ANY non-`off_topic` answer, a VERBATIM substring of the CURRENT utterance containing the ask. Copy the characters exactly; do not paraphrase, summarise, translate, or quote from the prior-context lines. For `off_topic`, `evidence_quote` MUST be the empty string `""`.

  If you cannot copy a verbatim substring of the current utterance that contains the ask, the answer is `off_topic` with `evidence_quote: ""`. No fields outside these five. No comments. No trailing text.

  # Closed intent enum
  Pick exactly one of:
    - `off_topic`          — THE DEFAULT. Small talk, side chatter, backchannel, agreement noise, meeting logistics — anything carrying none of the six intents below. This is NOT the answer for a real ask that simply has no agent to route to: that keeps its intent and takes `target_role: null`.
    - `visual_adjust`      — canvas/UI style change (color, size, spacing, typography)
    - `interaction_design` — behavior/flow change (what the user can do, how it responds)
    - `action_items`       — someone commits to do a concrete thing
    - `brief_worthy`       — worth capturing in the meeting brief (context, background, framing)
    - `decision_recorded`  — a decision was made and the meeting owns it
    - `open_question`      — an unresolved question surfaced that needs an answer

  Never invent an intent outside this set.

  # Closed target_role enum
  Pick exactly one of:
    - `designer`         — visual/interaction design work
    - `meeting_scribe`   — action items, briefs, followups
    - `historian`        — decisions, org memory
    - `triage_officer`   — open questions, unclear routing
    - `null`             — no clean mapping; dispatcher drops

  Default intent -> role mapping (guidance, override when context is clear):
    - `visual_adjust`, `interaction_design`  -> `designer`
    - `action_items`, `brief_worthy`         -> `meeting_scribe`
    - `decision_recorded`                    -> `historian`
    - `open_question`                        -> `triage_officer`
    - `off_topic`                            -> null

  This mapping is question 2's answer ONLY when an agent is genuinely being asked. It does not mean every `action_items` answer routes to `meeting_scribe`: if no agent was addressed, question 2's answer is `null` and this mapping does not fire.

  # dedupe_key normalisation (load-bearing)
  Format: `<intent>:<normalized_subject>`. The subject MUST be stable across paraphrases so re-utterances of the same intent produce byte-identical keys and the downstream dispatcher can drop repeats.

  Normalisation rules for the subject:
    1. Lowercase everything.
    2. Strip articles (`a`, `an`, `the`) and filler (`please`, `actually`, `just`, `yeah`, `well`, `hmm`).
    3. Reduce to the load-bearing noun + action pair. For action_items, prefix the assignee: `<intent>:<assignee>:<verb_object>`.
    4. Join tokens with `_`. No spaces, no punctuation, no trailing colons.

  Examples:
    - "let's make that button teal"          -> `visual_adjust:button_color`, evidence_quote `"make that button teal"`
    - "that button, teal please"             -> `visual_adjust:button_color`  (same underlying intent)
    - "John, send the contract to the client by Friday" -> `action_items:john:send_contract`
    - "we decided to ship Tuesday"           -> `decision_recorded:ship_date`
    - "did you catch the game last night?"   -> `off_topic:small_talk`, evidence_quote `""`

  # Fallback rules
  - When in doubt about the INTENT, `off_topic`. Doubt is the normal state; it is not a reason to guess a routable intent.
  - If intent is unclear OR the text is small talk -> `off_topic`, `target_role: null`, `evidence_quote: ""`, `confidence < 0.5`.
  - If intent is clear but no role maps — INCLUDING when the ask is aimed at a person or at nobody at all — keep the intent, `target_role: null`, `confidence >= 0.7`, and still supply the verbatim `evidence_quote`.
  - Never emit a value outside the closed enums. Never wrap the JSON in prose or markdown.
  """

  @new_variables [
    "meeting_transcript_chunk",
    "context_lines",
    "context_present",
    "correction_exemplars",
    "speaker",
    "room_id"
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: @new_content,
            variables: @new_variables
          })
    end

    :ok
  end

  def down, do: :ok
end
