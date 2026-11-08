# old-code-compatible: Creates only the new install_sharing table and its singleton constraint; previous code never reads it.
defmodule Platform.Repo.Migrations.CreateInstallSharing do
  @moduledoc """
  Task `01a1b678-8bb4-7000-96d2-c691eb9b13b5`, stage 1: the singleton row
  holding what this install shares with Burrow, one boolean per
  `Platform.Sharing.registry/0` key, plus a random `sharing_install_id`.

  Modelled on `create_install_branding`: `singleton` is pinned `true` by a
  CHECK and covered by a unique index, so a second row is refused by storage.

  Unlike `install_branding`, NO row ships with the migration. The row is
  seeded once, by `Platform.Sharing.get/0` on first read, from the install's
  environment (`FEEDBACK_POLICY`, `USAGE_COUNTS`, `FRICTION_REPORTS`,
  `HELP_CHANNEL_REPORTS`). A migration cannot see that environment reliably,
  and after the seed the row wins over the environment.

  Every switch column defaults to `false`, so a row written by anything
  other than the seed path shares nothing.

  No `Platform.Audit.record/1`, no `Phoenix.PubSub`: migrations run before
  the supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:install_sharing, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:singleton, :boolean, null: false, default: true)

      # Random UUIDv4. NOT the federation install id and linked to no account.
      add(:sharing_install_id, :uuid, null: false)

      add(:feedback, :boolean, null: false, default: false)
      add(:usage_counts, :boolean, null: false, default: false)
      add(:friction_reports, :boolean, null: false, default: false)
      add(:help_channel_reports, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:install_sharing, :install_sharing_singleton_true, check: "singleton"))
    create(unique_index(:install_sharing, [:singleton]))
  end
end
