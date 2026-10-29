defmodule Platform.Calendar.Booking do
  @moduledoc "A reservation and its idempotent receipt; public responses omit owner calendar details."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_bookings" do
    belongs_to :link, Platform.Calendar.BookingLink
    belongs_to :owner, Platform.Accounts.User
    belongs_to :event, Platform.Calendar.Event
    belongs_to :meeting, Platform.Meetings.Meeting
    field :idempotency_key, :string
    field :name, :string
    field :email, :string
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :reserved_start, :utc_datetime_usec
    field :reserved_end, :utc_datetime_usec
    field :delivery_error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
