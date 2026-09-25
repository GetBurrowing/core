defmodule Platform.Repo.Migrations.CreateFederationPeers do
  @moduledoc """
  Storage for install-to-install federation: this install's identity and
  signing keys, and the peers it has a relationship with (task
  01a0d90f-3e5a-7001-9bf8-c266127c5186 stage 2, ADR-0054,
  `docs/decisions/0054-install-to-install-federation.md`).

  ## Tables

    * `federation_install_identity` — this install's `install_id` (UUIDv7)
      and display name. A SINGLETON: the `singleton` column is `true` for
      every row, a CHECK forbids any other value, and a unique index on it
      admits exactly one row. A unique index on a nullable column would not
      do this, because `NULLS DISTINCT` never compares two NULLs.
    * `federation_install_keys` — this install's Ed25519 PUBLIC keys, one per
      `kid`, with `status` current | previous | retired and the `vault_slug`
      that names the private half in `Platform.Vault`. **No private key
      material is stored in this table.** A partial unique index admits at
      most one `current` key. `valid_until` bounds the rotation overlap of a
      `previous` key (7 days).
    * `federation_peers` — one row per remote install, unique on
      `peer_install_id`. `public_keys` is a jsonb ARRAY of
      `{kid, public_key, status, valid_until, added_at}`, so a receiver can
      end a peer's rotation overlap or retire one compromised peer kid
      without dropping the relationship (ADR-0054 section 1). `status` and
      `revoked_by` are CHECK-constrained to their vocabularies.

  Additive only: three new tables, no change to an existing one.
  """

  use Ecto.Migration

  def change do
    create table(:federation_install_identity, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:singleton, :boolean, null: false, default: true)
      add(:install_id, :uuid, null: false)
      add(:display_name, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:federation_install_identity, :federation_install_identity_singleton_true,
        check: "singleton"
      )
    )

    create(unique_index(:federation_install_identity, [:singleton]))

    create table(:federation_install_keys, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kid, :string, null: false)
      add(:public_key, :binary, null: false)
      add(:status, :string, null: false)
      add(:vault_slug, :string, null: false)
      add(:valid_until, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:federation_install_keys, [:kid]))

    create(
      unique_index(:federation_install_keys, [:status],
        where: "status = 'current'",
        name: :federation_install_keys_one_current
      )
    )

    create(
      constraint(:federation_install_keys, :federation_install_keys_status_check,
        check: "status IN ('current', 'previous', 'retired')"
      )
    )

    create table(:federation_peers, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:peer_install_id, :uuid, null: false)
      add(:base_url, :text, null: false)
      add(:display_name, :string)
      add(:public_keys, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:status, :string, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_by, :string)
      add(:accepted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:last_seen_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:federation_peers, [:peer_install_id]))
    create(index(:federation_peers, [:status]))

    create(
      constraint(:federation_peers, :federation_peers_status_check,
        check: "status IN ('pending_outbound', 'pending_inbound', 'active', 'revoked')"
      )
    )

    create(
      constraint(:federation_peers, :federation_peers_revoked_by_check,
        check: "revoked_by IS NULL OR revoked_by IN ('local', 'peer')"
      )
    )
  end
end
