defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateV2 do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  v2 of the validation system redesign (task 019df4a5) drops `failure_feedback`
  from the planner-supplied e2e_behavior evaluation_payload schema and allows
  multiple e2e_behavior validations per task (the planner-authored adversarial
  test plan, user-approved at plan time).

  This migration force-updates the seeded `dispatch.planning` prompt template
  content to the latest hardcoded default — same pattern used by v1 stages 3-4.
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
