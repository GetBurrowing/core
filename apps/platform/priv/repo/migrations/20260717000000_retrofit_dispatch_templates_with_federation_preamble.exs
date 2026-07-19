defmodule Platform.Repo.Migrations.RetrofitDispatchTemplatesWithFederationPreamble do
  use Ecto.Migration

  @slugs ~w(
    dispatch.planning
    dispatch.in_progress
    dispatch.in_review
    dispatch.review_e2e
    dispatch.deploying
    dispatch.fallback
  )

  @moduledoc """
  Force-updates the six Claude Code dispatch prompt templates so every
  runtime dispatch in prod consumes the consolidated `{{federation_preamble}}`
  placeholder introduced in task 019f5e2a stage 1 (of the
  meeting-to-tasks-pipeline stack).

  Previously each `dispatch.*` template inlined its own copies of the
  Organization Context, Writing to Org Memory, Skill discovery, and Evidence
  workflow blocks — three near-identical maintenance sites competing to
  drift out of sync (see the churn history from tasks 019f6c73 /
  019f6791 / 019f640d). Stage 3 replaces those inline blocks with a single
  `{{federation_preamble}}` mustache placeholder that resolves at render
  time from `PromptTemplates.federation_preamble/0`, and updates each
  descriptor's `variables:` list to declare the new placeholder (and drop
  the retired `skills_reference` / `evidence_workflow_reference` entries).

  Force-update pattern mirrors `20260716211312_refresh_dispatch_templates_subagent_id_ack`
  and earlier refresh migrations: re-write each template row's content and
  variables to the current descriptor. Rows that don't yet exist are
  skipped (`seed_defaults/0` handles those on first boot); rows already
  matching the new descriptor see a changeset no-op. `down` is a no-op —
  the retrofit is forward-only; a rollback would re-introduce the exact
  duplication this migration eliminates.

  Explicitly does NOT touch:
  * `heartbeat` — deprecated legacy nudge slug, not a Claude Code dispatch
    surface.
  * `nudge` — short-form safety-net dispatch, intentionally lean (<500
    tokens); the federation preamble would blow past that budget.
  * `historian.*` / `architecture.*` / `stacks.*` — role-specific dispatch
    templates that don't need Claude Code federation guidance.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    for slug <- @slugs do
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          :skip

        %PromptTemplate{} = template ->
          descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

          if descriptor do
            attrs = %{content: descriptor.content, variables: descriptor.variables}

            case PromptTemplates.update_template(template, attrs) do
              {:ok, _} -> :ok
              {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
            end
          else
            :skip
          end
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
