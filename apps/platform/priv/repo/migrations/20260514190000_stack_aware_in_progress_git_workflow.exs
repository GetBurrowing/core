defmodule Platform.Repo.Migrations.StackAwareInProgressGitWorkflow do
  use Ecto.Migration

  @moduledoc """
  Refreshes the persisted `dispatch.in_progress` prompt template so an upgraded
  DB renders identically to a fresh one.

  Task `019e2790` makes the Git Workflow section stack-aware: the static
  `{{task_slug}}`-based worktree/branch lines are replaced by a single
  pre-rendered `{{git_workflow_block}}` variable (built by
  `HeartbeatScheduler.git_workflow_section/1`, which emits a full-UUID
  worktree/branch + Task Stack Membership block for stack members, and the
  legacy 8-char-slug section for non-stack tasks).

  Both the template `content` and its `variables` list change, so this
  force-updates the existing row (NOT `seed_defaults` — that path is
  insert-only and ignores existing rows; see task `019df9cb`).
  """

  @slug "dispatch.in_progress"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
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
