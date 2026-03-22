defmodule Platform.Agents.Session do
  @moduledoc """
  Schema for the `agent_sessions` table.

  Tracks individual agent execution sessions, including their status,
  context snapshot, model used, and token usage.
  Sessions may be nested via parent_session_id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(running completed failed cancelled)

  schema "agent_sessions" do
    belongs_to(:agent, Platform.Agents.Agent)
    field(:parent_session_id, :binary_id)
    field(:status, :string, default: "running")
    field(:context_snapshot, :map)
    field(:model_used, :string)
    field(:token_usage, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :agent_id,
      :parent_session_id,
      :status,
      :context_snapshot,
      :model_used,
      :token_usage,
      :started_at,
      :ended_at
    ])
    |> validate_required([:agent_id, :status, :started_at])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
