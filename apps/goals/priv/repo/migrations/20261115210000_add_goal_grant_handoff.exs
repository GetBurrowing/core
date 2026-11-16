defmodule Platform.Repo.Migrations.AddGoalGrantHandoff do
  @moduledoc """
  The hand-off of a shared goal to a space's agents (task 01a1dfc1-dffb,
  Goals 7/8), stored on the space grant itself so a hand-off cannot outlive
  its grant: closing the goal to the space deletes the row and the hand-off
  with it.

  `0055-extension-contract-and-build-time-modules.md § 6. Migrations`: this
  alters only `goal_grants`, a Goals table, and references only stable core
  tables (`users`, `chat_canvases`) and Goals' own `goal_wake_ups`; core
  never references a `goal_*` table. Every column is nullable.

    * `handed_at` / `handed_by_user_id`: when and by whom the space's agents
      were given the goal; null means the goal is only shown there. The
      CHECK `goal_grants_handoff_only_space` keeps a hand-off on space
      grants only.
    * `card_canvas_id`: the goal card placed in the space (stage 5). A
      deleted canvas nils the column and keeps the grant (unlike Social's
      approval card, whose row cascades with its canvas).
    * `last_update_wake_up_id`, `last_update_at`, `last_update_number`: the
      last progress update posted into the space (stage 4).
  """

  use Ecto.Migration

  # old-code-compatible: adds nullable columns and one check to goal_grants, a Goals table; no core table changes and the previous release reads none of them

  def change do
    alter table(:goal_grants) do
      add(:handed_at, :utc_datetime_usec)
      add(:handed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(
        :card_canvas_id,
        references(:chat_canvases, type: :binary_id, on_delete: :nilify_all)
      )

      add(
        :last_update_wake_up_id,
        references(:goal_wake_ups, type: :binary_id, on_delete: :nilify_all)
      )

      add(:last_update_at, :utc_datetime_usec)
      add(:last_update_number, :string)
    end

    create(
      constraint(:goal_grants, :goal_grants_handoff_only_space,
        check: "handed_at IS NULL OR audience_type = 'space'"
      )
    )
  end
end
