defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropAck do
  use Ecto.Migration

  @slug "dispatch.planning"

  @moduledoc """
  Force-updates the `dispatch.planning` prompt template so the deployed row
  stops instructing an ack that cannot succeed (task 019fa469 stage 5).

  The row told every planner `**Your first tool call must be
  task_ack(task_id="...", stage_id="", ...)**`. A planning dispatch has no plan
  and therefore no `status == "running"` stage, so
  `ToolSurface.resolve_ack_stage_id/2` returns `{:error, :no_running_stage}`
  and the runtime is answered with `task_id=<id> has no running stage — cannot
  ack without a stage_id.` The documented escape hatch, `alarm_silence`, fails
  through the same resolver. Nothing was lost by the failure either:
  `TaskRouter.arm_liveness_timers/3` has the clause
  `arm_liveness_timers(_task_id, nil, _stage_kind), do: :ok`, so a stage-less
  dispatch arms no `:check_no_ack` and no `:check_safety_net` timer and never
  calls `LeaseManager.record_dispatch/4`. There was no alarm for the ack to
  satisfy — only a first tool call guaranteed to fail.

  THIS MIGRATION IS THE DELIVERABLE, not the edit to `do_default_templates/0`.
  `PromptTemplates.seed_defaults/0` is INSERT-only (skip-if-exists), so every
  environment that has ever booted already has this row and the default-function
  edit alone would reach nothing: the PR would merge, CI would go green, and
  prod would keep serving the old string.

  Force-update pattern taken verbatim from
  `20260716211312_refresh_dispatch_templates_subagent_id_ack.exs`: rewrite
  `content` from `default_content_for_slug/1` and `variables` from the shipped
  descriptor (this stage drops `stage_id`, which nothing interpolates any
  more). Environments where the row is absent are skipped — `seed_defaults/0`
  handles those on first boot. Environments already matching see a changeset
  no-op.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      %PromptTemplate{} = template ->
        content = PromptTemplates.default_content_for_slug(@slug)
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
        variables = (descriptor && descriptor.variables) || template.variables

        case PromptTemplates.update_template(template, %{content: content, variables: variables}) do
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
