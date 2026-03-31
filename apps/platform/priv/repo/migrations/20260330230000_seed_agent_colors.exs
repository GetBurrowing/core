defmodule Platform.Repo.Migrations.SeedAgentColors do
  use Ecto.Migration

  def up do
    # Set default colors for known agents by slug
    # Builder → purple, Pixel → orange, Beacon → brick red (as per design comp)
    execute "UPDATE agents SET color = 'purple' WHERE slug = 'builder' AND color IS NULL;"
    execute "UPDATE agents SET color = 'orange' WHERE slug = 'pixel' AND color IS NULL;"
    execute "UPDATE agents SET color = 'brick' WHERE slug = 'beacon' AND color IS NULL;"
  end

  def down do
    execute "UPDATE agents SET color = NULL WHERE slug IN ('builder', 'pixel', 'beacon');"
  end
end
