defmodule Platform.Repo.Migrations.AddSocialPublicationObservations do
  @moduledoc """
  Read-only publication observations and resumable list work. Extension-local
  tables follow ADR 0055. Down removes derived metrics/checkpoints only, never
  authored posts, approval records or media.
  """
  use Ecto.Migration

  # old-code-compatible: additive cache tables; existing binaries ignore them.
  def change do
    create table(:social_account_publications, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:provider_account_ref, :text, null: false)
      add(:provider_profile_ref, :text, null: false)
      add(:platform, :text, null: false)
      add(:native_id, :text, null: false)
      add(:external_id, :text)
      add(:vendor_url, :text)
      add(:published_at, :utc_datetime_usec)
      add(:vendor_synced_at, :utc_datetime_usec)
      add(:sync_status, :text)
      add(:metrics, :map, null: false, default: %{})
      add(:is_owner, :boolean)
      add(:is_ad, :boolean)
      add(:fetched_at, :utc_datetime_usec, null: false)
      add(:last_listed_at, :utc_datetime_usec, null: false)
      add(:last_seen_scans, :map, null: false, default: %{})
      add(:listed_from, :date, null: false)
      add(:listed_to, :date, null: false)
      add(:not_listed, :boolean, null: false, default: false)
      add(:source_stale, :boolean, null: false, default: false)
      add(:ambiguous_count, :integer, null: false, default: 0)
      add(:ambiguous_observation, :map)
    end

    create(
      unique_index(
        :social_account_publications,
        [:account_id, :provider_account_ref, :provider_profile_ref, :platform, :native_id],
        name: :social_publications_identity
      )
    )

    create(index(:social_account_publications, [:account_id, :published_at]))

    create(
      constraint(:social_account_publications, :social_publications_ambiguity_count,
        check: "ambiguous_count >= 0"
      )
    )

    create table(:social_publication_sync_states, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:provider_account_ref, :text, null: false)
      add(:provider_profile_ref, :text, null: false)
      add(:query_hash, :text)
      add(:from_date, :date)
      add(:to_date, :date)
      add(:cursor, :text)
      add(:seen_cursors, {:array, :text}, null: false, default: [])
      add(:scan_id, :binary_id)
      add(:scan_started_at, :utc_datetime_usec)
      add(:scan_safe, :boolean, null: false, default: true)
      add(:completed_at, :utc_datetime_usec)
      add(:checked_ranges, {:array, :map}, null: false, default: [])
      add(:incomplete_ranges, {:array, :map}, null: false, default: [])
      add(:coverage_repaired_at, :utc_datetime_usec)
      add(:checked_from, :date)
      add(:checked_to, :date)
      add(:window_index, :integer, null: false, default: 0)
      add(:history_incomplete, :boolean, null: false, default: false)
      add(:history_exhausted, :boolean, null: false, default: false)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:attempted_at, :utc_datetime_usec)
      add(:last_attempt_token, :binary_id)
      add(:last_error, :text)
    end

    create(unique_index(:social_publication_sync_states, [:account_id, :kind]))
    create(index(:social_publication_sync_states, [:next_attempt_at]))

    create(
      constraint(:social_publication_sync_states, :social_publications_kind,
        check: "kind IN ('discovery', 'refresh')"
      )
    )

    create table(:social_publication_org_budgets, primary_key: false) do
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), primary_key: true)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_account_id, :binary_id)
      add(:next_kind, :text, null: false, default: "discovery")
      add(:reservations, :map, null: false, default: %{})
    end
  end
end
