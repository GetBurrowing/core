defmodule Platform.InstructionPacks.Pack do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "instruction_packs" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
