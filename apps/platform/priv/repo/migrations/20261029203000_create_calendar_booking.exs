defmodule Platform.Repo.Migrations.CreateCalendarBooking do
  use Ecto.Migration
  def change do
    create table(:calendar_booking_links, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :title, :string, null: false
      add :time_zone, :string, null: false
      add :duration_minutes, :integer, null: false
      add :buffer_before_minutes, :integer, null: false, default: 0
      add :buffer_after_minutes, :integer, null: false, default: 0
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :windows, {:array, :map}, null: false, default: []
      add :create_meeting, :boolean, null: false, default: false
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all)
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:calendar_booking_links, [:token])
    create index(:calendar_booking_links, [:owner_id])
    create table(:calendar_bookings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :link_id, references(:calendar_booking_links, type: :uuid, on_delete: :delete_all), null: false
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :name, :string, null: false
      add :email, :string
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :reserved_start, :utc_datetime_usec, null: false
      add :reserved_end, :utc_datetime_usec, null: false
      add :event_id, references(:calendar_events, type: :uuid, on_delete: :nilify_all)
      add :meeting_id, references(:meetings, type: :uuid, on_delete: :nilify_all)
      add :delivery_error, :string
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:calendar_bookings, [:link_id, :idempotency_key])
    create index(:calendar_bookings, [:owner_id, :reserved_start])
  end
end
