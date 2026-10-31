defmodule Platform.Repo.Migrations.AddSshKeyIdToInstalls do
  @moduledoc """
  One-click installs (task 01a10315-b39b-7001-9086-b6f672c8a6bf, stage 6):
  `ssh_key_id` is the id of the DigitalOcean account SSH key registered for
  the install's root key. It is passed in the droplet create (`ssh_keys`), so
  the provider does not expire root's password, and teardown deletes it.
  It is an id, not a secret: the key is the install's PUBLIC half.
  """
  use Ecto.Migration

  def change do
    alter table(:installs) do
      add(:ssh_key_id, :bigint)
    end
  end
end
