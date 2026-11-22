defmodule Platform.Social.Analytics.Publication do
  @moduledoc "Read-only provider observation; never an authored or publishable Social post."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_account_publications" do
    belongs_to(:account, Platform.Social.Account)
    belongs_to(:profile, Platform.Social.Profile)
    field(:provider_account_ref, :string)
    field(:provider_profile_ref, :string)
    field(:platform, :string)
    field(:native_id, :string)
    field(:external_id, :string)
    field(:vendor_url, :string)
    field(:published_at, :utc_datetime_usec)
    field(:vendor_synced_at, :utc_datetime_usec)
    field(:sync_status, :string)
    field(:metrics, :map, default: %{})
    field(:is_owner, :boolean)
    field(:is_ad, :boolean)
    field(:fetched_at, :utc_datetime_usec)
    field(:last_listed_at, :utc_datetime_usec)
    field(:last_seen_scans, :map, default: %{})
    field(:listed_from, :date)
    field(:listed_to, :date)
    field(:not_listed, :boolean, default: false)
    field(:source_stale, :boolean, default: false)
    field(:ambiguous_count, :integer, default: 0)
    field(:ambiguous_observation, :map)
  end
end
