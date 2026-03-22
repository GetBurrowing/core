defmodule Platform.Agents.ContextShare do
  @moduledoc """
  Schema for the `agent_context_shares` table.

  Records context sharing events between agent sessions.
  Supports full, memory_only, config_only, and custom scopes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_scopes ~w(full memory_only config_only custom)

  schema "agent_context_shares" do
    field(:from_session_id, :binary_id)
    field(:to_session_id, :binary_id)
    field(:scope, :string)
    field(:scope_filter, :map)
    field(:delta, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(context_share, attrs) do
    context_share
    |> cast(attrs, [:from_session_id, :to_session_id, :scope, :scope_filter, :delta])
    |> validate_required([:from_session_id, :to_session_id, :scope])
    |> validate_inclusion(:scope, @valid_scopes)
  end
end
