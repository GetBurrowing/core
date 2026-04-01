defmodule Platform.Repo.Migrations.AddAvatarMetadataToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add_if_not_exists(:avatar_url, :string)
      add_if_not_exists(:avatar_source, :string)
    end
  end
end
