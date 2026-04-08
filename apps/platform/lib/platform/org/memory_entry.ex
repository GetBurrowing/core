defmodule Platform.Org.MemoryEntry do
  @moduledoc """
  Schema for org-level memory entries (daily notes, long-term memories).

  These entries mirror OpenClaw's daily memory files (memory/YYYY-MM-DD.md)
  but at the organizational level. Agents append entries to record decisions,
  milestones, and notable events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @memory_types ~w(daily long_term)

  schema "org_memory_entries" do
    field(:workspace_id, :binary_id)
    field(:memory_type, :string, default: "daily")
    field(:date, :date)
    field(:content, :string)
    field(:authored_by, :binary_id)
    field(:metadata, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @required ~w(content date)a
  @optional ~w(workspace_id memory_type authored_by metadata)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:memory_type, @memory_types)
  end
end
