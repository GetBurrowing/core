defmodule Platform.Agents.WorkspaceFile do
  @moduledoc """
  Schema for the `agent_workspace_files` table.

  Stores workspace files (SOUL.md, MEMORY.md, AGENTS.md, etc.) for an agent.
  Each file is versioned and identified by a key within the agent's scope.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_workspace_files" do
    belongs_to(:agent, Platform.Agents.Agent)
    field(:file_key, :string)
    field(:content, :string, default: "")
    field(:version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace_file, attrs) do
    workspace_file
    |> cast(attrs, [:agent_id, :file_key, :content, :version])
    |> validate_required([:agent_id, :file_key, :content])
    |> unique_constraint(:file_key,
      name: :agent_workspace_files_unique_key,
      message: "file key already exists for this agent"
    )
  end
end
