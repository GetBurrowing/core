defmodule Platform.Repo.Migrations.CreateSkillsTables do
  use Ecto.Migration

  def change do
    # ── skills ─────────────────────────────────────────────────────────────────
    create table(:skills, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:content, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:skills, [:name]))
    create(unique_index(:skills, [:slug]))

    # ── skill_attachments ──────────────────────────────────────────────────────
    create table(:skill_attachments, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :skill_id,
        references(:skills, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:entity_type, :string, null: false)
      add(:entity_id, :binary_id, null: false)

      # Immutable — only inserted_at, no updated_at
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:skill_attachments, [:skill_id, :entity_type, :entity_id],
        name: :skill_attachments_unique_triple
      )
    )

    create(index(:skill_attachments, [:entity_type, :entity_id]))

    # CHECK constraint: entity_type must be one of project/epic/task
    create(
      constraint(:skill_attachments, :skill_attachments_entity_type_check,
        check: "entity_type IN ('project', 'epic', 'task')"
      )
    )
  end
end
