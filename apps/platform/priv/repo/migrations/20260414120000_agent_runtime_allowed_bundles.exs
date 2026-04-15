defmodule Platform.Repo.Migrations.AgentRuntimeAllowedBundles do
  use Ecto.Migration

  @all_bundles ~w(federation space context_read messaging review canvas task plan org_context)

  def up do
    alter table(:agent_runtimes) do
      remove(:capabilities)

      add(:allowed_bundles, {:array, :string},
        null: false,
        default: ["federation", "space", "context_read", "messaging"]
      )
    end

    execute("UPDATE agent_runtimes SET allowed_bundles = '{#{Enum.join(@all_bundles, ",")}}'")
  end

  def down do
    alter table(:agent_runtimes) do
      remove(:allowed_bundles)
      add(:capabilities, :map, default: "[]")
    end
  end
end
