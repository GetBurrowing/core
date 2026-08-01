defmodule Platform.Repo.Migrations.ForceUpdateArchitectReviewPlanTemplate do
  use Ecto.Migration

  @moduledoc """
  ADR-0044 stage 3 (task `019f3da3`): the stage-1 placeholder body for
  `architecture.review_plan.v1` was seeded by
  `20260708120100_seed_prompt_templates_architect.exs`. Stage 3 ships
  the real prompt via `Platform.Orchestration.PromptTemplates.do_default_templates/0`,
  but `seed_defaults/0` is INSERT-only — a deployment that already ran
  the stage-1 migration would keep serving the placeholder body
  without an explicit overwrite. Force-update to
  `default_content_for_slug/1`'s current output.

  Skips slugs with no DB row (fresh boots pick them up via
  `seed_defaults/0`). Mirrors the `force_update_*` migration pattern
  at 20260520010000.
  """

  @slug "architecture.review_plan.v1"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          # Also refresh the variables list so a fresh render picks up
          # `open_prs` (introduced by the stage-3 rewrite).
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: content,
              variables: ["plan_summary", "sibling_tasks", "open_prs", "adr_index"],
              name: "Architecture Review — Plan-time"
            })
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
