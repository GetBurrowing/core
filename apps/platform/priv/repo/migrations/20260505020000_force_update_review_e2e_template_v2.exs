defmodule Platform.Repo.Migrations.ForceUpdateReviewE2eTemplateV2 do
  use Ecto.Migration

  @slug "dispatch.review_e2e"

  @moduledoc """
  v2 of the validation system redesign (task 019df4a5) shifts the review
  template from "exactly one e2e_behavior validation per task" to "one or more
  pending e2e_behavior validations per task" and drops the planner-supplied
  failure_feedback field — the review agent observes failures and posts them
  at review time.

  This migration force-updates the seeded `dispatch.review_e2e` prompt template
  content to the latest hardcoded default — same pattern used by v1 stages 3-4
  and v2 stage 1.
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
