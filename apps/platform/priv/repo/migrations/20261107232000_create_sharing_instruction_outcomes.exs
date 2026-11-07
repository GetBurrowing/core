defmodule Platform.Repo.Migrations.CreateSharingInstructionOutcomes do
  @moduledoc """
  Task 01a1b6e1-4995-7000-b918-fb305d219275: stores bounded anonymous
  instruction inventory and learned-default shape windows in the shared broker.
  Adds the learned-default sharing switch to the existing install singleton,
  defaulting existing rows off; only new installer manifests explicitly opt in.
  """
  use Ecto.Migration

  def change do
    alter table(:install_sharing) do
      add(:learned_default_shapes, :boolean, null: false, default: false)
    end

    create table(:sharing_instruction_outcomes, primary_key: false) do
      add(:sharing_install_id, :uuid, null: false)
      add(:window_start, :utc_datetime, null: false)
      add(:payload, :map, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sharing_instruction_outcomes, [:sharing_install_id, :window_start]))
  end
end
