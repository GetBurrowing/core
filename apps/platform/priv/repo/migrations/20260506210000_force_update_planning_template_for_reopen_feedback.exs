defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateForReopenFeedback do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Surfaces the previous rejection reason on planner re-dispatch (task 019dfad1
  reopen-with-feedback flow). Adds a `{{previous_rejection_reason}}` placeholder
  to the seeded `dispatch.planning` template so a re-dispatched planner sees
  what didn't work last time and designs v2 to address it.

  This migration force-updates the seeded `dispatch.planning` prompt template
  content to the latest hardcoded default — same pattern as the prior force-
  update migrations (e.g. `20260506173000_force_update_planning_template_drop_deploy_stage.exs`).
  Production picks up the new placeholder on the next deploy.
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
