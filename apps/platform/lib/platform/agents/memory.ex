defmodule Platform.Agents.Memory do
  @moduledoc """
  Schema for the `agent_memories` table.

  Uses a bigserial primary key for monotonic ordering (ADR 0005).
  Supports long-term, daily, and snapshot memory types.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  @valid_memory_types ~w(long_term daily snapshot)

  schema "agent_memories" do
    belongs_to(:agent, Platform.Agents.Agent)
    field(:memory_type, :string)
    field(:date, :date)
    field(:content, :string)
    field(:metadata, :map, default: %{})
    field(:inserted_at, :utc_datetime_usec, autogenerate: false)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:agent_id, :memory_type, :date, :content, :metadata])
    |> validate_required([:agent_id, :memory_type, :content])
    |> validate_inclusion(:memory_type, @valid_memory_types)
  end
end
