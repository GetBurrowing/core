defmodule Platform.Repo.Migrations.ForceUpdateDesignTaskDirectionDecline do
  use Ecto.Migration

  @slug "design.task_direction.v1"

  @moduledoc """
  Force-updates the `design.task_direction.v1` prompt template so the deployed
  row names the decline exit (task `019fa504` stage 3, ADR-0046 member 7).

  Until stages 1 and 2 of this task there WAS no second exit: the body's
  `## Delivery` section named exactly one thing to do — write a canvas and
  attach it with `task_attach_canvas` — because attaching a canvas was the only
  way to close the step. Stage 1 added `PreplanStep.decline/3` and stage 2
  exposed it as the `task_design_decline` MCP tool in the `task` bundle, which
  is the same bundle `task_attach_canvas` already lives in. That makes the exit
  PRESENT and reachable. It does not make it USED: a designer who is told to do
  one thing and holds a tool nobody mentioned will still attach a canvas she
  does not believe in, or go silent and burn the 30-minute deadline into a
  `failed` step. Naming the exit in the prompt is the third leg.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to `do_default_templates/0`.
  `PromptTemplates.seed_defaults/0` is INSERT-only (skip-if-exists) and
  `20260726051346_seed_design_task_direction.exs` already claimed this slug on
  every migrated environment, so the default-function edit alone would reach
  nothing but the fallback: the PR would merge, CI would go green, the image
  would publish, and every deployed designer would keep reading the one-exit
  body. Task `019fa469` proved that end to end on 2026-07-27 — prod still held
  the defective `dispatch.planning` text after a green run and a published
  image, and only `20260727183000_force_update_planning_template_drop_ack.exs`
  moved it.

  Force-update shape taken from that migration and from
  `20260726051347_force_update_dispatch_planning_design_preplan.exs`:
  rewrite `content` from `default_content_for_slug/1`. `variables` are NOT
  rewritten — this stage adds no interpolation, the three slots
  (`task_summary`, `brand_context`, `attached_canvases`) are unchanged, and a
  gratuitous write there would put churn in a column a reviewer has to diff.
  Both `nil` branches skip: an environment with no row picks the body up from
  `seed_defaults/0` on first boot, and a build whose defaults no longer carry
  the slug must not be papered over with a `nil` content write.

  `down/0` is a no-op. Reverting would re-remove the only non-canvas exit from
  the designer's instructions, leaving the tool shipped but unnamed — the exact
  state this task exists to end.
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        case PromptTemplates.default_content_for_slug(@slug) do
          nil ->
            :skip

          content ->
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
