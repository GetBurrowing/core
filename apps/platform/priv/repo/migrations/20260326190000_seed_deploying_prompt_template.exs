defmodule Platform.Repo.Migrations.SeedDeployingPromptTemplate do
  use Ecto.Migration

  @doc """
  Re-run seed_defaults to insert the dispatch.deploying template on existing
  deployments where the original seed migration ran before the deploying
  template existed. Idempotent — only inserts missing slugs.
  """
  def up do
    Platform.Orchestration.PromptTemplates.seed_defaults()
  end

  def down do
    :ok
  end
end
