defmodule Platform.Org.Seeds do
  @moduledoc """
  Seeds default org context files on first boot.

  Inserts the default org context files (ORG_IDENTITY.md, ORG_MEMORY.md,
  ORG_AGENTS.md) if they don't already exist.
  Idempotent — safe to call multiple times.
  """

  alias Platform.Repo
  alias Platform.Org.ContextFile

  @default_files %{
    "ORG_IDENTITY.md" => """
    # Org Identity

    _Describe your organization here — mission, values, what you're building._

    This file is shared with all agents on session start. Keep it concise and current.
    """,
    "ORG_MEMORY.md" => """
    # Org Memory

    _Curated long-term memory for the organization._

    Record key decisions, architectural choices, lessons learned, and anything
    agents should remember across sessions. Agents can read and append to this file.
    """,
    "ORG_AGENTS.md" => """
    # Org Agents

    _Shared conventions and guidelines for all agents in this organization._

    Document workflows, coding standards, review processes, deployment procedures,
    and any other conventions agents should follow.
    """
  }

  @doc """
  Seeds default org context files. Inserts only missing files.
  Uses workspace_id = nil for the default (single-tenant) workspace.
  """
  def seed_defaults(workspace_id \\ nil) do
    import Ecto.Query

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(@default_files, fn {file_key, content} ->
      query =
        if workspace_id do
          from(f in ContextFile,
            where: f.workspace_id == ^workspace_id and f.file_key == ^file_key
          )
        else
          from(f in ContextFile,
            where: is_nil(f.workspace_id) and f.file_key == ^file_key
          )
        end

      exists? = Repo.exists?(query)

      unless exists? do
        Repo.insert!(%ContextFile{
          workspace_id: workspace_id,
          file_key: file_key,
          content: String.trim(content),
          version: 1,
          inserted_at: now,
          updated_at: now
        })
      end
    end)

    :ok
  end
end
