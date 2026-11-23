defmodule Platform.Social.Analytics.PublicationSyncState do
  @moduledoc "Account/query-bound list cursor and applied request token, independent of the legacy delta cursor."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_publication_sync_states" do
    belongs_to(:account, Platform.Social.Account)
    field(:kind, :string)
    field(:provider_account_ref, :string)
    field(:provider_profile_ref, :string)
    field(:query_hash, :string)
    field(:from_date, :date)
    field(:to_date, :date)
    field(:cursor, :string)
    field(:seen_cursors, {:array, :string}, default: [])
    field(:scan_id, :binary_id)
    field(:scan_started_at, :utc_datetime_usec)
    field(:scan_safe, :boolean, default: true)
    field(:completed_at, :utc_datetime_usec)
    field(:checked_ranges, {:array, :map}, default: [])
    field(:incomplete_ranges, {:array, :map}, default: [])
    field(:coverage_repaired_at, :utc_datetime_usec)
    field(:checked_from, :date)
    field(:checked_to, :date)
    field(:window_index, :integer, default: 0)
    field(:history_incomplete, :boolean, default: false)
    field(:history_exhausted, :boolean, default: false)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:attempted_at, :utc_datetime_usec)
    field(:last_attempt_token, :binary_id)
    field(:last_error, :string)
  end
end
