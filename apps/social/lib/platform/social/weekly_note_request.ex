defmodule Platform.Social.WeeklyNoteRequest do
  @moduledoc "Durable per-profile delivery-week outbox and expiring generation claim."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_weekly_note_requests" do
    field(:profile_id, :binary_id)
    field(:week_start, :date)
    field(:request_sent, :boolean, default: false)
    field(:link_sent, :boolean, default: false)
    field(:claim_until, :utc_datetime_usec)
    field(:claim_token, :binary_id)
  end
end
