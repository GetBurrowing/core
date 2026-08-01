defmodule Platform.Repo.Migrations.ForceUpdateInReviewTemplateStageDescription do
  use Ecto.Migration

  @slug "dispatch.in_review"

  @moduledoc """
  Force-updates the `dispatch.in_review` prompt template so the deployed row
  actually carries the running stage's own description (task 019fba28 stage 3).

  Same boundary as stage 2's migration, second consumer. Stage 3 added the
  `stage_description:` assign to `review_prompt/5` (reusing stage 1's
  `format_stage_description/1` unchanged), the matching interpolation in
  `hardcoded_dispatch_in_review/4`, and both `{{stage_description}}` and the
  `"stage_description"` variable on the shipped descriptor in
  `do_default_templates/0`. It also amended the two lines in that body that
  steered the reviewer away from `suite_plan_get` and pointed it at a `context`
  field the channel bridge never surfaces.

  THIS MIGRATION IS THE DELIVERABLE, not that descriptor edit.
  `PromptTemplates.render_template/2` is tried FIRST and the DB row wins in
  every migrated environment; the hardcoded body is only the fallback for an
  environment with no row at all. `PromptTemplates.seed_defaults/0` is
  INSERT-only (skip-if-exists), so every environment that has ever booted
  already holds the OLD body. Without this migration the code change would
  merge, CI would go green, and a reviewer judging a `manual_approval` gate
  would keep being sent the stage NAME and nothing else.

  Both `content` and `variables` are rewritten. `variables` is not decorative:
  stage 3 adds `"stage_description"` to it and the prompt-template admin UI
  lists that field, so a content-only rewrite would leave the row's declared
  variable list stale and disagreeing with its own body.

  Force-update pattern taken from
  `20260731220000_force_update_in_progress_template_stage_description.exs`,
  itself taken from `20260727183000_force_update_planning_template_drop_ack.exs`:
  look the row up by slug, `:skip` when absent (first boot is
  `seed_defaults/0`'s job), otherwise rewrite `content` from
  `default_content_for_slug/1` and `variables` from the shipped descriptor.
  Environments already matching see a changeset no-op. `down/0` is `:ok` —
  reinstating a review dispatch that drops the planner's specification is not a
  state worth being able to restore.

  Deliberately scoped to `dispatch.in_review` alone. `dispatch.review_e2e` is
  NOT touched: the planner's authored substance already reaches that branch
  through `pending_e2e_validations_json`. `dispatch.deploying` is NOT touched:
  a deploy stage's description is engine-synthesized boilerplate from
  `DeployStageBuilder`.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      %PromptTemplate{} = template ->
        content = PromptTemplates.default_content_for_slug(@slug)
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
        variables = (descriptor && descriptor.variables) || template.variables

        case PromptTemplates.update_template(template, %{content: content, variables: variables}) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
