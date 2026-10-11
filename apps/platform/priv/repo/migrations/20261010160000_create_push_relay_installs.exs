defmodule Platform.Repo.Migrations.CreatePushRelayInstalls do
  @moduledoc """
  Task 01a1261e stage 2: the installs allowed to push through this install's
  push relay (`Platform.Push.RelayInstall`).

  The ONLY table relay mode writes. It holds a hashed credential per install
  (SHA-256 of a random secret, the `app_sessions` pattern) and nothing about
  any notification, device or token: the relay forwards sealed blobs and
  persists none of them. Empty on every install that does not run relay
  mode.
  """
  use Ecto.Migration

  def change do
    create table(:push_relay_installs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:host, :string, null: false)
      add(:credential_hash, :binary, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:last_used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:push_relay_installs, [:credential_hash]))
  end
end
