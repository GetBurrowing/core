# old-code-compatible: Creates only the new install_boot_markers table; previous code never reads it.
defmodule Platform.Repo.Migrations.CreateInstallBootMarkers do
  @moduledoc """
  Task 01a1e65e stage 2. One row per one-shot boot step that has finished on
  this install, keyed by a fixed name (`Platform.Install.BootMarkers`). The
  first user is `Platform.SignInAdmin.EmailLoginCodeBoot`: once it has turned
  pocket-id's email login code on, it must never turn it back on after an
  admin has turned it off.

  No row ships with the migration. A missing row means the step has not
  finished, so the step runs.
  """

  use Ecto.Migration

  def change do
    create table(:install_boot_markers, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:install_boot_markers, [:key]))
  end
end
