defmodule Platform.Repo.Migrations.SeedTriageDispatchTemplate do
  use Ecto.Migration

  @moduledoc """
  Re-run seed_defaults to insert the dispatch.triage_dispatch template on
  existing deployments where prior seed migrations ran before the triage
  template existed. Idempotent — only inserts missing slugs.

  Stage 2 of task 019f5e2b (meeting-to-tasks pipeline stack member M4) adds a
  force-update migration once the real body lands; seed_defaults() is
  insert-only and won't rewrite the Stage 1 stub.
  """
  def up do
    Platform.Orchestration.PromptTemplates.seed_defaults()
  end

  def down do
    :ok
  end
end
