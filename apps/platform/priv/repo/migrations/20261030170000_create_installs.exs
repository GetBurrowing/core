defmodule Platform.Repo.Migrations.CreateInstalls do
  @moduledoc """
  One-click DigitalOcean installs (task 01a10315-b39b-7001-9086-b6f672c8a6bf,
  stage 2): one row per install `Platform.Installs` provisions.

  * `steps` is a jsonb list of `%{key, state, started_at, finished_at, error}`
    (the runner's restartable step machine). It never holds a secret.
  * `status_token_hash` is the sha256 of the 32-byte capability token handed
    once to the creator; the token itself is never stored.
  * `handover_sealed` is `Platform.Vault.EncryptedBinary` (AES-GCM) holding
    the hand-over credentials until the customer acknowledges them
    (`handover_acknowledged_at`) or they expire unacknowledged
    (`handover_expired_at`, 7 days); either way it is set back to NULL.
  * `ssh_public_key` is the public half of the install's root key, kept so a
    re-render of the same install renders the same key. It is not a secret.
  """
  use Ecto.Migration

  def change do
    create table(:installs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:slug, :string, null: false)
      add(:business_name, :string, null: false)
      add(:owner_email, :string, null: false)
      add(:region, :string, null: false)
      add(:size, :string, null: false)
      add(:domain_mode, :string, null: false)
      add(:primary_host, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:steps, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:droplet_id, :bigint)
      add(:droplet_ip, :string)
      add(:firewall_id, :string)
      add(:ssh_public_key, :text, null: false)
      add(:status_token_hash, :binary, null: false)
      add(:handover_sealed, :binary)
      add(:ready_at, :utc_datetime_usec)
      add(:handover_acknowledged_at, :utc_datetime_usec)
      add(:handover_expired_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:installs, [:slug]))
    create(unique_index(:installs, [:status_token_hash]))
    create(index(:installs, [:status]))

    create(
      constraint(:installs, :installs_status_check,
        check:
          "status IN ('queued', 'provisioning', 'ready', 'failed', 'destroying', 'destroyed')"
      )
    )

    create(
      constraint(:installs, :installs_domain_mode_check,
        check: "domain_mode IN ('ours', 'customer')"
      )
    )
  end
end
