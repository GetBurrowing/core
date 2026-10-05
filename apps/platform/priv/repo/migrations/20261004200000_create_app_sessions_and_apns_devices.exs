defmodule Platform.Repo.Migrations.CreateAppSessionsAndApnsDevices do
  @moduledoc """
  Task 01a10882 stage 1: the server half of the native iOS app.

  Three tables, all owned by a user and all cascading with that user.

    * `app_sessions`: one row per signed-in app install. The app holds a
      bearer token; this table holds only its SHA-256 (`token_hash`). The raw
      token is returned exactly once, by `Platform.Mobile.exchange_code/3`.
    * `app_login_codes`: short-lived (60 s), single-use codes. `exchange`
      codes are minted by the OIDC callback for an app login and are bound to
      the app's PKCE S256 `code_challenge`; `handoff` codes are minted by the
      exchange and sign the app's WKWebView in through
      `GET /auth/app/handoff?code=...`. Only `code_hash` is stored.
    * `apns_devices`: APNs device tokens. Deliberately NOT
      `push_subscriptions`, which is keyed on a participant id with no FK.
      A device belongs to a user and to the app session that registered it,
      so revoking the session (or deleting the user) removes the device.
      `token` is unique across the install: a token that moves to another
      user is reassigned, never duplicated. `(user_id, app_install_id)` is
      unique: one device row per app install per user.

  Push type is alert only. Nothing here is VoIP or meeting related.
  """
  use Ecto.Migration

  def change do
    create table(:app_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:app_install_id, :text)
      add(:device_name, :text)
      add(:last_used_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:app_sessions, [:token_hash]))
    create(index(:app_sessions, [:user_id]))

    create table(:app_login_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:code_hash, :binary, null: false)
      add(:code_challenge, :text)
      add(:purpose, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:app_login_codes, [:code_hash]))
    create(index(:app_login_codes, [:user_id]))

    create(
      constraint(:app_login_codes, :app_login_codes_purpose_check,
        check: "purpose IN ('exchange', 'handoff')"
      )
    )

    create table(:apns_devices, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :app_session_id,
        references(:app_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:app_install_id, :text, null: false)
      add(:token, :text, null: false)
      add(:environment, :text, null: false)
      add(:bundle_id, :text, null: false)
      add(:last_registered_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:apns_devices, [:token]))
    create(unique_index(:apns_devices, [:user_id, :app_install_id]))
    create(index(:apns_devices, [:app_session_id]))

    create(
      constraint(:apns_devices, :apns_devices_environment_check,
        check: "environment IN ('sandbox', 'production')"
      )
    )
  end
end
