defmodule Platform.Repo.Migrations.SeedExperimentsLabelerPrompt do
  use Ecto.Migration

  @slug "experiments.labeler.v1"

  @moduledoc """
  Seeds (or refreshes) the `experiments.labeler.v1` prompt template: the
  system prompt of the blind signal labeler (`Platform.Experiments.Labeler`).
  Task `01a0d415-b616-7001-b87d-bb5568a776d3` stage 3, the
  experimentation-layer ADR-0052 (`docs/decisions/0052-experimentation-layer.md`), which extends ADR-0048.

  The template tells the model that the wrapped email is DATA TO CLASSIFY and
  never instructions, and fixes the closed JSON output shape the labeler
  parses.

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
  would leave the labeler rendering from the in-code default only, which
  hides the rollback rather than undoing it.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedExperimentsLabelerPrompt] no default descriptor for slug=#{@slug} — " <>
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
