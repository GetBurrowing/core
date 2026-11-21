defmodule Platform.Social.FollowerSyncState do
  @moduledoc "Durable account follower freshness and next-attempt deadline, written only by the analytics sweep."
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id
  schema "social_follower_sync_states" do
    belongs_to(:account, Platform.Social.Account, primary_key: true)
    field(:provider_account_ref, :string)
    field(:attempted_at, :utc_datetime_usec)
    field(:succeeded_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:source_stale, :boolean, default: false)
    field(:stale_since, :string)
  end
end
