defmodule Platform.Repo.Migrations.ForceUpdateArchitectTemplatesExperimentSurface do
  use Ecto.Migration

  @moduledoc """
  Task `01a0d41e` stage 1 (ADR-0046 Amendment 2,
  `0046-design-and-architecture-phases-in-planning.md`): the closed
  architect vocabulary gains `experiment_surface`, and the
  `architecture.review_plan.v1` body gains the three-condition rule that
  says when it may be used. `architecture.audit_diff.v1` lists the value
  with its diff-time clause.

  `seed_defaults/0` is INSERT-only and both rows already exist on every
  deployment, so editing `do_default_templates/0` alone would change the
  fallback body and leave the live rows telling the architect there are
  four constraints — the tool would accept a value the prompt never
  mentions. Same force-update shape as
  `20260908235900_force_update_architect_review_plan_plan_level_finding.exs`:
  the body AND the descriptor description are read from the code rather
  than frozen here, and slugs with no DB row are skipped (fresh boots
  pick them up via `seed_defaults/0`).
  """

  @slugs ["architecture.review_plan.v1", "architecture.audit_diff.v1"]

  def slugs, do: @slugs

  def up do
    alias Platform.Orchestration.PromptTemplates

    for slug <- @slugs do
      with template when not is_nil(template) <- PromptTemplates.get_template_by_slug(slug),
           %{content: content, description: description} <-
             Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug)) do
        {:ok, _} =
          PromptTemplates.update_template(template, %{content: content, description: description})
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
