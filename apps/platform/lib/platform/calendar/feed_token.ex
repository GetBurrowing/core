defmodule Platform.Calendar.FeedToken do
  @moduledoc "Hashed subscription credential; the plaintext is returned only when rotated."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_feed_tokens" do
    belongs_to(:owner, Platform.Accounts.User)
    field(:token_hash, :binary)
    timestamps(type: :utc_datetime_usec)
  end
end
