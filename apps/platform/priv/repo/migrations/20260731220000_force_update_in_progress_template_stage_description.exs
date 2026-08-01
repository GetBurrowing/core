defmodule Platform.Repo.Migrations.ForceUpdateInProgressTemplateStageDescription do
  use Ecto.Migration

  @slug "dispatch.in_progress"

  @moduledoc """
  Force-updates the `dispatch.in_progress` prompt template so the deployed row
  actually carries the running stage's own description (task 019fba28 stage 2).

  Stage 1 added `HeartbeatScheduler.format_stage_description/1`, the
  `stage_description:` assign on `in_progress_prompt/4`, the matching
  interpolation in `hardcoded_dispatch_in_progress/4`, and both
  `{{stage_description}}` and the `"stage_description"` variable on the shipped
  descriptor in `do_default_templates/0`.

  THIS MIGRATION IS THE DELIVERABLE, not that descriptor edit.
  `PromptTemplates.render_template/2` is tried FIRST and the DB row wins in
  every migrated environment; the hardcoded body is only the fallback for an
  environment that has no row at all. `PromptTemplates.seed_defaults/0` is
  INSERT-only (skip-if-exists), so every environment that has ever booted
  already holds the OLD body — one without the placeholder. Without this
  migration stage 1 would merge, CI would go green, and production would keep
  serving an execution dispatch that carries the stage NAME and nothing else.

  Both `content` and `variables` are rewritten. `variables` is not decorative:
  stage 1 adds `"stage_description"` to it and the prompt-template admin UI
  lists that field, so a content-only rewrite would leave the row's declared
  variable list stale and disagreeing with its own body.

  Force-update pattern taken verbatim from
  `20260727183000_force_update_planning_template_drop_ack.exs`: look the row up
  by slug, `:skip` when absent (first boot is `seed_defaults/0`'s job),
  otherwise rewrite `content` from `default_content_for_slug/1` and `variables`
  from the shipped descriptor. Environments already matching see a changeset
  no-op. `down/0` is `:ok` — reinstating a dispatch body that drops the
  planner's specification is not a state worth being able to restore.
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
