defmodule Platform.Repo.Migrations.CreateInstructionPackChecks do
  use Ecto.Migration

  @moduledoc "Persist catalog/pull status before first pack for task 01a1b6e1-4995-7000-b918-fb305d219275. Consent remains exclusively in install_sharing."
  def change do
    create table(:instruction_pack_checks, primary_key: false) do
      add(:singleton, :boolean, primary_key: true, default: true)
      add(:pending, :boolean, null: false, default: false)
      add(:checked_at, :utc_datetime_usec)
      add(:last_successful_check_at, :utc_datetime_usec)
      add(:error_kind, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:instruction_pack_checks, :instruction_pack_checks_singleton,
        check: "singleton = true"
      )
    )
  end
end
