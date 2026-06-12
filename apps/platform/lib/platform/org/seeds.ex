defmodule Platform.Org.Seeds do
  @moduledoc """
  Seeds default org context files on first boot.

  Inserts the default org wiki pages (`org/page/identity.md`,
  `org/page/memory.md`, `org/page/agents.md`) if they don't already
  exist. Idempotent — safe to call multiple times.

  Keys follow the T5 routing page grammar (`<ns>/page/<rest>`) so the
  seeded defaults are recognised by the memory_* gates (rolled forward
  from the flat `org/*.md` form by migration `20260611120000`).

  Legacy V1 callers using the uppercase `ORG_*.md` keys continue to
  resolve through the alias table backfilled by migration
  `20260519210000_path_style_file_keys_and_alias_backfill`; flat
  path-style keys (`org/identity.md`) resolve through the aliases
  backfilled by `20260611120000`.
  """

  alias Platform.Repo
  alias Platform.Org.WikiPage

  @default_files %{
    "org/page/identity.md" => """
    # Org Identity

    _Describe your organization here — mission, values, what you're building._

    This file is shared with all agents on session start. Keep it concise and current.
    """,
    "org/page/memory.md" => """
    # Org Memory

    _Curated long-term memory for the organization._

    Record key decisions, architectural choices, lessons learned, and anything
    agents should remember across sessions. Agents can read and append to this file.
    """,
    "org/page/agents.md" => """
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
          from(f in WikiPage,
            where: f.workspace_id == ^workspace_id and f.file_key == ^file_key
          )
        else
          from(f in WikiPage,
            where: is_nil(f.workspace_id) and f.file_key == ^file_key
          )
        end

      exists? = Repo.exists?(query)

      unless exists? do
        Repo.insert!(%WikiPage{
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
