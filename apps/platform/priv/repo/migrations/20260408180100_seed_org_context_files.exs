defmodule Platform.Repo.Migrations.SeedOrgContextFiles do
  use Ecto.Migration

  @doc """
  Seed default org context files on first boot.
  Idempotent — only inserts missing file keys.
  """
  def up do
    Platform.Org.Seeds.seed_defaults()
  end

  def down do
    :ok
  end
end
