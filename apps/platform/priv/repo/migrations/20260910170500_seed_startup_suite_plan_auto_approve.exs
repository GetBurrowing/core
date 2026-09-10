defmodule Platform.Repo.Migrations.SeedStartupSuitePlanAutoApprove do
  use Ecto.Migration

  @moduledoc """
  Task 01a08c1e stage 2: arm the project-level plan auto-approval policy
  on the `startup-suite` project (enabled, at most 5 implementation
  stages, no manual_approval gate). `Platform.Tasks.maybe_auto_approve/1`
  reads `projects.config["plan_auto_approve"]`; `Project.changeset/2`
  validates the same shape on every later `project_update`.

  No-op when the row is absent (fresh boots, the test DB). `down` removes
  only this key and leaves the rest of `config` intact.
  """

  @policy ~s({"plan_auto_approve":{"enabled":true,"max_stages":5,"allow_manual_approval":false}})

  def up do
    execute("""
    UPDATE projects
    SET config = coalesce(config, '{}'::jsonb) || '#{@policy}'::jsonb
    WHERE slug = 'startup-suite'
    """)
  end

  def down do
    execute("""
    UPDATE projects
    SET config = coalesce(config, '{}'::jsonb) - 'plan_auto_approve'
    WHERE slug = 'startup-suite'
    """)
  end
end
