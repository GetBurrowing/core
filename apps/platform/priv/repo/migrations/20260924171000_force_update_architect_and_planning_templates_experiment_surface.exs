defmodule Platform.Repo.Migrations.ForceUpdateArchitectAndPlanningTemplatesExperimentSurface do
  use Ecto.Migration

  @moduledoc """
  Task `01a0d41e` stage 2 (ADR-0046 Amendment 2,
  `0046-design-and-architecture-phases-in-planning.md`): `dispatch.planning`
  gains `PromptTemplates.planning_experiment_surface_notice/0`, the planner's
  half of the architect's `experiment_surface` constraint.

  `seed_defaults/0` is INSERT-only, so the descriptor edit alone reaches no
  existing deployment. This writes `default_content_for_slug/1` for all three
  rows the task changes. `architecture.review_plan.v1` and
  `architecture.audit_diff.v1` were ALREADY force-updated by stage 1's
  `20260924170000_force_update_architect_templates_experiment_surface.exs`;
  they are listed again deliberately, not by accident — the write is
  idempotent, and keeping all three here makes this the last force-update for
  every row the task touches, so a later reader has one migration to check.

  Live rows were read on both installs (fabrikam `core_platform`, milv
  `milv_platform`) on 2026-09-24 before this was written, and diffed against
  the origin/main descriptors (df64ae47):

  - `architecture.review_plan.v1` (md5 dddc47d314abd5c811e90084c7c73318) and
    `architecture.audit_diff.v1` (md5 b5bd4742816caf8c8f9b64bc93d6592a)
    matched the descriptor exactly on both installs.
  - `dispatch.planning` did NOT: both installs carried md5
    94f8aee137625d14de80c131aedf888e against the descriptor's
    bfdc01df09cbc9b904d9004da3420108. The difference is a 2026-09-10 hand
    edit (prompt_template_update, updated_by `dalton`) adding the
    `## CI evidence: what actually triggers a run (verified 2026-09-11)`
    section, plus a missing trailing newline. This change folds that section
    into the descriptor byte-for-byte
    (`PromptTemplates.planning_ci_evidence_section/0`), so the force-update
    preserves it instead of deleting it.

  No running experiment targets any of the three slugs on either install.

  Same shape as `20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10.exs`:
  the body is read from the descriptor rather than frozen here, and slugs
  with no DB row are skipped (fresh boots pick them up via `seed_defaults/0`).
  """

  @slugs [
    "architecture.review_plan.v1",
    "architecture.audit_diff.v1",
    "dispatch.planning"
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
