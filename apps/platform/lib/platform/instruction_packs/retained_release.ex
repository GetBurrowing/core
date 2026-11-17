defmodule Platform.InstructionPacks.RetainedRelease do
  @moduledoc "Signed bytes retained locally, never confused with publisher release storage."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "instruction_pack_downloads" do
    field(:pack_id, :string)
    field(:version, :integer)
    field(:digest, :string)
    field(:envelope, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
