defmodule Platform.Repo.Migrations.CreateCalendarBookingLinkHosts do
  @moduledoc """
  Co-hosts on a booking link and the host set each booking reserved.

  Task 01a1eff0-6880-7000-b5fa-8ca51ebdf743, stage 1. One row per invited
  co-host carries its own status (pending, accepted, declined, left), so a
  link offers times only once every co-host has accepted
  (`Platform.Calendar.BookingHosts.hosts_ready/1`). `calendar_bookings`
  gains the host user ids it reserved (GIN-indexed for the overlap query a
  later stage adds) and the per-host event ids. The arrays carry no foreign
  key: a deleted host event leaves a dangling id, which the busy query
  ignores.
  """
  use Ecto.Migration

  def change do
    create table(:calendar_booking_link_hosts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:link_id, references(:calendar_booking_links, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:invited_by_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:status, :string, null: false, default: "pending")
      add(:responded_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:calendar_booking_link_hosts, :calendar_booking_link_hosts_status_check,
        check: "status IN ('pending', 'accepted', 'declined', 'left')"
      )
    )

    create(unique_index(:calendar_booking_link_hosts, [:link_id, :user_id]))
    create(index(:calendar_booking_link_hosts, [:user_id, :status]))

    alter table(:calendar_bookings) do
      add(:host_user_ids, {:array, :uuid}, null: false, default: [])
      add(:host_event_ids, {:array, :uuid}, null: false, default: [])
    end

    create(index(:calendar_bookings, [:host_user_ids], using: "GIN"))
  end
end
