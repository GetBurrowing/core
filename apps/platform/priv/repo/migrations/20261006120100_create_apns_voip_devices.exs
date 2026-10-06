defmodule Platform.Repo.Migrations.CreateApnsVoipDevices do
  @moduledoc """
  Task 01a10db7 stage 1: PushKit VoIP tokens for the native iOS app (Burrow),
  used to ring a device for an incoming meeting through CallKit.

  The THIRD push-device table, next to `apns_devices` (APNs alert tokens) and
  `fcm_devices` (Android). Deliberately not a column on `apns_devices`:

    * a PushKit VoIP token is a different token from the install's alert
      token, issued by a different API (`PKPushRegistry`), and an install can
      hold one without the other — `apns_devices.token` is NOT NULL;
    * VoIP pushes go to a different topic (`<bundle id>.voip`) with push type
      `voip`, so a 410 / `BadDeviceToken` for one token says nothing about the
      other, and pruning must delete exactly the row that failed.

  Consolidating the three tables is out of scope here.

  Same ownership as its siblings: a device belongs to a user and to the app
  session that registered it, so deleting either removes it. Sign-out
  REVOKES the session row rather than deleting it, so the cascade alone never
  fires on sign-out; `Platform.Mobile.revoke_session/1` and
  `unregister_device/2` delete from this table explicitly.
  """
  use Ecto.Migration

  def change do
    create table(:apns_voip_devices, primary_key: false) do
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

    create(unique_index(:apns_voip_devices, [:token]))
    create(unique_index(:apns_voip_devices, [:user_id, :app_install_id]))
    create(index(:apns_voip_devices, [:app_session_id]))

    create(
      constraint(:apns_voip_devices, :apns_voip_devices_environment_check,
        check: "environment IN ('sandbox', 'production')"
      )
    )
  end
end
