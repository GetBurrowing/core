defmodule Platform.Repo.Migrations.SeedPromptTemplates do
  use Ecto.Migration

  def up do
    Platform.Orchestration.PromptTemplates.seed_defaults()
  end

  def down do
    # No-op: we don't want to delete user-edited templates on rollback
    :ok
  end
end
