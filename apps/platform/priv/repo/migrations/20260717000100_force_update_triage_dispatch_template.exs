defmodule Platform.Repo.Migrations.ForceUpdateTriageDispatchTemplate do
  use Ecto.Migration

  @moduledoc """
  Force-updates the persisted `dispatch.triage_dispatch` prompt template so an
  upgraded DB renders the real triage-officer body (task 019f5e2b stack member
  M4 Stage 2), not the Stage 1 stub.

  Stage 1 shipped a placeholder body ("dispatch.triage_dispatch template stub
  — filled in Stage 2.") seeded via the insert-only
  `PromptTemplates.seed_defaults/0` path. `seed_defaults/0` skips rows that
  already exist, so on any DB where the Stage 1 seed migration already ran
  (dev, staging, prod) the stub row is now stale — the seed path cannot
  rewrite it. This force-update migration is the escape hatch: it re-writes
  the persisted row's `content` (and `variables`, in case the descriptor's
  declared list has evolved) to the current `default_content_for_slug/1`
  output.

  Mirrors the shape of `20260514190000_stack_aware_in_progress_git_workflow`
  and the more recent `20260716211312_refresh_dispatch_templates_subagent_id_ack`
  refresh migrations: nil row → :skip (fresh DBs pick up the current body via
  seed_defaults/0 on next boot), existing row → update to descriptor content
  + variables. Down: no-op.
  """

  @slug "dispatch.triage_dispatch"

  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      %PromptTemplate{} = template ->
        descriptor =
          PromptTemplates.default_templates()
          |> Enum.find(&(&1.slug == @slug))

        if descriptor do
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: descriptor.content,
              variables: descriptor.variables
            })
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
