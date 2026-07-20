defmodule Platform.Repo.Migrations.AddMigrationSlotSectionToDispatchInProgress do
  use Ecto.Migration

  @slug "dispatch.in_progress"

  @moduledoc """
  Force-updates the `dispatch.in_progress` prompt template so it carries the
  `{{migration_slot_section}}` placeholder (task 019f7b7e stage 3).

  Stage 2 reserves a per-stack Ecto migration timestamp at plan-approval time
  and stashes it on `task.metadata["reserved_migration_slots"]`. That
  reservation is inert unless the executor actually SEES it, which is what
  this placeholder does: `HeartbeatScheduler.render_migration_slot_section/2`
  resolves it to a "Reserved migration timestamp" block for stack members
  whose current stage holds a reservation, and to an empty string for
  everyone else.

  The placeholder sits immediately before `{{git_workflow_block}}` so the
  reserved timestamp is read before the executor is told how to branch and
  commit.

  Retrofit safety: the assign always renders (empty string when there is no
  reservation), so existing solo tasks and stack members without a migration
  stage see byte-identical prompts to before.

  Force-update pattern is the same as
  `20260715000000_add_task_ack_preamble_to_dispatch_templates.exs` — re-write
  the row body from the current `default_content_for_slug/1` output and
  refresh the `variables` list. Environments where the row is absent are
  skipped; `seed_defaults/0` handles those on first boot. Environments whose
  live row already matches see a changeset no-op.
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
