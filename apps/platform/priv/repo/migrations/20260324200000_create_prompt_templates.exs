defmodule Platform.Repo.Migrations.CreatePromptTemplates do
  use Ecto.Migration

  def change do
    create table(:prompt_templates, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:slug, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:content, :text, null: false)
      add(:variables, {:array, :string}, default: [])
      add(:updated_by, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:prompt_templates, [:slug]))
  end
end
