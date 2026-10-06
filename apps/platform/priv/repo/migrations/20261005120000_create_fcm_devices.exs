defmodule Platform.Repo.Migrations.CreateFcmDevices do
  @moduledoc """
  Task 01a10d8e stage 1: Firebase Cloud Messaging device tokens for the
  native Android app (Burrow, package `com.koboai.burrow`).

  A sibling of `apns_devices`, deliberately NOT a `platform` column on it:

    * `apns_devices` carries `environment IN ('sandbox', 'production')` and
      its changeset requires a hex-only token. An FCM registration token has
      no environment and is not hex, so a shared table would need both rules
      relaxed conditionally and every APNs query filtered by platform, which
      means editing `Platform.Push.APNs`. Two tables keep the transports
      independently prunable and leave the live APNs code untouched.
    * Not `push_subscriptions` either: that table is web push, keyed on a
      chat participant id with no foreign key (task 019ffcab).

  Same ownership as `apns_devices`: a device belongs to a user and to the app
  session that registered it, so revoking the session or deleting the user
  removes it. `token` is unique (a token that moves to another user is
  reassigned, never duplicated) and `(user_id, app_install_id)` is unique
  (one device row per app install per user).
  """
  use Ecto.Migration

  def change do
    create table(:fcm_devices, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :app_session_id,
        references(:app_sessions, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:app_install_id, :text, null: false)
      add(:token, :text, null: false)
      add(:package_name, :text, null: false)
      add(:last_registered_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:fcm_devices, [:token]))
    create(unique_index(:fcm_devices, [:user_id, :app_install_id]))
    create(index(:fcm_devices, [:app_session_id]))
  end
end
