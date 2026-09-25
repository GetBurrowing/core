defmodule Platform.Repo.Migrations.CreateFederationSharedSpaces do
  @moduledoc """
  Shared spaces and message links for install-to-install federation (task
  01a0d90f-3e5a-7001-9bf8-c266127c5186 stage 5, ADR-0054,
  `docs/decisions/0054-install-to-install-federation.md` section 3).

  ## Tables

    * `federation_shared_spaces` — one row per local space that is shared
      with a peer. `local_space_id` is UNIQUE: in v1 a space is shared with
      at most one peer. `role` is `owner` (this install shared it and is
      authoritative) or `replica` (the peer shared it with us). The pair
      `(peer_id, remote_space_id)` is unique too, so a re-delivered
      `space.share` finds the space it already created instead of making a
      second one. `outbound_cursor_message_id` is the newest local message
      the peer has acknowledged (2xx); a restarted connection replays the
      local messages after it. It is not a foreign key: a deleted message
      must not move or clear the cursor.
    * `federation_message_links` — one row per message that crossed the
      relationship. `direction` is `inbound` (the peer's message, ingested
      here as `local_message_id`) or `outbound` (our message, stored by the
      peer as `remote_message_id`). UNIQUE on `(peer_id, remote_message_id)`,
      which is what makes a duplicate inbound delivery a no-op: the second
      delivery finds the link and posts nothing. `local_message_id` is null
      while an ingest holds the claim and is filled once the message is
      posted.

  `status` / `role` / `direction` are CHECK-constrained to their
  vocabularies. Additive only: two new tables, no change to an existing one.
  """

  use Ecto.Migration

  def change do
    create table(:federation_shared_spaces, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:peer_id, references(:federation_peers, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:local_space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:remote_space_id, :uuid, null: false)
      add(:role, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:outbound_cursor_message_id, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:federation_shared_spaces, [:local_space_id]))
    create(unique_index(:federation_shared_spaces, [:peer_id, :remote_space_id]))

    create(
      constraint(:federation_shared_spaces, :federation_shared_spaces_role_check,
        check: "role IN ('owner', 'replica')"
      )
    )

    create(
      constraint(:federation_shared_spaces, :federation_shared_spaces_status_check,
        check: "status IN ('active', 'revoked')"
      )
    )

    create table(:federation_message_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:peer_id, references(:federation_peers, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :local_message_id,
        references(:chat_messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:remote_message_id, :uuid, null: false)
      add(:direction, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:federation_message_links, [:peer_id, :remote_message_id]))
    create(index(:federation_message_links, [:local_message_id]))

    create(
      constraint(:federation_message_links, :federation_message_links_direction_check,
        check: "direction IN ('inbound', 'outbound')"
      )
    )
  end
end
