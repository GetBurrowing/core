defmodule Platform.Repo.Migrations.UseAuthenticatedMeetingCompletionTools do
  use Ecto.Migration

  @moduledoc """
  Task 01a17f00-832c-7000-b480-64ab6d710532 stage 2 replaces unreachable
  internal meeting handoff instructions with authenticated completion tools.
  Exact span replacements preserve human edits and install-specific scribe
  correction rules measured on Kobo and milv before authoring this migration.
  A repeated run is a no-op; down does not restore the broken filing contract.
  """
  alias Platform.Orchestration.PromptTemplates

  # Read BOTH Kobo and milv before authoring (2026-10-27): same legacy handoff spans;
  # scribe rows retain install corrections and identity examples. Replace exact spans only.
  @replacements [
    {~S"""
     Fetch meeting + transcript context via `space_get_context` on `{{space_id}}` and direct
     Meetings context reads keyed by `{{transcript_id}}`. Filter `memory_search` calls with
     `transcript_id={{transcript_id}}` so other meetings' content does not leak into your canvas.

     """,
     ~S"""
     Read `meeting_id`, `run_id`, `snapshot_hash`, `completion_transcript` and
     `source_transcript_ids` from the attention signal. `completion_transcript` is the full
     ordered segment snapshot across the meeting's recordings. Use it, not the latest chunk
     or summary alone. Preserve these canonical identities unchanged in the callback.
     Use `space_get_context` for supporting context only. No task or stage ack is needed.

     """},
    {~S"""
     Use a `checklist` node whose children are `checklist_item` nodes. For each action item:

     """,
     ~S"""
     Use an `actions` checklist whose children are `checklist_item` nodes. Give every item a
     stable node `id`; triage uses that exact id as `item_id` across retries. Include grounded
     descriptions and `source_segment_ids` from `completion_transcript` in the note. Separate
     questions and canvas edits from concrete follow-up work; do not turn transcript comments
     into tasks. For each action item:

     """},
    {~S"""
     ## After canvas_create — dispatch the triage agent

     Once `canvas_create` returns a `canvas_id`, IMMEDIATELY call
     `Platform.Federation.dispatch_triage_attention/2` (added by stack member C — this template
     only references it; do not try to import or verify existence at plan time) with:

     - the new `canvas_id`, so the triage agent can walk Card 3's `checklist_item.note` payloads.
     - the source signal metadata: `%{transcript_id: "{{transcript_id}}", room_id: "{{room_id}}",
       space_id: "{{space_id}}", meeting_name: "{{meeting_name}}"}`.

     The triage agent picks up the action items and creates real tasks. Without this dispatch the
     action items sit stranded on the canvas.

     """,
     ~S"""
     ## After canvas_create — complete the scribe run

     Call the MCP tool `meeting_scribe_complete` with `meeting_id`, `run_id`, `transcript_id`,
     `snapshot_hash` copied unchanged from the signal and `canvas_id` returned by canvas_create.
     This authenticated callback invokes the server's triage dispatch. Do not call internal
     Elixir functions or file tasks yourself. A callback error means the handoff is incomplete;
     report it and retry the same run rather than creating another canvas or filing independently.

     """},
    {~S"""
     5. **Hand parsed items to Triage.** Call `Platform.Meetings.Triage.file_tasks_from_canvas/2` with the source canvas and the parsed checklist items (stack member E's surface). Do NOT reimplement the filing loop yourself. Do NOT reimplement the dedup check yourself — Triage.file_tasks_from_canvas/2 calls `Platform.Tasks.similar_open_titles/3` internally and returns a per-item verdict (`{:filed, task_id}` | `{:skipped_dupe, existing_task_id}` | `{:fallback_project, task_id}`) that you reflect in the summary card.

     """,
     ~S"""
     5. **File through the authenticated completion tool.** Read `meeting_id`, `run_id`,
        `snapshot_hash`, `completion_transcript` and `source_transcript_ids` from the signal.
        Review the full ordered segments, including late final segments. For each real follow-up,
        submit `item_id` equal to its canonical checklist_item node id, a normalized imperative
        `title`, grounded `description`, and nonempty `source_segment_ids` from that snapshot.
        Call `meeting_triage_file` with `meeting_id`, `run_id`, `transcript_id`, `canvas_id`,
        `snapshot_hash` and `action_items`. Questions and canvas edits stay on their canvases.
        Submit synthesis duplicate/conflict/exclude decisions with the same item_id and
        `decision`; these create no task. Do not call task_create or internal Elixir functions.

     """},
    {~S"""
     Do NOT check for pre-existing tasks yourself — `Platform.Meetings.Triage.file_tasks_from_canvas/2` calls `Platform.Tasks.similar_open_titles/3` internally (added by stack member E). Trust its verdict and reflect skipped items in the summary card with `status: skipped_dupe` and the pre-existing `task_id` in the row rather than a freshly-filed one. Re-broadcasting the same `meeting_triage_dispatch` on the same canvas must produce zero new tasks.

     ## Telemetry

     Emit two events during this dispatch so `Platform.Meetings.TelemetryHandler` (added by stack member E) can observe the pass. Do NOT attach a handler yourself — E's handler is already wired.

     - On dispatch entry, after step 2 counts the checklist items, emit `[:platform, :meetings, :triage_dispatch]` with measurements `%{items: N}` (where `N` is the count of `checklist_item` children under the `actions` section) and metadata `%{canvas_id: {{canvas_id}}, transcript_id: {{transcript_id}}}`.
     - After `Platform.Meetings.Triage.file_tasks_from_canvas/2` returns, emit `[:platform, :meetings, :tasks_created_from_meeting]` with measurements `%{filed_count: F, skipped_count: S, fallback_project_count: P}` computed from the per-item verdicts, and metadata `%{canvas_id: {{canvas_id}}, transcript_id: {{transcript_id}}}`.

     """,
     ~S"""
     The server owns filing, deduplication, caps and audit provenance. Reuse the same run,
     snapshot_hash and canonical checklist item ids on retry, including when an earlier task
     is done. Never mint another item id from its title. The synthesis pass supplies duplicate
     and conflict decisions through this same boundary and never files independently.
     Delivery is not successful filing: inspect the returned persisted status and task_ids.
     If the snapshot is stale, wait for the refreshed completion dispatch; do not bypass it.
     Server-side Triage emits filing telemetry; the remote runtime does not invoke telemetry.

     """},
    {~S"""
     6. **Append a summary card to the source canvas.** After `file_tasks_from_canvas/2` returns, patch the source canvas by appending a new `card` node containing a `table` with one row per checklist_item. Columns: `title` (from the checklist_item label), `task_id` (the id returned by Triage, or `-` for skipped items with no filed task), and `status` (one of `filed`, `skipped_dupe`, `fallback_project`). Use `canvas_patch` with the `append_child` operation against the canvas root; do NOT rewrite the whole document.
     """,
     ~S"""
     6. **Append a summary card to the source canvas.** After `meeting_triage_file` returns,
        append its persisted status and cumulative task_ids to the source canvas. Report excluded
        duplicate/conflict items without invented task ids. The return is a run-level ledger,
        not per-item verdicts; do not infer newly created tasks from a replay's task_ids.
        Use canvas_patch append_child; preserve the existing document.
     """}
  ]

  @skill_replacements [
    {~S"""
     ## 1. Signal shape

     The `meeting_triage_dispatch` attention signal (broadcast by
     """,
     ~S"""
     ## 1. Signal shape

     Call `meeting_triage_file` with `meeting_id`, `run_id`, `transcript_id`,
     `canvas_id`, `snapshot_hash` copied from the completion dispatch, plus
     `action_items`. Read `completion_transcript` (the full ordered segments
     across `source_transcript_ids`), not a summary or latest chunk alone.
     Each filed item requires `item_id` equal to the canonical checklist_item
     node id, normalized imperative `title`, grounded `description`, and
     nonempty `source_segment_ids` drawn from that snapshot. Never use raw
     utterances as titles. Questions and canvas edits remain canvas-only.
     Synthesis duplicate/conflict/exclude decisions use the same item_id with
     `decision`; these create no tasks. Never call task_create independently.
     The tool invokes the internal Triage function with its dedup and caps.
     Reuse the same run, snapshot_hash and canonical item ids on retry,
     including after a filed task is done. Report callback failures and wait
     for a refreshed dispatch if the snapshot changed.

     The `meeting_triage_dispatch` attention signal (broadcast by
     """},
    {~S"""
     becomes the filed task's title verbatim (Triage may normalise
     trailing punctuation but does not rewrite the label).
     """,
     ~S"""
     is candidate evidence. Normalize it to an imperative task title and
     a grounded description before submitting it through meeting_triage_file.
     """},
    {~S"""
     Do NOT dedup yourself. `Platform.Meetings.Triage.file_tasks_from_canvas/2`
     calls `Platform.Tasks.similar_open_titles/3` internally (from stack
     member E) and returns a per-item verdict:
     """,
     ~S"""
     Server-side Triage owns title dedup; the persisted completion run owns
     stable run/item replay, including done tasks. Inspect meeting_triage_file's
     persisted status and task_ids before reporting successful filing. Internal
     per-item verdicts reflected in the audit summary include:
     """},
    {~S"""
     `Platform.Federation.dispatch_triage_attention/2`) carries four ids in
     its payload:
     """,
     ~S"""
     `Platform.Federation.dispatch_triage_attention/2`) carries the canonical
     meeting_id, run_id, transcript_id, canvas_id and snapshot_hash, plus full
     completion_transcript and source_transcript_ids. It also carries:
     """},
    {~S"""
     Server-side Triage owns title dedup; the persisted completion run owns
     stable run/item replay, including done tasks. Inspect meeting_triage_file's
     persisted status and task_ids before reporting successful filing. Internal
     per-item verdicts reflected in the audit summary include:

     - `{:filed, task_id}` — new task inserted; put in the summary row as
       `status: filed`.
     - `{:skipped_dupe, existing_task_id}` — an open task with a
       near-identical title already exists; put in the summary row as
       `status: skipped_dupe` and reflect the pre-existing `task_id`,
       NOT a new one.
     - `{:fallback_project, task_id}` — filed against the fallback
       project (see section 3); put in the summary row as
       `status: fallback_project`.

     Re-broadcasting the same `meeting_triage_dispatch` on the same
     canvas must produce zero new tasks — every checklist_item's dedup
     hit produces `skipped_dupe` on the second pass. Reflect that in the
     summary card so an operator viewing the canvas after two passes can
     see the second pass filed nothing.
     """,
     ~S"""
     Server-side Triage owns title dedup; the persisted completion run owns
     stable run/item replay, including done tasks. The meeting_triage_file
     response contains meeting_id, run_id, status, canvas_id and task_ids.
     Report success only when status is filed; delivery alone is not filing.
     The response is cumulative for this run, so a replay returning the same
     task_ids does not mean new tasks were created. Record duplicate/conflict
     decisions as exclusions, without inventing task ids or per-item verdicts
     absent from the tool response. Reuse canonical item ids on every retry.
     """}
  ]

  def rewrite(content) do
    content =
      Enum.reduce(@replacements, content, fn {old, new}, acc -> String.replace(acc, old, new) end)

    # Exact generated prefix only; preserve a customized preamble or added text.
    String.replace_prefix(content, PromptTemplates.task_ack_preamble() <> "\n", "")
  end

  def rewrite_skill(content),
    do:
      Enum.reduce(@skill_replacements, content, fn {old, new}, acc ->
        String.replace(acc, old, new)
      end)

  def up do
    for slug <- ["dispatch.scribe_completion", "dispatch.triage_dispatch"] do
      case PromptTemplates.get_template_by_slug(slug) do
        %{content: content} = template ->
          updated = rewrite(content)

          if updated != content,
            do: PromptTemplates.update_template(template, %{content: updated})

        _ ->
          :ok
      end
    end

    case Platform.Skills.get_skill_by_slug("meeting-triage-officer") do
      %{content: content} = skill ->
        updated = rewrite_skill(content)
        if updated != content, do: Platform.Skills.update_skill(skill, %{content: updated})

      _ ->
        :ok
    end

    :ok
  end

  def down, do: :ok
end
