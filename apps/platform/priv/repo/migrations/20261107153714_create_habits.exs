defmodule Platform.Repo.Migrations.CreateHabits do
  @moduledoc """
  Task 01a1b6a1 stage 1, recorded in `0061-learned-defaults.md`: the learned
  defaults store.

    * `habit_signals` — one row per learnable choice on any surface. `outcome`
      and `rung` are closed sets, held by CHECK constraints.
    * `habit_patterns` — the cache over signals plus the trust-ladder state,
      one row per (user, space, action, target). `space_id` is nullable for
      org-level actions, so the unique index is `NULLS NOT DISTINCT` (ADR 0052
      decision 4): under the Postgres default two NULL-space rows for the same
      tuple would never collide.

  Both tables are new and empty; nothing existing changes. `down/0` drops them.
  """

  use Ecto.Migration

  def up do
    require_pg15!()

    create table(:habit_signals, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:actor_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:action, :text, null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :uuid, null: false)
      add(:outcome, :text, null: false)
      add(:rung, :text, null: false)
      add(:source_message_id, :uuid)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:habit_signals, :habit_signals_outcome_check,
        check: "outcome IN ('accepted', 'overridden', 'ignored', 'chosen')"
      )
    )

    create(
      constraint(:habit_signals, :habit_signals_rung_check,
        check: "rung IN ('none', 'rank', 'prefill', 'act')"
      )
    )

    create(
      constraint(:habit_signals, :habit_signals_target_type_check,
        check: "target_type IN ('user', 'agent')"
      )
    )

    create(
      index(:habit_signals, [:actor_user_id, :space_id, :action, :inserted_at],
        name: :habit_signals_actor_space_action_index
      )
    )

    create table(:habit_patterns, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:action, :text, null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :uuid, null: false)
      add(:accepted_prefills, :integer, null: false, default: 0)
      add(:rung, :text, null: false, default: "rank")
      add(:stopped_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:habit_patterns, :habit_patterns_rung_check,
        check: "rung IN ('rank', 'prefill', 'act')"
      )
    )

    create(
      constraint(:habit_patterns, :habit_patterns_target_type_check,
        check: "target_type IN ('user', 'agent')"
      )
    )

    create(
      constraint(:habit_patterns, :habit_patterns_accepted_prefills_check,
        check: "accepted_prefills >= 0"
      )
    )

    create(
      unique_index(:habit_patterns, [:user_id, :space_id, :action, :target_type, :target_id],
        nulls_distinct: false,
        name: :habit_patterns_tuple_index
      )
    )
  end

  def down do
    drop(table(:habit_patterns))
    drop(table(:habit_signals))
  end

  defp require_pg15! do
    %{rows: [[version]]} = repo().query!("SHOW server_version_num", [])

    if String.to_integer(version) < 150_000 do
      raise """
      #{inspect(__MODULE__)} needs Postgres 15 or newer for NULLS NOT DISTINCT.

      This server reports server_version_num=#{version}. The one-row-per-pattern
      index on habit_patterns cannot be built without it. Upgrade the server.
      """
    end
  end
end
