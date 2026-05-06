defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropDeployStage do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Drops the planner's responsibility to author a deploy stage. The system
  auto-injects the deploy stage when the task transitions to `deploying`
  (see `Platform.Tasks.PlanEngine.maybe_inject_deploy_or_complete/2` and
  `Platform.Tasks.DeployStageBuilder.build_stage/2`).

  This migration force-updates the seeded `dispatch.planning` prompt template
  content to the latest hardcoded default — same pattern as the prior force-
  update migrations (e.g. `20260505010000_force_update_planning_template_v2.exs`).
  Production picks up the new role-separation guidance on the next deploy.
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
