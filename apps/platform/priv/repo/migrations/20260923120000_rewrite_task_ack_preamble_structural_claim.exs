defmodule Platform.Repo.Migrations.RewriteTaskAckPreambleStructuralClaim do
  use Ecto.Migration

  @moduledoc """
  Task 01a0ac55-37e7-7001-9aec-051688ef7b07, stage 2.

  The ack-first preamble told every stage-scoped dispatch that requiring a
  `subagent_id` "makes it structurally impossible to ack a dispatch you never
  spawned a subagent for". `task_ack` checks only that the id is present and
  under 128 bytes; it cannot tell whether the id names a real spawn. The
  measurement that motivated fixing the WORDING (option 1) rather than adding
  server-side enforcement: of 4,039 `execution.acked` events on prod, 34%
  carried an id that is not an Agent-tool agentId (session UUIDs, invented
  labels such as `brosnan-executor-stage2`, `session_*`, `slug.host`), and no
  server check could distinguish those from honest ids.

  Stage 1 reworded `@task_ack_spawn_paragraph` in `do_default_templates/0`, but
  `seed_defaults/0` is insert-only and `render_template/2` serves the DB row,
  with the preamble baked into each row's content. This migration carries the
  rewording into the four seeded rows that embed the preamble:
  `dispatch.deploying`, `dispatch.in_progress`, `dispatch.in_review` and
  `dispatch.scribe_completion`.

  ## Why surgical, not a whole-body write

  The house pattern (`20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10`)
  writes `default_content_for_slug/1` over the whole row. These rows were last
  written between 2026-08-12 and 2026-09-11, and live rows have been hand-patched
  in prod before (PR #995), so a whole-body write could ship divergence that
  has nothing to do with this task. This migration replaces only the old
  paragraph, frozen below as a literal, with
  `PromptTemplates.task_ack_spawn_paragraph/0`. A row that is missing, or that
  no longer contains the old literal (already fixed, or hand-edited), is left
  untouched, so the migration is idempotent.

  ## Why down/0 is a no-op

  Rolling back would reinstate a false claim in a live dispatch prompt. There
  is no prior state worth restoring, so `down/0` deliberately does nothing.
  """

  alias Platform.Orchestration.PromptTemplates

  @slugs [
    "dispatch.deploying",
    "dispatch.in_progress",
    "dispatch.in_review",
    "dispatch.scribe_completion"
  ]

  # Frozen verbatim from origin/main's @task_ack_preamble second paragraph
  # (before task 01a0ac55). Never derive it from code: the code no longer says it.
  @old_paragraph "Spawn the subagent FIRST, then include its returned agent id in the ack. Empty or missing subagent_id will fail validation — this ordering makes it structurally impossible to ack a dispatch you never spawned a subagent for. Without a successful ack the router will fire a no-ack alert in 5 minutes."

  def slugs, do: @slugs
  def old_paragraph, do: @old_paragraph

  def up do
    new_paragraph = PromptTemplates.task_ack_spawn_paragraph()

    for slug <- @slugs do
      with %{content: content} = template when is_binary(content) <-
             PromptTemplates.get_template_by_slug(slug),
           true <- String.contains?(content, @old_paragraph) do
        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: String.replace(content, @old_paragraph, new_paragraph)
          })
      else
        _ -> :skip
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
