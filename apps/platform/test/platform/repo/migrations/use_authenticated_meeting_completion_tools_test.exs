defmodule Platform.Repo.Migrations.UseAuthenticatedMeetingCompletionToolsTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../../../priv/repo/migrations/20261027193000_use_authenticated_meeting_completion_tools.exs",
               __DIR__
             )
  Code.require_file(@migration)
  alias Platform.Repo.Migrations.UseAuthenticatedMeetingCompletionTools, as: Migration

  test "exact legacy handoff replacement preserves unrelated human text and is idempotent" do
    content = """
    Human identity: user:ryan; preserve Kobo corrections.
    Fetch meeting + transcript context via `space_get_context` on `{{space_id}}` and direct
    Meetings context reads keyed by `{{transcript_id}}`. Filter `memory_search` calls with
    `transcript_id={{transcript_id}}` so other meetings' content does not leak into your canvas.

    Human footer: retain this sentence unchanged.
    """

    updated = Migration.rewrite(content)
    assert updated =~ "full"
    assert updated =~ "completion_transcript"
    assert updated =~ "Human identity: user:ryan; preserve Kobo corrections."
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
    `Platform.Federation.dispatch_triage_attention/2`) carries four ids in
    its payload:
    """

    updated = Migration.rewrite_skill(content)
    assert updated =~ "snapshot_hash"
    assert updated =~ "completion_transcript"
    assert updated =~ "Human addition preserved."
    assert Migration.rewrite_skill(updated) == updated
  end
end
