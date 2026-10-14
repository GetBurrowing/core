defmodule Platform.Repo.Migrations.AddPushPublicKeyToDeviceTables do
  @moduledoc """
  Task 01a1261e stage 1: the device's X25519 public key for sealed push
  previews (`Platform.Push.Seal`), on BOTH alert-push device tables.

  Columns, not a fourth device table: the key belongs to exactly the
  registration row it arrived with (one install, one token), is replaced on
  re-registration and dies with the row. A separate table would need its own
  lifecycle beside `apns_devices`, `fcm_devices` and `apns_voip_devices`.
  `apns_voip_devices` gets none: VoIP rings carry no preview.

  Nullable and with no default: every existing row, and every registration
  from a build that sends no key (TestFlight build 1), stays valid and simply
  gets no sealed preview. Stored as base64url without padding (43
  characters); the changesets validate it decodes to exactly 32 bytes.
  """
  use Ecto.Migration

  def change do
    alter table(:apns_devices) do
      add(:push_public_key, :string)
    end

    alter table(:fcm_devices) do
      add(:push_public_key, :string)
    end
  end
end
