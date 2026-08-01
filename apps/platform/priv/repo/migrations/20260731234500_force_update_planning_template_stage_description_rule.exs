defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateStageDescriptionRule do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Force-updates the `dispatch.planning` prompt template so every planner is
  told that a constraint binds only when it is restated inside a stage
  `description` (task 019fba28 stage 4).

  This is fix (b) of the task, and it lands only after stages 1-3 made the
  stage description a field the execution and human-gate dispatches actually
  render. Before those stages the new section would have instructed planners to
  write constraints into text no implementer is ever shown — a sentence added
  to a prompt that changes nothing observable, which is the defect class this
  task exists to close.

  The section added to the body says three things: the ticket body is rendered
  into the PLANNING dispatch and no other; anything that must bind the
  implementer has to be restated inside the relevant stage's `description`,
  in checkable form (file path, assertion, what failure looks like); and the
  constraint kinds that most often need restating are what-not-to-do,
  out-of-scope, mutation/anti-vacuity requirements, and premises the planner
  already verified. It closes by naming its own recursion — a planner that
  reads the rule and does not restate has already lost the constraint.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to `do_default_templates/0`.
  `PromptTemplates.render_template/2` is tried FIRST and the DB row wins in
  every migrated environment; the hardcoded `hardcoded_dispatch_planning/4`
  body is only the fallback for an environment with no row at all.
  `PromptTemplates.seed_defaults/0` is INSERT-only (skip-if-exists), so every
  environment that has ever booted already holds the OLD body. Without this
  migration the descriptor edit would merge, CI would go green, and no planner
  on any real environment would ever read the rule.

  Force-update pattern taken from
  `20260727183000_force_update_planning_template_drop_ack.exs`, which performed
  this exact operation on this exact row six days ago: look the row up by slug,
  `:skip` when absent (first boot is `seed_defaults/0`'s job), otherwise
  rewrite `content` from `default_content_for_slug/1` and `variables` from the
  shipped descriptor. This stage adds no new variable — the section is static
  prose with no placeholder — but `variables` is still rewritten from the
  descriptor so the row cannot drift from the shipped list, matching stages 2
  and 3. Environments already matching see a changeset no-op. `down/0` is `:ok`
  — restoring a planning dispatch that never mentions the boundary is not a
  state worth being able to return to.

  Scoped to `dispatch.planning` alone. No other slug's body carries this
  section: the rule is addressed to the agent that authors stage descriptions,
  and no other dispatch kind reaches one.
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
