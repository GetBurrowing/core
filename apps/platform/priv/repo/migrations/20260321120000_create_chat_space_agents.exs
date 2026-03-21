defmodule Platform.Repo.Migrations.CreateChatSpaceAgents do
  use Ecto.Migration

  def change do
    create table(:chat_space_agents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:role, :string, null: false, default: "member")
      add(:dismissed_by, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:dismissed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:chat_space_agents, [:space_id, :agent_id],
        name: :chat_space_agents_space_agent_unique
      )
    )

    # Exactly one principal per space
    create(
      unique_index(:chat_space_agents, [:space_id],
        where: "role = 'principal'",
        name: :chat_space_agents_principal_unique
      )
    )
  end
end
