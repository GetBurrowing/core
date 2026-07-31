defmodule Platform.Repo.Migrations.UpdateActionItemsPromptForLiveMeeting do
  use Ecto.Migration

  @moduledoc """
  Rewrite the `meetings.action_items.v1` prompt for mid-meeting canvas
  work (task 019fb90f-36e3 stage 3).

  ## Why a migration and not an edit to the seed file

  `20260703120200_seed_prompt_templates_meeting_scribe.exs` created this
  row, with a description that reads "from a finished meeting
  transcript" and a body that opens "A meeting just ended". Both are now
  false: the key fires per classified utterance while the meeting is
  still running (stage 1) over three live context slots (stage 2).

  Editing that seed file changes nothing on any environment that has
  migrated — it has already run there, and
  `PromptTemplates.seed_defaults/0` is INSERT-only (`nil -> create`,
  `_existing -> :skip`). The row has to be force-updated, which is what
  this does.

  ## Why the body is duplicated inline rather than patched

  Same reasoning as
  `20260726000100_update_intent_classify_prompt_with_corrections`: a
  `String.replace/3` against whatever is currently in the row would
  silently produce a different prompt on any environment where somebody
  iterated the wording live through the `prompt_template_update` MCP
  tool. Overwriting with a known-good body makes every environment
  byte-identical, which is the only property the runtime depends on.

  ## Marker set

  `@new_variables` is the set of `{{marker}}` names in `@new_content`,
  and it must equal the set in
  `Handlers.MeetingActionItems`'s `@fallback_action_items_prompt`. That
  equality is asserted mechanically in
  `meeting_action_items_test.exs` — a marker in one body and not the
  other is how a rollout gap turns into a silently untuned prompt.

  ## `down/0`

  `:ok`. Rolling back to a body that tells the model a meeting just
  ended, while the key only fires mid-meeting, would be a worse state
  than the one being rolled back from; and restoring the 20260703 body
  is that migration's business, not this one's.
  """

  @slug "meetings.action_items.v1"

  @new_description "Meeting Scribe reconciles the live action-items canvas from one classified utterance during an in-progress meeting."

  @new_content """
  You are the Meeting Scribe's `meetings.action_items` responsibility, working DURING a live meeting.

  A meeting is happening right now. One thing was just said, a cheap fast model flagged it as being about action items, and you are being asked what that ONE utterance changes about the meeting's action-items canvas. You are not summarising a meeting and you are not reading a finished transcript — you are keeping a live list correct while people are still talking.

  # The utterance you are acting on

  {{meeting_intent}}

  **Read the excerpt before the label.** `classified_intent` is a cheap fast model's label and nothing more. Its only job was to notice that this text might be about action items; it made no add, update, or remove decision, and it is routinely wrong about the details. The excerpt is the ground truth. Where the two disagree the excerpt wins, and when the excerpt turns out not to be about action items at all, returning no operations is the correct answer.

  Every add, update, and remove decision is made here, from the utterance and the context around it. The speaker attribution is best-effort and may be missing or wrong; when the utterance itself names an owner, the utterance wins.

  # What was said just before

  {{transcript_window}}

  Use these lines ONLY to resolve pronouns, subjects, and deadlines in the utterance — "that", "she", "by then". Do not mine them for action items of their own; they have already been seen.

  # The canvas you are reconciling against

  {{action_items_canvas}}

  This is the CURRENT contents of this meeting's action-items canvas — the list as it stands right now, not a draft.

  - When no canvas exists yet, the items you add create it.
  - When it already has items you are MODIFYING it. Reconcile against what is already there rather than appending blindly:
    - someone says they already did an item -> mark that item complete
    - an owner, a deadline, or the substance of an item changes -> amend that item
    - an item is retracted, cancelled, or decided against -> remove it
    - a genuinely new commitment -> add it
  - An item the utterance does not touch is left exactly as it is. Say nothing about it.

  Match an existing item by its text: quote enough of its label back in `match` to identify it unambiguously.

  # Output

  Return ONLY a single JSON object — no markdown fence, no prose, no leading whitespace — matching:

      {"operations": [ ... ]}

  Each operation is exactly one of:

      {"op": "add", "label": "<owner> <verb-first commitment> (<due when stated>)", "state": "pending"}
      {"op": "update", "match": "<text of the existing item>", "label": "<new text, omit when unchanged>", "state": "complete"}
      {"op": "remove", "match": "<text of the existing item>"}

  Rules:
  - `state` is one of `pending`, `active`, `complete`. Omit it on `add` to mean `pending`.
  - One commitment per item, phrased as a single actionable sentence.
  - Name the assignee when the utterance or the surrounding lines identify one, and keep a stated deadline in the text.
  - Invent nothing. Only what was actually committed to out loud.
  - `{"operations": []}` is a correct and expected answer. Most utterances change nothing, and an empty list is how you say so.

  # Grounding context

  {{org_identity}}

  Platform context for entity names only. It is not meeting content and it contains no action items.
  """

  @new_variables [
    "meeting_intent",
    "transcript_window",
    "action_items_canvas",
    "org_identity"
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        # Genuine no-op guard rather than a rollout path: the 20260703
        # seed created this row on every environment that has migrated
        # at all, and migrations run in timestamp order. This branch
        # exists so a DB where an operator deleted the row does not fail
        # the whole migration run.
        :skip

      template ->
        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: @new_content,
            description: @new_description,
            variables: @new_variables
          })
    end

    :ok
  end

  def down, do: :ok
end
