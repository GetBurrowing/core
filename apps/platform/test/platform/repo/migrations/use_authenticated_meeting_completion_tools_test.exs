defmodule Platform.Repo.Migrations.UseAuthenticatedMeetingCompletionToolsTest do
  use Platform.DataCase, async: false

  @migration Path.expand(
               "../../../../priv/repo/migrations/20261027193000_use_authenticated_meeting_completion_tools.exs",
               __DIR__
             )
  Code.require_file(@migration)
  alias Platform.Repo.Migrations.UseAuthenticatedMeetingCompletionTools, as: Migration

  test "exact legacy handoff replacement preserves unrelated human text and is idempotent" do
    content = """
    Human identity: user:operator; preserve install corrections.
    Fetch meeting + transcript context via `space_get_context` on `{{space_id}}` and direct
    Meetings context reads keyed by `{{transcript_id}}`. Filter `memory_search` calls with
    `transcript_id={{transcript_id}}` so other meetings' content does not leak into your canvas.

    Human footer: retain this sentence unchanged.
    """

    updated = Migration.rewrite(content)
    assert updated =~ "full"
    assert updated =~ "completion_transcript"
    assert updated =~ "Human identity: user:operator; preserve install corrections."
    assert updated =~ "Human footer: retain this sentence unchanged."
    assert Migration.rewrite(updated) == updated
  end

  test "only the exact generated task-stage preamble is removed" do
    prefix = Platform.Orchestration.PromptTemplates.task_ack_preamble()

    assert Migration.rewrite(prefix <> "\n{{federation_preamble}}\nHuman copy") ==
             "{{federation_preamble}}\nHuman copy"

    custom =
      "**Your first tool call must be `suite_task_ack(custom human edit)`**\n{{federation_preamble}}"

    assert Migration.rewrite(custom) == custom
  end

  test "skill signal contract changes without rewriting human additions" do
    content = """
    Human addition preserved.
    ## 1. Signal shape

    The `meeting_triage_dispatch` attention signal (broadcast by
    `Platform.Federation.dispatch_triage_attention/2`) carries four ids in
    its payload:
    """

    updated = Migration.rewrite_skill(content)
    assert updated =~ "snapshot_hash"
    assert updated =~ "completion_transcript"
    assert updated =~ "Human addition preserved."
    assert Migration.rewrite_skill(updated) == updated
  end

  test "up rewrites persisted stale prompts and skill while preserving human edits" do
    alias Platform.Orchestration.PromptTemplates
    :ok = PromptTemplates.seed_defaults()
    Platform.Skills.seed_defaults()

    scribe = """
    HUMAN SCRIBE PREFIX: preserve identity and hostname corrections.
    Fetch meeting + transcript context via `space_get_context` on `{{space_id}}` and direct
    Meetings context reads keyed by `{{transcript_id}}`. Filter `memory_search` calls with
    `transcript_id={{transcript_id}}` so other meetings' content does not leak into your canvas.

    ## After canvas_create — dispatch the triage agent

    Once `canvas_create` returns a `canvas_id`, IMMEDIATELY call
    `Platform.Federation.dispatch_triage_attention/2` (added by stack member C — this template
    only references it; do not try to import or verify existence at plan time) with:

    - the new `canvas_id`, so the triage agent can walk Card 3's `checklist_item.note` payloads.
    - the source signal metadata: `%{transcript_id: "{{transcript_id}}", room_id: "{{room_id}}",
      space_id: "{{space_id}}", meeting_name: "{{meeting_name}}"}`.

    The triage agent picks up the action items and creates real tasks. Without this dispatch the
    action items sit stranded on the canvas.

    HUMAN SCRIBE SUFFIX: preserve custom instructions.
    """

    triage = """
    HUMAN TRIAGE PREFIX: preserve review policy.
    5. **Hand parsed items to Triage.** Call `Platform.Meetings.Triage.file_tasks_from_canvas/2` with the source canvas and the parsed checklist items (stack member E's surface). Do NOT reimplement the filing loop yourself. Do NOT reimplement the dedup check yourself — Triage.file_tasks_from_canvas/2 calls `Platform.Tasks.similar_open_titles/3` internally and returns a per-item verdict (`{:filed, task_id}` | `{:skipped_dupe, existing_task_id}` | `{:fallback_project, task_id}`) that you reflect in the summary card.

    HUMAN TRIAGE SUFFIX: preserve escalation policy.
    """

    skill_content = """
    HUMAN SKILL PREFIX: preserve tenant conventions.
    ## 1. Signal shape

    The `meeting_triage_dispatch` attention signal (broadcast by
    `Platform.Federation.dispatch_triage_attention/2`) carries four ids in
    its payload:
    HUMAN SKILL SUFFIX: preserve custom priorities.
    """

    for {slug, content} <- [
          {"dispatch.scribe_completion", scribe},
          {"dispatch.triage_dispatch", triage}
        ] do
      template = PromptTemplates.get_template_by_slug(slug)
      assert {:ok, _} = PromptTemplates.update_template(template, %{content: content})
    end

    skill = Platform.Skills.get_skill_by_slug("meeting-triage-officer")
    assert {:ok, _} = Platform.Skills.update_skill(skill, %{content: skill_content})

    assert :ok = Migration.up()
    updated_scribe = PromptTemplates.get_template_by_slug("dispatch.scribe_completion").content
    updated_triage = PromptTemplates.get_template_by_slug("dispatch.triage_dispatch").content
    updated_skill = Platform.Skills.get_skill_by_slug("meeting-triage-officer").content
    assert updated_scribe =~ "meeting_scribe_complete"
    assert updated_scribe =~ "full"
    assert updated_scribe =~ "completion_transcript"
    assert updated_scribe =~ "HUMAN SCRIBE PREFIX: preserve identity and hostname corrections."
    assert updated_scribe =~ "HUMAN SCRIBE SUFFIX: preserve custom instructions."
    assert updated_triage =~ "meeting_triage_file"
    assert updated_triage =~ "full ordered segments"
    assert updated_triage =~ "HUMAN TRIAGE PREFIX: preserve review policy."
    assert updated_triage =~ "HUMAN TRIAGE SUFFIX: preserve escalation policy."
    assert updated_skill =~ "meeting_triage_file"
    assert updated_skill =~ "snapshot_hash"
    assert updated_skill =~ "HUMAN SKILL PREFIX: preserve tenant conventions."
    assert updated_skill =~ "HUMAN SKILL SUFFIX: preserve custom priorities."
    assert :ok = Migration.up()

    assert PromptTemplates.get_template_by_slug("dispatch.scribe_completion").content ==
             updated_scribe

    assert PromptTemplates.get_template_by_slug("dispatch.triage_dispatch").content ==
             updated_triage

    assert Platform.Skills.get_skill_by_slug("meeting-triage-officer").content == updated_skill
  end
end
