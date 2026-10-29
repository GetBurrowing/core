defmodule Platform.Repo.Migrations.CreateCalendar do
  @moduledoc """
  Add native calendar events and hashed per-user aggregate feed tokens.
  Authorized by Calendar task 01a16991-b7ae-7000-923f-54cd0b8cd7f7, stage 1.
  """
  use Ecto.Migration

  def up do
    create table(:calendar_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all))
      add(:title, :text, null: false)
      add(:description, :text)
      add(:starts_at, :utc_datetime_usec, null: false)
      add(:ends_at, :utc_datetime_usec, null: false)
      add(:time_zone, :text, null: false, default: "Etc/UTC")
      add(:all_day, :boolean, null: false, default: false)
      add(:start_date, :date)
      add(:end_date, :date)
      add(:visibility, :text, null: false, default: "details")
      add(:recurrence, :text)
      add(:exception_dates, {:array, :date}, null: false, default: [])
      add(:sequence, :integer, null: false, default: 0)
      add(:cancelled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:calendar_events, [:owner_id, :starts_at]))
    create(index(:calendar_events, [:space_id]))
    create(index(:calendar_events, [:project_id]))

    create(
      constraint(:calendar_events, :calendar_events_positive_window, check: "ends_at > starts_at")
    )

    create(
      constraint(:calendar_events, :calendar_events_one_scope,
        check: "num_nonnulls(space_id, project_id) <= 1"
      )
    )

    create(
      constraint(:calendar_events, :calendar_events_visibility,
        check: "visibility IN ('busy', 'details')"
      )
    )

    create(
      constraint(:calendar_events, :calendar_events_all_day_dates,
        check: "NOT all_day OR (start_date IS NOT NULL AND end_date > start_date)"
      )
    )

    create table(:calendar_feed_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_feed_tokens, [:owner_id]))
    create(unique_index(:calendar_feed_tokens, [:token_hash]))

    execute("""
    UPDATE access_roles
    SET permissions = permissions || '{"calendar.read":"all","calendar.write":"all"}'::jsonb
    WHERE builtin = true AND key IN ('admin', 'member')
    """)
  end

  def down do
    execute(
      "UPDATE access_roles SET permissions = permissions - 'calendar.read' - 'calendar.write' WHERE builtin = true"
    )

    drop(table(:calendar_feed_tokens))
    drop(table(:calendar_events))
  end
end
