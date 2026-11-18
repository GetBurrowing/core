defmodule Platform.Calendar.Booking do
  @moduledoc "A reservation and its idempotent receipt; public responses omit owner calendar details."
  use Ecto.Schema
  import Ecto.Query
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_bookings" do
    belongs_to(:link, Platform.Calendar.BookingLink)
    belongs_to(:owner, Platform.Accounts.User)
    belongs_to(:event, Platform.Calendar.Event)
    belongs_to(:meeting, Platform.Meetings.Meeting)
    field(:idempotency_key, :string)
    field(:name, :string)
    field(:email, :string)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:reserved_start, :utc_datetime_usec)
    field(:reserved_end, :utc_datetime_usec)
    # Every host this booking reserved, owner included, and each host's
    # native event (`Platform.Calendar.BookingHosts`). No foreign key: a
    # deleted host event leaves a dangling id the busy query ignores.
    field(:host_user_ids, {:array, :binary_id}, default: [])
    field(:host_event_ids, {:array, :binary_id}, default: [])
    belongs_to(:delivery, Platform.Mail.Delivery)
    field(:delivery_error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  True when `event_id` is the native event of some booking, for ANY of its
  hosts: the owner's `event_id` or a co-host's entry in `host_event_ids`
  (task 01a1eff0-6880 stage 2). Agent calendar access refuses to move or
  revert such an event, so a grant on a co-host cannot shift a booked slot
  out from under its reservation.
  """
  def owns_event?(event_id) when is_binary(event_id) do
    Platform.UUID.valid?(event_id) and
      Platform.Repo.exists?(
        from(b in __MODULE__,
          where:
            b.event_id == ^event_id or
              fragment("? = ANY(?)", type(^event_id, Ecto.UUID), b.host_event_ids)
        )
      )
  end

  def owns_event?(_), do: false
end
