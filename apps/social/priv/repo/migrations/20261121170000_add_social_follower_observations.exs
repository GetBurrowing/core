defmodule Platform.Repo.Migrations.AddSocialFollowerObservations do
  @moduledoc """
  Stores dated, account-specific follower observations and durable refresh
  state alongside an optional account target. Follows extension-local migration
  ownership follows ADR 0055.
  0055-extension-contract-and-build-time-modules.md § 6. Migrations.
  Also separates post-refresh failure from a shared rate-limit deadline.
  Down removes follower history, refresh diagnostics and targets, never posts or votes.
  """
  use Ecto.Migration

  # old-code-compatible: additive tables and nullable target; old code ignores them.
  def change do
    alter table(:social_accounts) do
      add(:follower_target, :integer)
    end

    alter table(:social_analytics_sync_states) do
      add(:post_refresh_error, :text)
      add(:provider_retry_at, :utc_datetime_usec)
    end

    create(
      constraint(:social_accounts, :social_accounts_follower_target_check,
        check: "follower_target IS NULL OR follower_target > 0"
      )
    )

    create table(:social_follower_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:provider_account_ref, :text, null: false)
      add(:date, :date, null: false)
      add(:followers, :bigint, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:social_follower_snapshots, [:account_id, :provider_account_ref, :date],
        name: :social_follower_snapshots_account_date
      )
    )

    create(
      constraint(:social_follower_snapshots, :social_follower_snapshots_nonnegative,
        check: "followers >= 0"
      )
    )

    create table(:social_follower_sync_states, primary_key: false) do
      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:provider_account_ref, :text, null: false)
      add(:attempted_at, :utc_datetime_usec)
      add(:succeeded_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error, :text)
      add(:source_stale, :boolean, default: false, null: false)
      add(:stale_since, :text)
    end

    create(index(:social_follower_sync_states, [:next_attempt_at]))
  end
end
