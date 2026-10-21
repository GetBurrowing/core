defmodule Platform.Repo.Migrations.CreateSocialConnectInvites do
  @moduledoc """
  Connect invites (task 01a14ce1, stage 2): a profile approver invites a
  person to connect THEIR OWN account on one platform, and that person
  becomes the account's owner (`social_accounts.owner_user_id`).

  Only hashes are stored: `token_hash` is sha256 of the 32-byte random
  token in the link the approver shares (returned once by
  `Platform.Social.create_invite/5`), and `connect_nonce_hash` is sha256 of
  the per-connect nonce `start_invite_connect/2` puts in the vendor's
  `redirect_url` (so the shared token never reaches the vendor or the
  browser history of the return). `started_by_user_id` is who started the
  current connect; only they may complete it. The row holds NO Zernio key
  or token.
  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    create table(:social_connect_invites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:platform, :string, null: false)
      add(:token_hash, :binary, null: false)

      add(:created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:used_at, :utc_datetime_usec)
      add(:used_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :nilify_all))

      add(:cancelled_at, :utc_datetime_usec)
      add(:started_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:connect_nonce_hash, :binary)
      add(:connect_nonce_expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_connect_invites, [:token_hash]))
    create(unique_index(:social_connect_invites, [:connect_nonce_hash]))
    create(index(:social_connect_invites, [:profile_id]))
    create(index(:social_connect_invites, [:account_id]))
  end
end
