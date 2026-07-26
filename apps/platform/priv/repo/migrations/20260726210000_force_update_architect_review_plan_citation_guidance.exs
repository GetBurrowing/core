defmodule Platform.Repo.Migrations.ForceUpdateArchitectReviewPlanCitationGuidance do
  use Ecto.Migration

  # Task `019f9b28-6ca7` stage 5 (ADR-0046 stack member 3): the
  # `architecture.review_plan.v1` body instructed the architect to
  # "Prefer citing the ADR by number (e.g. ADR-0034)". `docs/decisions/`
  # holds four numbers that each name two different ADRs, so that
  # instruction produced confident citations of the wrong document. The
  # new `:adr_index` context slot is keyed on filename and flags the
  # collisions; the prompt has to stop asking for the ambiguous thing or
  # the block and the instruction contradict each other.
  #
  # `seed_defaults/0` is INSERT-only and
  # `20260708123000_force_update_architect_review_plan_template.exs`
  # already claimed this row on every existing deployment, so editing
  # `do_default_templates/0` alone would change the fallback body and
  # leave the live row serving the old guidance. Same force-update shape
  # as that migration, for the same reason.
  #
  # Skips slugs with no DB row (fresh boots pick them up via
  # `seed_defaults/0`).

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
