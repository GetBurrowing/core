defmodule Platform.Repo.Migrations.AddGoalRetroAndPacing do
  @moduledoc "Goals retro storage, task 01a1dfc2-0d97; ADR 0055 section 6."
  use Ecto.Migration

  # old-code-compatible: adds nullable columns and widens two CHECK lists on goal tables; every value the previous release writes stays valid and it reads none of the new columns
  def up do
    alter(table(:goals), do: add(:retro_every, :integer))

    create(
      constraint(:goals, :goals_retro_every,
        check: "retro_every IS NULL OR retro_every BETWEEN 2 AND 60"
      )
    )

    alter(table(:goal_clocks), do: add(:paced_at, :utc_datetime_usec))
    drop(constraint(:goal_wake_ups, :goal_wake_ups_outcome))

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_outcome,
        check: "outcome IS NULL OR outcome IN ('do', 'ask', 'wait', 'retro')"
      )
    )

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_retro_outcome,
        check: "outcome IS NULL OR (outcome = 'retro') = (kind = 'retro')"
      )
    )

    alter(table(:goal_brief_items),
      do: add(:entry_id, references(:goal_entries, type: :binary_id, on_delete: :delete_all))
    )

    drop(constraint(:goal_brief_items, :goal_brief_items_kind))

    create(
      constraint(:goal_brief_items, :goal_brief_items_kind,
        check: "kind IN ('report', 'ask', 'note')"
      )
    )

    create(
      constraint(:goal_brief_items, :goal_brief_items_note_shape,
        check: "(kind = 'note') = (entry_id IS NOT NULL)"
      )
    )

    create(unique_index(:goal_brief_items, [:user_id, :entry_id], where: "entry_id IS NOT NULL"))
  end

  def down do
    execute("DELETE FROM goal_brief_items WHERE kind = 'note'")
    drop(index(:goal_brief_items, [:user_id, :entry_id]))
    drop(constraint(:goal_brief_items, :goal_brief_items_note_shape))
    drop(constraint(:goal_brief_items, :goal_brief_items_kind))

    create(
      constraint(:goal_brief_items, :goal_brief_items_kind, check: "kind IN ('report', 'ask')")
    )

    alter(table(:goal_brief_items), do: remove(:entry_id))
    execute("DELETE FROM goal_wake_ups WHERE outcome = 'retro'")
    drop(constraint(:goal_wake_ups, :goal_wake_ups_retro_outcome))
    drop(constraint(:goal_wake_ups, :goal_wake_ups_outcome))

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_outcome,
        check: "outcome IS NULL OR outcome IN ('do', 'ask', 'wait')"
      )
    )

    alter(table(:goal_clocks), do: remove(:paced_at))
    drop(constraint(:goals, :goals_retro_every))
    alter(table(:goals), do: remove(:retro_every))
  end
end
