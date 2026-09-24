defmodule Platform.Repo.Migrations.SeedExperimentsScientistPrompt do
  use Ecto.Migration

  @slug "experiments.scientist.v1"

  @moduledoc """
  Seeds (or refreshes) the `experiments.scientist.v1` prompt template: the
  user turn of the `experiments.scientist` cron responsibility
  (`Platform.Responsibilities.Handlers.ExperimentsScientist`). Task
  `01a0d415-b616-7001-b87d-bb5568a776d3` stage 5, the experimentation-layer
  ADR-0052 (`docs/decisions/0052-experimentation-layer.md`),
  which extends ADR-0048.

  The template carries the Scientist's loop, the reading rules (never a
  figure without its n; `insufficient_data` means not yet; stopping is not
  concluding; exclusions need a reason), the guardrails, and the instruction
  to answer a human's `stop_feedback` before proposing the next experiment.
  Launch approval is described as opt-in per org (Rowan, 2026-09-24): by
  default a start runs within the guardrails, and `pending_human_approval` is
  success where an org has turned approval on.

  ## Why a migration and not just the descriptor

  `PromptTemplates.render_template/2` prefers the seeded row, and
  `PromptTemplates.seed_defaults/0` is INSERT-only and never re-runs on an
  already-migrated install, so adding the entry to `do_default_templates/0`
  alone would reach fresh databases only. This migration is the half that
  reaches a live install.

  Shape mirrors `20260916103000_seed_memory_daily_summary_prompt.exs`:
  insert-or-force-update, reading the body and variables from the matching
  `default_templates/0` descriptor so the row and its source cannot drift. A
  missing descriptor raises rather than silently writing nothing.

  ## No `down/0` revert

  `def down, do: :ok`, as in the precedent. Dropping the row on rollback
  would leave the Scientist rendering from the in-code default only, which
  hides the rollback rather than undoing it.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedExperimentsScientistPrompt] no default descriptor for slug=#{@slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    attrs = %{
      slug: @slug,
      name: descriptor.name,
      description: descriptor.description,
      content: content,
      variables: descriptor.variables
    }

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        case PromptTemplates.create_template(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end

      %PromptTemplate{} = template ->
        case PromptTemplates.update_template(template, %{
               content: content,
               variables: descriptor.variables
             }) do
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
