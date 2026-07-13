defmodule Platform.Repo.Migrations.AddParentPlansSectionToDispatchPlanning do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Force-updates the seeded `dispatch.planning` prompt template with the
  new `{{upstream_plans_section}}` variable (task
  `019f487e-25e6-7e53-8968-802a2b76302f` — Stack v2 stage 5).

  Stack members' planner dispatches now receive an `Upstream plans
  (approved by dep parents)` section describing each in-stack
  `blocks`-kind parent's approved plan, so downstream planning aligns
  with upstream design decisions instead of independently reinventing
  them. Solo tasks pass an empty `upstream_plans_section` assign so the
  section renders as nothing — backwards-compatible.

  Force-update pattern (same as `20260506173000` and
  `20260711010000`): re-write the template body to the current
  `default_content_for_slug/1` output. Environments where the row is
  absent are skipped (`seed_defaults/0` handles those on first boot).
  Environments where the live row already matches see a changeset
  no-op.
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
