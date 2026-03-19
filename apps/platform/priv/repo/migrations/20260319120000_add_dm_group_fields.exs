defmodule Platform.Repo.Migrations.AddDmGroupFields do
  use Ecto.Migration

  def change do
    alter table(:chat_spaces) do
      add(:is_direct, :boolean, default: false, null: false)

      add(:created_by, references(:users, type: :binary_id, on_delete: :nilify_all), null: true)
    end

    # Make slug and name nullable for DM/group spaces
    execute(
      "ALTER TABLE chat_spaces ALTER COLUMN slug DROP NOT NULL",
      "ALTER TABLE chat_spaces ALTER COLUMN slug SET NOT NULL"
    )

    execute(
      "ALTER TABLE chat_spaces ALTER COLUMN name DROP NOT NULL",
      "ALTER TABLE chat_spaces ALTER COLUMN name SET NOT NULL"
    )
  end
end
