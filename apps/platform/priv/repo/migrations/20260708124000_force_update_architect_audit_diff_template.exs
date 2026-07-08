defmodule Platform.Repo.Migrations.ForceUpdateArchitectAuditDiffTemplate do
  use Ecto.Migration

  # ADR-0044 stage 4 (task `019f3da3`): the stage-1 placeholder body for
  # `architecture.audit_diff.v1` was seeded by
  # `20260708120100_seed_prompt_templates_architect.exs`. Stage 4 ships
  # the real prompt via `Platform.Orchestration.PromptTemplates.do_default_templates/0`,
  # but `seed_defaults/0` is INSERT-only — a deployment that already ran
  # the stage-1 migration would keep serving the placeholder body
  # without an explicit overwrite. Force-update to
  # `default_content_for_slug/1`'s current output.
  #
  # Skips slugs with no DB row (fresh boots pick them up via
  # `seed_defaults/0`). Mirrors the stage-3 sibling migration at
  # 20260708123000 and the earlier `force_update_*` pattern at
  # 20260520010000.

  @slug "architecture.audit_diff.v1"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: content,
              variables: ["stage_diff", "planned_shape", "org_memory_entries"],
              name: "Architecture Audit — Post-executor drift"
            })
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
