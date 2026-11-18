defmodule Platform.Repo.Migrations.CreateGoalReadings do
  @moduledoc """
  Dated readings and the notebook's reading link (task 01a1dfc0-cce8).
  ADR 0055 section 6: module-owned tables reference stable core tables;
  core gains no reference to Goals.
  """
  use Ecto.Migration

  # old-code-compatible: creates the new goal_readings table and adds one nullable column to goal_entries; no core table changes and the previous release reads neither

  def change do
    create table(:goal_readings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:value, :decimal, null: false)
      add(:unit, :string)
      add(:source_key, :string, null: false)
      add(:population, :string, null: false)
      add(:origin, :string, null: false)
      add(:measured_at, :utc_datetime_usec, null: false)
      add(:note, :string)
      add(:details, :map, null: false, default: %{})
      add(:author_type, :string, null: false)
      add(:author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:author_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:goal_readings, [:goal_id, :measured_at]))

    create(
      constraint(:goal_readings, :goal_readings_origin,
        check: "origin IN ('manual', 'practice', 'measured')"
      )
    )

    create(
      constraint(:goal_readings, :goal_readings_author_type,
        check: "author_type IN ('user', 'agent')"
      )
    )

    alter table(:goal_entries) do
      add(:reading_id, references(:goal_readings, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:goal_entries, [:reading_id]))
  end
end
