# old-code-compatible: Creates only new instruction state, entry and download tables; previous code never reads them.
defmodule Platform.Repo.Migrations.CreateInstructionPackInstallState do
  use Ecto.Migration
  @moduledoc "Task 01a1b6e1: install-side provenance and verified retained releases."
  def change do
    create table(:instruction_pack_states, primary_key: false) do
      add(:pack_id, :string, primary_key: true)
      add(:version, :bigint)
      add(:highest_version, :bigint, default: 0, null: false)
      add(:digest, :string)
      add(:pinned_version, :bigint)
      add(:history, {:array, :map}, default: [], null: false)
      add(:applied_at, :utc_datetime_usec)
      add(:checked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:instruction_pack_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:pack_id, references(:instruction_pack_states, column: :pack_id, type: :string),
        null: false
      )

      add(:type, :string, null: false)
      add(:target, :string, null: false)
      add(:vendor_content, :text)
      add(:vendor_hash, :string)
      add(:applied_hash, :string)
      add(:effective_version, :bigint)
      add(:conflict, :map)
      add(:retired, :boolean, default: false, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    # One vendor owner per physical target, even across packs.
    create(unique_index(:instruction_pack_entries, [:type, :target]))

    create table(:instruction_pack_downloads, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:pack_id, :string, null: false)
      add(:version, :bigint, null: false)
      add(:digest, :string, null: false)
      add(:envelope, :binary, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:instruction_pack_downloads, [:pack_id, :version]))
  end
end
