defmodule Platform.Repo.Migrations.CreateGoalTables do
  @moduledoc """
  Goals' four tables (task 01a1dfc0, Goals 1/8): the goal itself, the stops
  on its journey, the grants that open it to a person, a team or a space, and
  the notebook entries written against it. One file because the stack
  reserved one migration version for this member (20261115152203).

  `0055-extension-contract-and-build-time-modules.md § 6. Migrations`: a
  module's migration references only stable core tables (here orgs, users,
  agents and chat_spaces) and core never references a `goal_*` table.

  A team is an ORG row: core has no team table. A space grant IS the goal's
  link to that space; there is no other link column. `goals.source_key` has
  no CHECK on purpose, so a later member adds a number source without
  touching this table. Additive only: four new tables, no change to an
  existing one.
  """

  use Ecto.Migration

  # old-code-compatible: creates four new goal tables only; no existing table changes and the previous release reads none of them

  def change do
    create table(:goals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)

      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:coach_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:title, :string, null: false)
      add(:why, :text)
      add(:kind, :string, null: false, default: "personal")
      add(:status, :string, null: false, default: "active")
      add(:unit, :string)
      add(:target_value, :decimal)
      add(:source_key, :string)
      add(:source_settings, :map, null: false, default: %{})
      add(:agent_mode, :string, null: false, default: "advise")
      add(:rhythm, :string, null: false, default: "weekly")
      add(:rhythm_weekday, :integer)
      add(:outreach, :string, null: false, default: "gentle")

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:goals, [:owner_user_id]))
    create(index(:goals, [:org_id]))
    create(index(:goals, [:coach_agent_id]))

    create(constraint(:goals, :goals_kind_check, check: "kind IN ('personal', 'shared')"))

    create(
      constraint(:goals, :goals_status_check, check: "status IN ('active', 'paused', 'finished')")
    )

    create(
      constraint(:goals, :goals_agent_mode_check,
        check: "agent_mode IN ('do', 'advise', 'coach')"
      )
    )

    create(
      constraint(:goals, :goals_rhythm_check,
        check: "rhythm IN ('daily', 'weekdays', 'weekly', 'biweekly')"
      )
    )

    create(
      constraint(:goals, :goals_rhythm_weekday_check,
        check: "rhythm_weekday IS NULL OR rhythm_weekday BETWEEN 1 AND 7"
      )
    )

    create(
      constraint(:goals, :goals_outreach_check, check: "outreach IN ('off', 'gentle', 'pushy')")
    )

    create table(:goal_stops, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:position, :integer, null: false)
      add(:label, :string, null: false)
      add(:target_value, :decimal)
      add(:due_on, :date)
      add(:caption, :string)
      add(:theme, :string)
      add(:criteria, {:array, :map}, null: false, default: [])
      add(:reached_on, :date)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:goal_stops, [:goal_id, :position]))

    create table(:goal_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:audience_type, :string, null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all))
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:granted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(
      constraint(:goal_grants, :goal_grants_audience_type_check,
        check: "audience_type IN ('user', 'team', 'space')"
      )
    )

    create(
      constraint(:goal_grants, :goal_grants_one_audience,
        check: """
        (audience_type = 'user' AND user_id IS NOT NULL AND org_id IS NULL AND space_id IS NULL) OR
        (audience_type = 'team' AND org_id IS NOT NULL AND user_id IS NULL AND space_id IS NULL) OR
        (audience_type = 'space' AND space_id IS NOT NULL AND user_id IS NULL AND org_id IS NULL)
        """
      )
    )

    create(
      unique_index(:goal_grants, [:goal_id, :user_id],
        where: "user_id IS NOT NULL",
        name: :goal_grants_goal_id_user_id_index
      )
    )

    create(
      unique_index(:goal_grants, [:goal_id, :org_id],
        where: "org_id IS NOT NULL",
        name: :goal_grants_goal_id_org_id_index
      )
    )

    create(
      unique_index(:goal_grants, [:goal_id, :space_id],
        where: "space_id IS NOT NULL",
        name: :goal_grants_goal_id_space_id_index
      )
    )

    create(index(:goal_grants, [:user_id]))
    create(index(:goal_grants, [:org_id]))
    create(index(:goal_grants, [:space_id]))

    create table(:goal_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :delete_all), null: false)
      add(:kind, :string, null: false)
      add(:title, :string)
      add(:body, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:author_type, :string, null: false)
      add(:author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:author_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:prediction, :text)
      add(:predicted_change, :decimal)
      add(:predicted_by, :date)
      add(:sources, {:array, :map}, null: false, default: [])
      add(:details, :map, null: false, default: %{})
      add(:takeaway_id, references(:goal_entries, type: :binary_id, on_delete: :nilify_all))
      add(:stop_id, references(:goal_stops, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:goal_entries, [:goal_id, :occurred_at]))
    create(index(:goal_entries, [:goal_id, :kind]))

    create(
      constraint(:goal_entries, :goal_entries_kind_check,
        check: "kind IN ('wake_up', 'action', 'ask', 'wait', 'takeaway', 'retro')"
      )
    )

    create(
      constraint(:goal_entries, :goal_entries_author_type_check,
        check: "author_type IN ('user', 'agent')"
      )
    )
  end
end
