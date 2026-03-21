defmodule Platform.Chat.SpaceAgent do
  @moduledoc """
  Schema for the `chat_space_agents` table.

  Each entry defines an agent's role within a space's roster:

    * `"principal"` — the default responder for unaddressed messages (exactly one per space)
    * `"member"`    — available for @-mention but does not handle unaddressed messages
    * `"dismissed"` — soft-removed from the roster; preserved for re-invite
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(principal member dismissed)

  schema "chat_space_agents" do
    belongs_to(:space, Platform.Chat.Space)
    belongs_to(:agent, Platform.Agents.Agent)

    field(:role, :string, default: "member")
    field(:dismissed_by, :binary_id)
    field(:dismissed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(space_agent, attrs) do
    space_agent
    |> cast(attrs, [:space_id, :agent_id, :role, :dismissed_by, :dismissed_at])
    |> validate_required([:space_id, :agent_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:space_id, :agent_id], name: :chat_space_agents_space_agent_unique)
    |> unique_constraint(:space_id, name: :chat_space_agents_principal_unique)
    |> foreign_key_constraint(:dismissed_by, name: :chat_space_agents_dismissed_by_fkey)
  end
end
