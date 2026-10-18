defmodule Platform.Repo.Migrations.ForceUpdateIntentClassifyPromptOffTopicDefault do
  use Ecto.Migration

  @moduledoc """
  Fourth revision of `meetings.intent_classify.v1` (task 01a03f57 stage 1):
  make `off_topic` the STATED DEFAULT and require an `evidence_quote`.

  ## Why a migration and not an edit to `do_default_templates/0`

  Editing `Platform.Orchestration.PromptTemplates.do_default_templates/0`
  is a runtime no-op: `render_template/2` prefers the seeded
  `prompt_templates` row and `seed_defaults/0` is INSERT-only, so an
  existing row is never refreshed from source. A prompt change reaches
  the classifier ONLY through a force-update migration like this one.
  Verify against `get_template_by_slug/1`, never against source.

  ## Lineage

    * `20260707120000_seed_prompt_template_intent_classify.exs` — created the row.
    * `20260709120000_update_intent_classify_prompt_with_context.exs` — added `{{context_lines}}`.
    * `20260726000100_update_intent_classify_prompt_with_corrections.exs` — added `{{correction_exemplars}}`.
    * this one — off_topic-as-default + `evidence_quote` + the
      "is an AGENT being asked to do something?" re-framing.

  ## What the measurement said

  The classifier almost never answers `off_topic`: the escape hatch was
  present in the enum but nothing in the body pushed the model toward
  it, so ordinary meeting speech was force-fitted into one of the six
  routable intents. 87 of 102 recorded producer corrections are
  `wrong_target`, not `wrong_intent` — i.e. the model detects "somebody
  is asking for something" and then has nowhere to say "yes, but not of
  an agent". Detection and addressing are therefore ONE question, and
  the body now asks it that way. Model size is NOT the lever: measured,
  the production ~2B matched a far larger model.

  ## Why the body is a literal, not a `String.replace/3`

  Operators iterate the wording live via the `prompt_template_update`
  MCP tool. Substituting against whatever is currently in the row would
  produce a divergent body per environment. Overwriting with a
  known-good literal makes every environment byte-identical, which is
  the only property the runtime depends on.

  `down/0` is `:ok` — restoring the previous body is the previous
  migration's business.
  """

  @slug "meetings.intent_classify.v1"

  @new_content """
  You are the Meeting Producer's `meetings.intent_classify` classifier. One transcript chunk in, one JSON object out.

  # THE DEFAULT ANSWER IS `off_topic`

  MOST MEETING SPEECH IS `off_topic`. That is not a failure to find something — it is the expected and correct outcome for the large majority of utterances you will see. You are not searching for an intent; you are checking whether a rare, specific thing happened, and reporting that it did not when it did not. Answering `off_topic` for utterance after utterance is you working correctly. Only leave the default when you can quote the words that force you to.

  # The one question you are answering: is an AGENT being asked to do something?

  Do NOT ask "is this actionable?". Almost everything in a meeting is actionable by somebody. Meetings are full of genuine requests, commitments, and instructions aimed at PEOPLE — those are `off_topic` for this classifier, because no agent is being addressed. Detection and addressing are ONE question, not two: if you cannot name the agent role being asked, there is no intent to report.

  Negative exemplars — all of these are real requests, and all of them are `off_topic`:
    - "Nah, I'm gonna get Sam in here."                                 -> `off_topic` (a person is being pulled in)
    - "Try, can you try that link just to see what happened?"            -> `off_topic` (a human is asked to click something)
    - "But I would just say, like, send it to us."                       -> `off_topic` (a human is asked to send something)
    - "Promote to prod. Yeah, I know, me too. Okay, so let's go."        -> `off_topic` (humans coordinating their own work)

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

  If you cannot copy a verbatim substring of the current utterance that contains an agent being asked to do something, the answer is `off_topic` with `evidence_quote: ""`. No fields outside these five. No comments. No trailing text.

  # Closed intent enum
  Pick exactly one of:
    - `off_topic`          — THE DEFAULT. Small talk, side chatter, human-to-human requests, or anything with no agent being asked to act.
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
  - When in doubt, `off_topic`. Doubt is the normal state; it is not a reason to guess a routable intent.
  - If intent is unclear OR the text is small talk OR the request is aimed at a person -> `off_topic`, `target_role: null`, `evidence_quote: ""`, `confidence < 0.5`.
  - If intent is clear but no role maps -> keep the intent, `target_role: null`, `confidence >= 0.7`, and still supply the verbatim `evidence_quote`.
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
