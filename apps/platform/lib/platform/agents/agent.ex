defmodule Platform.Agents.Agent do
  @moduledoc """
  Schema for the `agents` table.

  An Agent is a named, configurable AI agent within a workspace.
  Agents can be active, paused, or archived, and may have a parent agent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(active paused archived)

  schema "agents" do
    field(:workspace_id, :binary_id)
    field(:slug, :string)
    field(:name, :string)
    field(:status, :string, default: "active")
    field(:model_config, :map, default: %{})
    field(:tools_config, :map, default: %{})
    field(:thinking_default, :string)
    field(:heartbeat_config, :map, default: %{})
    field(:max_concurrent, :integer, default: 1)
    field(:sandbox_mode, :string, default: "off")
    field(:parent_agent_id, :binary_id)
    field(:metadata, :map, default: %{})
    field(:runtime_type, :string, default: "built_in")
    field(:runtime_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :workspace_id,
      :slug,
      :name,
      :status,
      :model_config,
      :tools_config,
      :thinking_default,
      :heartbeat_config,
      :max_concurrent,
      :sandbox_mode,
      :parent_agent_id,
      :metadata,
      :runtime_type,
      :runtime_id
    ])
    |> validate_required([:slug, :name, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:slug,
      name: :agents_unique_slug,
      message: "slug already taken in this workspace"
    )
  end
end
