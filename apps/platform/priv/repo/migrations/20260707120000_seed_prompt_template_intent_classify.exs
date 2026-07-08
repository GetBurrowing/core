defmodule Platform.Repo.Migrations.SeedPromptTemplateIntentClassify do
  use Ecto.Migration

  @moduledoc """
  Seed the Meeting Producer bundle `meetings.intent_classify.v1` prompt
  template (task 019f2451 stage 1).

  Backs the placeholder `Platform.Responsibilities.Handlers.IntentClassify`
  registered in the meeting_producer bundle — the handler declares
  `default_prompt_template: "meetings.intent_classify.v1"` but no
  migration seeded the row on prod until this one landed.

  The content is a tight system prompt for a small, fast, local
  classifier: one transcript chunk in, one JSON object out, closed
  intent + role enums, and a stable dedupe_key normalisation so
  paraphrases of the same intent collapse in the downstream dispatcher.
  Rowan and the Producer team iterate wording live via the
  `prompt_template_update` MCP tool after the seed lands.

  Idempotent — if the slug already exists we leave the row alone (this
  matches the `PromptTemplates.seed_defaults/0` behaviour). `down/0`
  deletes only the single slug this migration introduced.
  """

  @templates [
    %{
      slug: "meetings.intent_classify.v1",
      name: "Meetings: Intent Classifier",
      description:
        "Meeting Producer classifies a single transcript chunk into a routable intent + target role + dedupe key.",
      variables: ["meeting_transcript_chunk"],
      content: """
      You are the Meeting Producer's `meetings.intent_classify` classifier. One transcript chunk in, one JSON object out.

      # Input
      A single transcript chunk supplied via the `{{meeting_transcript_chunk}}` variable, shaped as:
        {"speaker": "<string>", "timestamp_ms": <int>, "text": "<string>"}

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
    }
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn template ->
      case PromptTemplates.get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  def down do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn %{slug: slug} ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end
    end)

    :ok
  end
end
