defmodule Platform.Agents.AgentRuntime do
  @moduledoc """
  Schema for the `agent_runtimes` table.

  Represents an external agent runtime (e.g. an OpenClaw instance) that
  connects to the Suite collaboration plane via WebSocket.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending active suspended revoked)
  @valid_trust_levels ~w(viewer participant collaborator admin)
  @valid_transports ~w(websocket)

  schema "agent_runtimes" do
    field(:runtime_id, :string)
    field(:owner_user_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:display_name, :string)
    field(:transport, :string, default: "websocket")
    field(:status, :string, default: "pending")
    field(:trust_level, :string, default: "participant")
    field(:capabilities, {:array, :string}, default: [])
    field(:auth_token_hash, :string)
    field(:last_connected_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(runtime, attrs) do
    runtime
    |> cast(attrs, [
      :runtime_id,
      :owner_user_id,
      :agent_id,
      :display_name,
      :transport,
      :status,
      :trust_level,
      :capabilities,
      :auth_token_hash,
      :last_connected_at,
      :metadata
    ])
    |> validate_required([:runtime_id, :owner_user_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:trust_level, @valid_trust_levels)
    |> validate_inclusion(:transport, @valid_transports)
    |> unique_constraint(:runtime_id)
  end

  @doc "Hash a raw token for storage."
  def hash_token(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  @doc "Generate a cryptographically random token."
  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "Verify a raw token against a stored hash."
  def verify_token(raw_token, stored_hash) do
    hash_token(raw_token) == stored_hash
  end
end
