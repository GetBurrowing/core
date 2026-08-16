defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleContent do
  use Ecto.Migration

  @moduledoc """
  Force-updates the `federation.preamble` prompt template row so the served
  preamble carries the new "Execution posture — close the ticket" section
  (task 01a00c99 stage 4).

  THIS MIGRATION IS THE DELIVERABLE, not the edit to `@federation_preamble`.
  `PromptTemplates.seed_defaults/0` is INSERT-only (skip-if-exists), so every
  environment that has ever booted already holds the row. Since stage 2,
  `federation_preamble/0` PREFERS that row and only falls back on the
  constant, so an attribute-only edit would reach no deployed dispatch: CI
  would go green against the constant while roughly fifteen `dispatch.*`
  templates kept rendering the old text.

  ## Content is read from the descriptor, not frozen as a literal

  Unlike `20260812190000_force_update_planning_template_branch_push_rule`,
  this migration calls `PromptTemplates.default_content_for_slug/1`. The
  invariant this stack maintains is `row.content ==
  PromptTemplates.federation_preamble()` — the row and the fallback must never
  disagree, and that is pinned by tests. A frozen literal would be a second
  copy of a ~5 KB block that a later attribute edit could silently diverge
  from, breaking that pin at deploy time rather than at edit time. Reading the
  descriptor makes the equality structural.

  ## Force-update, unconditionally

  The update is guarded only by row existence (zero rows is a no-op, not an
  error — `seed_defaults/0` owns first boot). It is NOT conditional on whether
  an operator edited the row through the admin form, and it therefore
  overwrites such an edit. That cost is accepted deliberately: the suite pins
  the row against the constant, so a "skip if edited" branch would leave an
  edited row permanently failing that pin with no signal to anyone. Every
  prior template fix in this tree took the same force-update path.

  `down/0` is an explicit no-op. The prior body differs only by the absence of
  the posture section; returning to it is not a state worth restoring.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.PromptTemplates

  @slug "federation.preamble"

  def up do
    content = PromptTemplates.default_content_for_slug(@slug)

    if is_binary(content) and String.trim(content) != "" do
      Platform.Repo.update_all(
        from(t in "prompt_templates", where: t.slug == ^@slug),
        set: [content: content, updated_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  def down do
    :ok
  end
end
