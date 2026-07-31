defmodule Platform.Repo.Migrations.ForceUpdateArchitectAuditDiffAuditTool do
  use Ecto.Migration

  @slug "architecture.audit_diff.v1"

  @moduledoc """
  Force-updates the `architecture.audit_diff.v1` prompt template so the
  deployed row names `stage_architecture_audit` (task `019fa61c` stage 3).

  Until this task there WAS no tool to name. The body's `## Output shape`
  section said "post one annotation per concern to the task's execution
  space" and named no tool and no stage id — an instruction to produce a
  side effect the agent was never told how to perform. Its sibling
  `architecture.review_plan.v1` names `plan_architecture_verdict`, which
  writes `plans.architecture_verdict`, and that is the entire reason one
  architect surface is observable and the other left 28 fires in a
  3.3-hour window with no evidence anywhere. Stages 1 and 2 built the row;
  stage 3 built the tool. Naming it in the prompt is the third leg, and
  the row is what the deployed architect actually renders.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to
  `do_default_templates/0`. `PromptTemplates.seed_defaults/0` is
  INSERT-only (skip-if-exists), and `20260708120100_seed_prompt_templates_architect.exs`
  already claimed this slug on every migrated environment, so the
  default-function edit alone would reach nothing but the in-memory
  fallback: the PR would merge, CI would go green, the image would
  publish, and every deployed architect would keep reading the tool-less
  body. Proved end to end twice this cycle — task `019fa469` on
  2026-07-27 (prod still held the defective `dispatch.planning` text after
  a green run and a published image, and only
  `20260727183000_force_update_planning_template_drop_ack.exs` moved it)
  and task `019fa504` (`20260727210000_force_update_design_task_direction_decline.exs`),
  whose shape this migration copies.

  `variables` ARE rewritten here, unlike the 019fa504 precedent: this
  stage adds a real interpolation slot. `stage_architecture_audit`'s only
  required lookup argument is `stage_id`, and a prompt that names a tool
  without printing the argument it needs is the same defect one level
  down. The list is written explicitly rather than read back from
  `default_templates/0` so a later reshuffle of that function cannot
  silently rewrite a deployed row's variable list as a side effect.

  Both `nil` branches skip: an environment with no row picks the body up
  from `seed_defaults/0` on first boot, and a build whose defaults no
  longer carry the slug must not be papered over with a `nil` content
  write.

  `down/0` is a no-op. Reverting would put the architect back to being
  asked for an audit with no way to land one — the exact state this task
  exists to end.
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
            {:ok, _} =
              PromptTemplates.update_template(template, %{
                content: content,
                variables: ["stage_diff", "planned_shape", "org_memory_entries", "stage_id"]
              })
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
