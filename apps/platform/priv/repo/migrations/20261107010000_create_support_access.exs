defmodule Platform.Repo.Migrations.CreateSupportAccess do
  @moduledoc """
  Task 01a1b362-6ef5-7000-9bdd-cbe40bf2378c, stage 1 (ADR 0059): vendor
  support access on hosted installs.

    * `install_support_access_settings`: the owner's switch, a singleton in
      the `install_link_unfurl_settings` shape (CHECK on `singleton` plus a
      unique index). The row is seeded HERE from the OS env
      `SUPPORT_ACCESS_DEFAULT`: exactly `on` seeds `enabled = true`; any other
      value, or none, seeds `false`. A migration cannot assume
      `config/runtime.exs` ran, so it reads the env directly, the same as
      `20260519143620_seed_root_orgs`. The installer renders `on` for new
      hosted installs; an existing install that later receives this code
      starts OFF until its owner turns it on.
    * `support_sessions`: one row per granted admin or repair session.
    * `support_grant_nonces`: used grant nonces, kept until the grant's
      `expires_at`, so a replay is refused across restarts.
    * `support_sign_in_codes`: single-use sign-in codes for admin sessions,
      stored only as a sha256 hash.
    * `users.support_vendor`: marks the one support user per operator email.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:support_vendor, :boolean, null: false, default: false)
    end

    create table(:install_support_access_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:singleton, :boolean, null: false, default: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      # Host state file bookkeeping: the last write error (nil when the last
      # write succeeded) so the owner's Support card can show it, and when the
      # file was last written.
      add(:state_file_error, :text)
      add(:state_file_written_at, :utc_datetime_usec)
      # Read offset into the host-written shell events JSONL.
      add(:shell_events_offset, :bigint, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:install_support_access_settings, :install_support_access_settings_singleton,
        check: "singleton"
      )
    )

    create(unique_index(:install_support_access_settings, [:singleton]))

    enabled = System.get_env("SUPPORT_ACCESS_DEFAULT") == "on"

    execute("""
    INSERT INTO install_support_access_settings
      (id, singleton, enabled, shell_events_offset, inserted_at, updated_at)
    VALUES (gen_random_uuid(), true, #{enabled}, 0, now(), now())
    """)

    create table(:support_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :string, null: false)
      add(:operator_name, :string, null: false)
      add(:operator_email, :string, null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:not_before, :utc_datetime_usec, null: false)
      add(:not_after, :utc_datetime_usec, null: false)
      add(:ended_at, :utc_datetime_usec)
      add(:end_reason, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:support_sessions, :support_sessions_kind, check: "kind IN ('admin', 'repair')"))

    create(
      constraint(:support_sessions, :support_sessions_end_reason,
        check:
          "end_reason IS NULL OR end_reason IN ('expired', 'ended_by_owner', 'access_turned_off')"
      )
    )

    create(index(:support_sessions, [:not_after], where: "ended_at IS NULL"))
    create(index(:support_sessions, [:user_id]))

    create table(:support_grant_nonces, primary_key: false) do
      add(:nonce, :string, primary_key: true)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(index(:support_grant_nonces, [:expires_at]))

    create table(:support_sign_in_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :support_session_id,
        references(:support_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:code_hash, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:support_sign_in_codes, [:code_hash]))
  end

  def down do
    drop(table(:support_sign_in_codes))
    drop(table(:support_grant_nonces))
    drop(table(:support_sessions))
    drop(table(:install_support_access_settings))

    alter table(:users) do
      remove(:support_vendor)
    end
  end
end
