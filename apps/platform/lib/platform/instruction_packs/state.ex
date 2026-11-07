defmodule Platform.InstructionPacks.State do
  @moduledoc "Install-local pack selection and audit history; distinct from publisher releases."
  use Ecto.Schema
  @primary_key {:pack_id, :string, autogenerate: false}
  schema "instruction_pack_states" do
    field(:version, :integer)
    field(:highest_version, :integer, default: 0)
    field(:digest, :string)
    field(:pinned_version, :integer)
    field(:history, {:array, :map}, default: [])
    field(:applied_at, :utc_datetime_usec)
    field(:checked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
