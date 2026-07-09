defmodule Platform.Repo.Migrations.UpdateIntentClassifyPromptWithContext do
  use Ecto.Migration

  @moduledoc """
  Rewrite the `meetings.intent_classify.v1` prompt to accept the
  prior-N transcript context window (task 019f474d stage 2).

  Preserves the load-bearing pieces of the stage-1 seed
  (`20260707120000_seed_prompt_template_intent_classify.exs`):

    * closed intent enum (7 values)
    * closed target_role enum (5 values, including `null`)
    * JSON-only output contract with `intent`, `target_role`,
      `confidence`, and `dedupe_key`
    * dedupe_key normalisation rules

  What changes: the "# Input" framing block is replaced with a
  prior-conversation-context block followed by the current utterance,
  and the declared variables now include `context_lines`,
  `context_present`, `speaker`, and `room_id` on top of the existing
  `meeting_transcript_chunk`. The prompt tells the model explicitly
  NOT to classify the prior context — it's disambiguation only.

  Idempotent shape mirrors `20260505200600_refresh_org_memory_prompt_templates.exs`:
  the row must exist (stage-1 migration created it) and gets
  overwritten in place. If the row is missing (e.g. running against a
  DB where stage 1 hasn't run) the migration is a no-op — the stage-1
  seed will insert the fresh content next time.

  `down/0` intentionally does not attempt to restore the stage-1
  content. Rolling back is a stage-1 concern; this migration only
  refreshes the row.
  """

  @slug "meetings.intent_classify.v1"

  @new_content """
  You are the Meeting Producer's `meetings.intent_classify` classifier. One transcript chunk in, one JSON object out.

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
