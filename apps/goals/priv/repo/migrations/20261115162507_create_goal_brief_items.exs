defmodule Platform.Repo.Migrations.CreateGoalBriefItems do
  @moduledoc "Goals 6/8, task 01a1dfc1-abcc: module-owned daily delivery, ADR 0055 section 6."
  use Ecto.Migration

  # old-code-compatible: creates the new goal_brief_items table only; no existing table changes and the previous release reads none of it
  def change do
    create table(:goal_brief_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:digest_date, :date, null: false)
      add(:kind, :string, null: false)
      add(:ask_id, references(:goal_asks, type: :binary_id, on_delete: :delete_all))
      add(:entry_ids, {:array, :binary_id}, null: false, default: [])
      add(:since_at, :utc_datetime_usec)
      add(:through_at, :utc_datetime_usec)
      add(:noted_at, :utc_datetime_usec)
      add(:ignored_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:goal_brief_items, :goal_brief_items_kind, check: "kind IN ('report', 'ask')")
    )

    create(
      constraint(:goal_brief_items, :goal_brief_items_shape,
        check: "(kind = 'ask') = (ask_id IS NOT NULL)"
      )
    )

    create(unique_index(:goal_brief_items, [:user_id, :ask_id], where: "ask_id IS NOT NULL"))

    create(
      unique_index(:goal_brief_items, [:user_id, :goal_id, :digest_date],
        where: "kind = 'report'"
      )
    )

    create(index(:goal_brief_items, [:user_id, :digest_date]))
  end
end
