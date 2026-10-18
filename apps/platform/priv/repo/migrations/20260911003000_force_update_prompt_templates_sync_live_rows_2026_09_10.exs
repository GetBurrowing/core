defmodule Platform.Repo.Migrations.ForceUpdatePromptTemplatesSyncLiveRows20260910 do
  use Ecto.Migration

  @moduledoc """
  PR #995. On 2026-09-10 five `prompt_templates` rows were patched directly in the
  database on both installs (install A and install B): `dispatch.planning`,
  `dispatch.review_e2e`, `federation.preamble`, `nudge`, `dispatch.deploying`.
  The sibling change to `do_default_templates/0` makes each descriptor
  byte-identical to the patched row.

  `seed_defaults/0` is INSERT-only, so the descriptor edit alone reaches no
  existing deployment — and a FRESH install serves whatever the LAST
  force-update migration for a slug wrote, not the descriptor, because the
  earlier force-update migrations (2026-07-31 through 2026-08-16) rewrite
  these rows after the seed runs. This migration is that last one: it writes
  `default_content_for_slug/1` for each of the five slugs, which also
  collapses the install A/install B drift on `dispatch.planning` (one install carried a
  trailing newline the other did not).

  Same shape as `20260908235900_force_update_architect_review_plan_plan_level_finding`:
  the body is read from the descriptor rather than frozen here, and slugs
  with no DB row are skipped (fresh boots pick them up via `seed_defaults/0`).
  """

  @slugs [
    "dispatch.planning",
    "dispatch.review_e2e",
    "federation.preamble",
    "nudge",
    "dispatch.deploying"
  ]

  def slugs, do: @slugs

  def up do
    alias Platform.Orchestration.PromptTemplates

    for slug <- @slugs do
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          :skip

        template ->
          case PromptTemplates.default_content_for_slug(slug) do
            nil ->
              :skip

            content ->
              {:ok, _} = PromptTemplates.update_template(template, %{content: content})
          end
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
