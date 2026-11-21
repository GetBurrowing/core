defmodule Platform.Social.FollowerSnapshot do
  @moduledoc "A vendor's daily follower observation, partitioned by account and its current vendor identity."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_follower_snapshots" do
    belongs_to(:account, Platform.Social.Account)
    field(:provider_account_ref, :string)
    field(:date, :date)
    field(:followers, :integer)
    field(:observed_at, :utc_datetime_usec)
  end
end
