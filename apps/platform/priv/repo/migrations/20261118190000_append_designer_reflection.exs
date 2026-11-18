defmodule Platform.Repo.Migrations.AppendDesignerReflection do
  use Ecto.Migration

  @moduledoc """
  UX super agent phase 1 (PR #218, designer role from task 01a1af00): appends
  the end-of-job reflection instruction
  (`Platform.Designer.reflection_instruction/0`) to the stored
  `design.task_direction.v1` row.

  APPEND, not overwrite. The row may carry an operator edit or a promoted
  Scientist variant, and a force-update from the default would erase it. The
  append is skipped when the marker heading is already present, so a re-run
  (or a row seeded after this build, which already carries it) is a no-op.
  No row: `seed_defaults/0` inserts the default, which already ends with it.

  The text is inlined so this migration does not change if the module does.
  `down/0` removes exactly the appended block.
  """

  @slug "design.task_direction.v1"
  @marker "## Reflect before you stop"
  @block "\n\n" <>
           """
           ## Reflect before you stop

           After you have delivered or declined, and only if you hold the memory tools, write ONE entry in your private journal (`space/<your space id>/private/<your agent id>/journal/`): what you did and which pattern cards you used, what you would do differently, and each card whose confidence should move, with its evidence. Cap a reflection-only raise at 0.7. A human agreeing with you is not evidence and never raises a card. Never edit a prompt template, including this one. Save work in progress before any long step, and run at most 3 subagents at once.
           """

  def up do
    repo().query!(
      """
      UPDATE prompt_templates
         SET content = rtrim(content) || $2, updated_at = now()
       WHERE slug = $1 AND position($3 in content) = 0
      """,
      [@slug, @block, @marker]
    )
  end

  def down do
    repo().query!(
      "UPDATE prompt_templates SET content = replace(content, $2, ''), updated_at = now() WHERE slug = $1",
      [@slug, @block]
    )
  end
end
