defmodule Platform.Repo.Migrations.CreateGoalClockTables do
  @moduledoc "Goal clock storage (task 01a1dfc1-05b0; ADR 0055 section 6)."
  use Ecto.Migration

  # old-code-compatible: creates five new goal tables only; no existing table changes and the previous release reads none of them
  def change do
    create table(:goal_clocks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:time_zone, :string, null: false)
      add(:wake_hour, :integer, null: false, default: 6)
      add(:next_wake_at, :utc_datetime_usec, null: false)
      add(:anchor_on, :date, null: false)
      add(:schedule_key, :string, null: false)
      add(:last_woken_at, :utc_datetime_usec)
      add(:stalled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:goal_clocks, [:goal_id]))
    create(index(:goal_clocks, [:next_wake_at]))

    create table(:goal_wake_ups, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false, default: "check_in")
      add(:due_at, :utc_datetime_usec, null: false)
      add(:fired_at, :utc_datetime_usec, null: false)
      add(:respond_by, :utc_datetime_usec, null: false)
      add(:coach_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:status, :string, null: false, default: "open")
      add(:outcome, :string)
      add(:closed_at, :utc_datetime_usec)
      add(:catch_up, :boolean, null: false, default: false)
      add(:delivery, :string, null: false, default: "pending")
      add(:reading_id, references(:goal_readings, type: :binary_id, on_delete: :nilify_all))
      add(:briefing, :map, null: false, default: %{})
      add(:entry_id, references(:goal_entries, type: :binary_id, on_delete: :nilify_all))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:goal_wake_ups, [:goal_id, :kind, :due_at]))
    create(index(:goal_wake_ups, [:status, :respond_by]))

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_kind, check: "kind IN ('check_in', 'retro')")
    )

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_status,
        check: "status IN ('open', 'closed', 'unanswered')"
      )
    )

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_outcome,
        check: "outcome IS NULL OR outcome IN ('do', 'ask', 'wait')"
      )
    )

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_delivery,
        check: "delivery IN ('pending', 'sent', 'offline', 'failed', 'no_runtime')"
      )
    )

    create table(:goal_asks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:wake_up_id, references(:goal_wake_ups, type: :binary_id, on_delete: :nilify_all))
      add(:entry_id, references(:goal_entries, type: :binary_id, on_delete: :nilify_all))
      add(:created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:kind, :string, null: false)
      add(:title, :string, null: false)
      add(:body, :text)
      add(:payload, :map, null: false, default: %{})
      add(:addressed_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:status, :string, null: false, default: "open")
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:closed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:goal_asks, [:goal_id, :status]))

    create(
      constraint(:goal_asks, :goal_asks_kind, check: "kind IN ('question', 'offer', 'practice')")
    )

    create(
      constraint(:goal_asks, :goal_asks_status, check: "status IN ('open', 'closed', 'expired')")
    )

    create table(:goal_ask_answers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:ask_id, references(:goal_asks, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:answer, :string, null: false)
      add(:details, :map, null: false, default: %{})
      add(:answered_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:goal_ask_answers, [:ask_id, :user_id]))

    create(
      constraint(:goal_ask_answers, :goal_ask_answers_answer,
        check: "answer IN ('used', 'declined', 'ignored')"
      )
    )

    create table(:goal_task_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false)
      add(:wake_up_id, references(:goal_wake_ups, type: :binary_id, on_delete: :nilify_all))
      add(:entry_id, references(:goal_entries, type: :binary_id, on_delete: :nilify_all))
      add(:created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))

      add(
        :reported_wake_up_id,
        references(:goal_wake_ups, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:goal_task_links, [:task_id]))
    create(index(:goal_task_links, [:goal_id]))
    create(constraint(:goal_clocks, :goal_clocks_wake_hour, check: "wake_hour BETWEEN 0 AND 23"))

    create(
      constraint(:goal_wake_ups, :goal_wake_ups_outcome_matches_status,
        check: "(status = 'closed') = (outcome IS NOT NULL)"
      )
    )

    create(
      unique_index(:goal_wake_ups, [:goal_id, :kind],
        name: :goal_wake_ups_one_open,
        where: "status = 'open'"
      )
    )
  end
end
