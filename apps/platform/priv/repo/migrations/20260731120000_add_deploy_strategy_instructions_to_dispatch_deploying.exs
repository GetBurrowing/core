defmodule Platform.Repo.Migrations.AddDeployStrategyInstructionsToDispatchDeploying do
  use Ecto.Migration

  @slug "dispatch.deploying"

  @moduledoc """
  Force-updates the `dispatch.deploying` prompt template so it carries the
  `{{deploy_strategy_instructions}}` placeholder (task 019fa63a stage 5).

  WHY A MIGRATION AND NOT JUST THE CODE EDIT. `PromptTemplates.seed_defaults/0`
  is INSERT-only — it skips any slug whose row already exists. Every
  environment that has booted once already holds a `dispatch.deploying` row
  written by `20260326190000_seed_deploying_prompt_template.exs`. Editing
  `do_default_templates/0` changes only the FALLBACK used when the row is
  ABSENT, so a code-only change here would be a no-op deploy: green CI, a
  published image, and production still rendering the old body forever. Two
  tasks proved this end-to-end in July (`019fa469`, `019fa504`).

  WHAT CHANGES IN THE BODY. The `### Strategy-specific instructions` section
  used to be a STATIC four-line summary of every deploy strategy, ending in
  "Follow the instructions for **{{deploy_strategy_type}}** above." Its
  `pr_merge` line named exactly one PR and one merge. That is the dispatch half
  of the bug this task exists to fix: a task whose work spans two repositories
  was told to open one PR, and read the one `pr_merged` gate that passed as a
  finished deploy.

  The section now interpolates the RESOLVED strategy's own instructions, which
  `HeartbeatScheduler.deploy_strategy_instructions/5` builds from
  `Tasks.repos_from_strategy/2` — one PR/CI/merge sequence per repository, each
  keyed on that repository's own `ci` state, plus an explicit statement that the
  stage does not complete until every repository's gate passes. It is the same
  function the hardcoded fallback calls, so the templated and fallback dispatch
  paths can no longer drift (they had already: the body's static summary was
  never updated when `project_files` and `no_op_wait_for_rollup` were added).

  `repo_url` and `default_branch` KEEP their names and their places in the
  variable list. They are not a second source of truth — `repo_url` now
  resolves to the PRIMARY entry of the same repo set — so a row an operator
  customized to interpolate `{{repo_url}}` keeps rendering, and renders the
  right repository. Dropping them would have blanked such rows silently, since
  `PromptTemplates.interpolate/2` resolves an unknown placeholder to `""`.

  Force-update pattern follows
  `20260719120100_add_migration_slot_section_to_dispatch_in_progress.exs`:
  re-write the row body from the current `default_content_for_slug/1` output and
  refresh `variables`. Absent row → `:skip` (`seed_defaults/0` handles first
  boot). Already-matching row → changeset no-op.
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
