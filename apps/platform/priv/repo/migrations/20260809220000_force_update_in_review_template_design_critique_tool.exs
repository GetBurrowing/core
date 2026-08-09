defmodule Platform.Repo.Migrations.ForceUpdateInReviewTemplateDesignCritiqueTool do
  use Ecto.Migration

  @slug "dispatch.in_review"

  @moduledoc """
  Force-updates the `dispatch.in_review` prompt template so the deployed row
  names a design-review mechanism that exists (task 019fe844 stage 3).

  The old paragraph told every reviewer to "obtain Saru's design review" and
  named no tool. There was none to name: the `design.critique` handler was a
  stub, and the only trigger it carried was a chat pattern the Router's
  feedback-loop guard closes to agents. The instruction was therefore
  satisfiable only by improvisation, and it was improvised four different
  ways — including one gate filed stating no design review had been obtained,
  minutes before a critique arrived carrying a finding the reviewer missed.
  Stages 1 and 2 built the mechanism; this stage points the instruction at it.

  THIS MIGRATION IS THE DELIVERABLE, not the descriptor edit in
  `do_default_templates/0`. `PromptTemplates.render_template/2` is tried FIRST
  and the DB row wins in every migrated environment; the hardcoded body is only
  the fallback where no row exists. `seed_defaults/0` is INSERT-only, so every
  environment that has ever booted still holds the OLD paragraph. Without this
  migration the tool would ship and no reviewer would ever be told to call it.

  Same force-update pattern as
  `20260731230000_force_update_in_review_template_stage_description.exs`:
  look up by slug, `:skip` when absent (first boot is `seed_defaults/0`'s job),
  otherwise rewrite `content` from `default_content_for_slug/1` and `variables`
  from the shipped descriptor. `variables` is unchanged by this stage but is
  rewritten anyway so the row cannot drift from its descriptor. `down/0` is
  `:ok` — reinstating an instruction that cannot be followed is not a state
  worth restoring.

  Scoped to `dispatch.in_review` alone. `dispatch.review_e2e` is NOT touched:
  it dispositions behavioural validations and never carried the design-review
  paragraph.
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
