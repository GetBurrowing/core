defmodule Platform.Repo.Migrations.UpdateIntentClassifyPromptWithCorrections do
  use Ecto.Migration

  @moduledoc """
  Add the `{{correction_exemplars}}` few-shot block to the
  `meetings.intent_classify.v1` prompt (task 019f70b8 stage 6, AC16).

  Third revision of this template. The lineage:

    * `20260707120000_seed_prompt_template_intent_classify.exs` created
      the row (task 019f2451 stage 1).
    * `20260709120000_update_intent_classify_prompt_with_context.exs`
      added the `{{context_lines}}` prior-conversation window
      (task 019f474d stage 2).
    * this one adds the org's accumulated producer corrections above
      that window, so the classifier sees what it previously got wrong
      in this org before it sees what was just said.

  ## Update-only, unlike stage 5's migration

  Stage 5's `dispatch.intent_attention` migration did BOTH halves
  (insert-if-missing AND force-update) because its slug was NEW, and
  prod no longer re-runs `PromptTemplates.seed_defaults/0`, so nothing
  would ever have inserted it. This slug is not new: the 20260707 seed
  created it on every environment that has migrated at all, and
  migrations run in timestamp order, so by the time this one executes
  the row exists. Re-implementing the insert here would duplicate the
  seed's content in a third place with no environment that needs it.

  The `nil -> :skip` branch is therefore a genuine no-op guard rather
  than a rollout path — it exists so a DB where an operator deleted the
  row does not fail the whole migration run.

  ## Why the body is duplicated rather than patched

  The preceding migration's content is copied and extended rather than
  string-substituted. A `String.replace/3` against whatever is currently
  in the row would silently produce a different prompt on any
  environment where somebody had iterated the wording live via the
  `prompt_template_update` MCP tool — which the stage-1 seed explicitly
  invites. Overwriting with a known-good body makes every environment
  byte-identical, which is the only property the runtime depends on.

  `down/0` is `:ok`: rolling back to a body with no
  `{{correction_exemplars}}` marker while the classifier still renders
  the variable would leave a dangling assign, which is harmless, and
  restoring the previous body is the previous migration's business.
  """

  @slug "meetings.intent_classify.v1"

  @new_content """
  You are the Meeting Producer's `meetings.intent_classify` classifier. One transcript chunk in, one JSON object out.

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
    {"intent": "<intent>", "target_role": "<role or null>", "confidence": <0.0-1.0>, "dedupe_key": "<intent>:<normalized_subject>"}

  No fields outside these four. No comments. No trailing text.

  # Closed intent enum
  Pick exactly one of:
    - `visual_adjust`      — canvas/UI style change (color, size, spacing, typography)
    - `interaction_design` — behavior/flow change (what the user can do, how it responds)
    - `action_items`       — someone commits to do a concrete thing
    - `brief_worthy`       — worth capturing in the meeting brief (context, background, framing)
    - `decision_recorded`  — a decision was made and the meeting owns it
    - `open_question`      — an unresolved question surfaced that needs an answer
    - `off_topic`          — small talk, side chatter, or not routable

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
    - "let's make that button teal"          -> `visual_adjust:button_color`
    - "that button, teal please"             -> `visual_adjust:button_color`  (same underlying intent)
    - "John, send the contract to the client by Friday" -> `action_items:john:send_contract`
    - "we decided to ship Tuesday"           -> `decision_recorded:ship_date`
    - "did you catch the game last night?"   -> `off_topic:small_talk`

  # Fallback rules
  - If intent is unclear OR the text is small talk -> `off_topic`, `target_role: null`, `confidence < 0.5`.
  - If intent is clear but no role maps -> keep the intent, `target_role: null`, `confidence >= 0.7`.
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
