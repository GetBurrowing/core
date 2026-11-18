defmodule Platform.Calendar.BookingLinkHost do
  @moduledoc """
  One co-host of a booking link and where their invitation stands.

  Rows are written only by `Platform.Calendar.BookingHosts`, which owns the
  transitions (pending -> accepted | declined, accepted -> left, declined |
  left -> pending on a re-invite). The link owner is never a row.
  """
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending accepted declined left)

  schema "calendar_booking_link_hosts" do
    belongs_to(:link, Platform.Calendar.BookingLink)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:invited_by, Platform.Accounts.User)
    field(:status, :string, default: "pending")
    field(:responded_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every status a host row can hold."
  def statuses, do: @statuses

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:link_id, :user_id, :invited_by_id, :status, :responded_at])
    |> validate_required([:link_id, :user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :calendar_booking_link_hosts_status_check)
    |> unique_constraint([:link_id, :user_id])
    |> foreign_key_constraint(:link_id)
    |> foreign_key_constraint(:user_id)
  end
end
