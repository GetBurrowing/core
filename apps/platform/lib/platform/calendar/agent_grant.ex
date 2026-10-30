defmodule Platform.Calendar.AgentGrant do
  @moduledoc "An owner's live, revocable delegation to one agent."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_agent_grants" do
    field(:owner_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:read, :boolean, default: false)
    field(:read_private, :boolean, default: false)
    field(:create, :boolean, default: false)
    field(:move, :boolean, default: false)
    field(:preapprove, :boolean, default: false)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:read, :read_private, :create, :move, :preapprove])
    |> unique_constraint([:owner_id, :agent_id])
  end
end
