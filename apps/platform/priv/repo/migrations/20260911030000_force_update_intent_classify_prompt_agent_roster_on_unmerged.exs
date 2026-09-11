defmodule Platform.Repo.Migrations.ForceUpdateIntentClassifyPromptAgentRosterOnUnmerged do
  use Ecto.Migration

  require Logger

  @moduledoc """
  Sixth revision of `meetings.intent_classify.v1` (task 01a08f9f; recovers the
  prompt half of task 01a05997): put the agent roster back in front of
  question 2, ON TOP OF the 09-02 un-merged framing.

  ## Why this file exists at all

  Task 01a05997 shipped a roster-aware body as
  `20260831120000_force_update_intent_classify_prompt_agent_roster.exs` on a
  branch that was never merged (rescued as tag
  `rescue/01a05997-agent-roster-d3baf101`). That file MUST NOT be replayed.
  It writes the 08-31 body, which is built on the "detection and addressing
  are ONE question" framing that
  `20260902140000_force_update_intent_classify_prompt_unmerge_intent_and_target.exs`
  (task 01a06575) deliberately reversed. A rebase does not renumber
  migrations, so the 08-31 file would run as a pending LOWER version and
  clobber the 09-02 revision on every already-migrated deployment — silently,
  because a force-update compares nothing.

  This migration instead takes the 09-02 body VERBATIM as its base and applies
  the roster change to it, so the un-merge survives and the roster arrives.

  ## The three edits, and nothing else

  Diff against the 09-02 heredoc is two additive hunks, zero deletions:

    1. a `# Agents available in this org` section carrying `{{agent_roster}}`,
       inserted ABOVE the `## Question 2 — TARGET` heading so the model has
       the referent before the question is posed;
    2. one paragraph inside question 2 restating the addressing rule against
       that roster: a name or slug ON the roster is an agent and `target_role`
       is that agent's role key; a name NOT on the roster is a person, so
       question 2 answers `null` and question 1's intent stands;
    3. `"agent_roster"` appended to `@new_variables`.

  Deliberately unchanged, and each is load-bearing: the `target_role` enum
  membership and the exact spelling of the null sentinel (``  - `null`
  — no clean mapping; dispatcher drops``; `@no_target_role` is the STRING
  `"null"` in `Platform.Meetings.IntentClassifier`, and
  `CandidateDisplay.role_label("null")` renders "unassigned"), `off_topic` as
  the stated default, the `evidence_quote` requirement (the demotion gate in
  `IntentClassifier.parse_content/3` depends on it), every confidence
  threshold, the `dedupe_key` rules, and every existing render marker
  (`{{correction_exemplars}}`, `{{context_lines}}`, `{{speaker}}`,
  `{{meeting_transcript_chunk}}`).

  ## Three-way diff, read 2026-09-11 before authoring

  A force-update migration overwrites blind — no diff, no error, no warning —
  so the live rows were read on BOTH installs first. They do drift on other
  slugs (`heartbeat`, `historian.scheduled`, the three `design.*.v1` rows),
  so neither was assumed to stand for the other.

  | | fabrikam (`core-postgres` / `core_platform`) | milv (`milv-postgres` / `milv_platform`) |
  |---|---|---|
  | `updated_at` | 2026-09-03 08:23:49.764041Z | 2026-09-03 20:16:11.043652Z |
  | `updated_by` | `86149c7d-1e45-42aa-a250-1e190e169341` (Rowan) | NULL |
  | `inserted_at` | 2026-07-08 14:39:03Z | 2026-09-03 20:16:10Z |
  | bytes | 8311 | 8311 |
  | sha256 | `66b75c4467048314cdbded4ee3d3770d9e6bc455b09f37eae38a5ed929796b80` | same |
  | `variables` | `meeting_transcript_chunk, context_lines, context_present, correction_exemplars, speaker, room_id` | same |

  Both live rows are **byte-identical to the 09-02 heredoc** — not merely
  equal under `diff -w -B`, but the same sha256 this migration's base was
  extracted from. Rowan's uuid on the fabrikam row is a UI re-save, not a hand
  edit: `updated_by` names the last SAVER, never the author of the content.
  Nothing in either row is absent from the 09-02 heredoc, so nothing is
  destroyed by overwriting, and the stop condition (an install carrying
  content the heredoc does not) did not fire.

  What this migration writes: 8964 bytes, sha256
  `5afe1aa91e2ffd9ec566af27815ae1bf481d59ca99bb525f78c3701ba580a6f3`.

  ## Known contradiction left in place, on purpose

  `Platform.Meetings.IntentClassifier`'s inline `@fallback_intent_prompt`
  already carries a roster section, and the wording above follows it — with
  ONE exception. That fallback's roster paragraph ends:

      If you cannot name the agent role being asked, there is no intent to
      report.

  That sentence is a leftover of the 08-31 merged framing and directly
  contradicts question 2's `target_role: null` rule six lines above it in the
  same prompt. It is NOT copied here. The fallback needs the sentence
  deleted; a follow-up owns that, because the fallback is only reached when
  the row is ABSENT and fixing it is not this migration's business.

  A second instance of the same leftover lives in
  `IntentClassifier.format_agent_roster([])`, whose empty-roster text says
  "no agent can be addressed, so every utterance is off_topic". Under the
  09-02 framing an unaddressed ask keeps its intent and takes
  `target_role: null`, so that string is wrong too, and it is injected into
  the rendered body this migration writes. The same follow-up should take it.

  ## Lineage

    * `20260707120000_seed_prompt_template_intent_classify.exs` — created the row (INSERT-only; this slug has NO `do_default_templates/0` entry, so on a fresh install the LAST force-update wins and this file's version must sort after `20260902140000`).
    * `20260709120000_update_intent_classify_prompt_with_context.exs`
    * `20260726000100_update_intent_classify_prompt_with_corrections.exs`
    * `20260826120000_force_update_intent_classify_prompt_off_topic_default.exs`
    * `20260902140000_force_update_intent_classify_prompt_unmerge_intent_and_target.exs` — the base of this body.
    * this one — adds the roster on top of the un-merge.

  `down/0` is `:ok` — restoring the previous body is the previous migration's
  business.
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

  # Agents available in this org

  These are the ONLY agents that can be addressed. Each line gives an agent's name, its slug, and the `target_role` key it answers to. A name or slug that does NOT appear in this list is a person, not an agent.

  {{agent_roster}}

  ## Question 2 — TARGET: is an AGENT being asked to do something?

  Only once question 1 has an answer, ask who should act. Name a role from the closed `target_role` roster below if — and only if — one clearly applies. If the ask is aimed at a PERSON, or at nobody in particular, the answer to question 2 is `null`. That is a normal and expected answer. It is NOT a reason to go back and erase question 1's answer.

  Decide agent-or-person against the roster above, not against how the name sounds. If the utterance addresses a name or a slug that IS on the roster, an agent is being asked, and `target_role` is that agent's role key from the closed enum below. If it addresses a name that is NOT on the roster, a person is being asked: question 2's answer is `null` and question 1's intent stands unchanged.

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
    "room_id",
    "agent_roster"
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        Logger.info(
          "[ForceUpdateIntentClassifyPromptAgentRosterOnUnmerged] overwriting #{@slug} " <>
            "prior_sha256=#{:crypto.hash(:sha256, template.content) |> Base.encode16(case: :lower)} " <>
            "prior_bytes=#{byte_size(template.content)}\nprior_content:\n#{template.content}"
        )

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
