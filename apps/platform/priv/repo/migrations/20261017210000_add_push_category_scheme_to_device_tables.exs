defmodule Platform.Repo.Migrations.AddPushCategorySchemeToDeviceTables do
  @moduledoc """
  Task 01a14ba1 stage 3: the notification category ids an install's build
  registers, on BOTH alert-push device tables. The capability the push
  transports key on (stage 4) to send `BURROW_*` category ids only to a
  build that registers them.

  `nil` means legacy: the build registers only the `SUITE_*` ids
  (`SUITE_MENTION`, `SUITE_OPEN`, `SUITE_RING_WAITING`), which is every
  build shipped before this task. `"burrow"` means the build registers the
  `BURROW_*` ids as well. The changesets admit only `"burrow"` or nil.

  Columns, mirroring `push_public_key` (20261010150000): the value belongs to
  exactly the registration row it arrived with and is replaced on
  re-registration. `apns_voip_devices` gets none: VoIP rings carry no
  category.

  Additive only: nullable, no default, no backfill. Every existing row stays
  nil (legacy), which is the correct value for it.
  """
  use Ecto.Migration

  def change do
    alter table(:apns_devices) do
      add(:push_category_scheme, :string)
    end

    alter table(:fcm_devices) do
      add(:push_category_scheme, :string)
    end
  end
end
