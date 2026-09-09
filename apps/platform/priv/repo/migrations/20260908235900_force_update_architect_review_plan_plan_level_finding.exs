defmodule Platform.Repo.Migrations.ForceUpdateArchitectReviewPlanPlanLevelFinding do
  use Ecto.Migration

  @moduledoc """
  Task `01a0588e` stage 3: `plan_architecture_verdict` now accepts a
  finding with no `stage_id` — an objection to the plan AS A WHOLE (a
  wrong decomposition, a sequencing defect with no single stage at
  fault). The capability is worthless unless the architect knows it
  exists: the old body told it every finding carries a `stage_id` and
  that an objection it could not pin to a stage belongs in `summary`
  with a `pass`. That sentence is exactly how a plan-level architectural
  defect became a passed gate.

  `seed_defaults/0` is INSERT-only and this row is already claimed on
  every existing deployment by
  `20260726210000_force_update_architect_review_plan_citation_guidance.exs`,
  so editing `do_default_templates/0` alone would change the fallback
  body and leave the live row serving the old instruction. Same
  force-update shape, for the same reason.

  Skips slugs with no DB row (fresh boots pick them up via
  `seed_defaults/0`).
  """

  @slug "architecture.review_plan.v1"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        case PromptTemplates.default_content_for_slug(@slug) do
          nil ->
            :skip

          content ->
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
