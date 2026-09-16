defmodule Platform.Repo.Migrations.SeedMemoryDailySummaryPrompt do
  use Ecto.Migration

  @slug "memory.daily_summary.v1"

  @moduledoc """
  Seeds (or refreshes) the `memory.daily_summary.v1` prompt template so the
  23:00 UTC `memory.daily_summary` cron fire stops dispatching an empty body.

  Task `01a0a74d` stage 2. Stage 1 measured the gap at `origin/main` sha
  `f8e0d6392e7d9874a2040dc3f574654518d90add`: the slug named by
  `Platform.Responsibilities.Handlers.DailySummary.register/0` as its
  `default_prompt_template` had no row, so
  `Responsibilities.Router.render_default_template/2` returned
  `{:absent, {:template_missing, "memory.daily_summary.v1"}}` and the
  native dispatch went out stamped `prompt_status: :render_gap` — an
  empty prompt reaching the one agent with write access to org-wide
  pages, which is an invitation to invent a day nobody observed.

  ## Why a migration and not just the descriptor

  `PromptTemplates.seed_defaults/0` is INSERT-only and skips environments
  that have already been seeded, so adding the entry to
  `do_default_templates/0` alone fixes fresh databases and leaves every
  live install exactly as broken. The router's own `:template_missing`
  warning says as much. This migration is the half that reaches a live
  install.

  Shape mirrors `20260718230000_seed_dreaming_prompt_dual_slug.exs`:
  insert-or-force-update, reading the body from
  `PromptTemplates.default_content_for_slug/1` and the name/description/
  variables from the matching `default_templates/0` descriptor, so the row
  and the source of truth cannot drift. The descriptor is required, not
  optional — a missing one means `do_default_templates/0` lost the entry
  and silently writing nothing would restore the defect this migration
  exists to remove, so it raises.

  ## No `down/0` revert

  `def down, do: :ok`, as in the precedent. Dropping the row on rollback
  re-creates the render gap, and the gap is silent: nothing errors, the
  dispatch just goes out empty. A rollback that reopens a silent defect is
  worse than one that leaves a prompt row behind.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedMemoryDailySummaryPrompt] no default descriptor for slug=#{@slug} — " <>
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
