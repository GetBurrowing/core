defmodule Platform.Org.Context do
  @moduledoc """
  Context module for org-level shared context management.

  Provides CRUD for org context files (ORG_IDENTITY.md, ORG_MEMORY.md,
  ORG_AGENTS.md, ORG_DIRECTORY.md) and append + search for org memory
  entries (daily notes and long-term memories).

  The `build_context/1` function assembles the full org context bundle
  for injection into agent sessions — workspace files plus recent daily
  notes, mirroring OpenClaw's MEMORY.md + memory/YYYY-MM-DD.md pattern.

  ## Telemetry

  Emits telemetry events on write operations:
    - `[:platform, :org_context, :file_updated]` — when a context file is upserted
    - `[:platform, :org_context, :memory_appended]` — when a memory entry is appended
  """

  import Ecto.Query

  alias Platform.Org.{ContextFile, MemoryEntry}
  alias Platform.Repo

  # ── Context Files ─────────────────────────────────────────────────────────

  @doc """
  Get a single org context file by file_key, optionally scoped to a workspace.

  Returns `{:ok, file}` if found, `{:error, :not_found}` otherwise.
  """
  def get_context_file(file_key, workspace_id \\ nil) do
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

    case Repo.one(query) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  List all org context files, optionally scoped to a workspace.

  Returns files ordered by file_key for stable output.
  """
  def list_context_files(workspace_id \\ nil) do
    query =
      if workspace_id do
        from(f in ContextFile,
          where: f.workspace_id == ^workspace_id,
          order_by: f.file_key
        )
      else
        from(f in ContextFile,
          where: is_nil(f.workspace_id),
          order_by: f.file_key
        )
      end

    Repo.all(query)
  end

  @doc """
  Upsert an org context file with optimistic locking.

  On insert: creates the file with version 1.
  On update: applies `update_changeset/2` which uses `optimistic_lock/1` to
  detect concurrent modification. Increments version on each successful update.

  Emits `[:platform, :org_context, :file_updated]` telemetry on success.

  Returns `{:ok, file}` or `{:error, changeset}`.

  ## Options
    - `:updated_by` — UUID of the agent or user performing the update
  """
  def upsert_context_file(file_key, content, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    updated_by = Keyword.get(opts, :updated_by)

    result =
      case get_context_file(file_key, workspace_id) do
        {:ok, existing} ->
          existing
          |> ContextFile.update_changeset(%{content: content, updated_by: updated_by})
          |> Repo.update()

        {:error, :not_found} ->
          %ContextFile{}
          |> ContextFile.changeset(%{
            file_key: file_key,
            content: content,
            workspace_id: workspace_id,
            updated_by: updated_by
          })
          |> Repo.insert()
      end

    case result do
      {:ok, file} ->
        :telemetry.execute(
          [:platform, :org_context, :file_updated],
          %{system_time: System.system_time()},
          %{
            file_key: file_key,
            workspace_id: workspace_id,
            version: file.version,
            updated_by: updated_by
          }
        )

        {:ok, file}

      error ->
        error
    end
  end

  # ── Memory Entries ────────────────────────────────────────────────────────

  @doc """
  Append a new org memory entry.

  Memory entries are append-only — they represent a log of decisions,
  milestones, and notable events at the org level.

  Emits `[:platform, :org_context, :memory_appended]` telemetry on success.

  ## Options
    - `:workspace_id` — scope to a specific workspace (nil = default)
    - `:authored_by` — UUID of the agent or user authoring the entry
    - `:memory_type` — "daily" (default) or "long_term"
    - `:date` — entry date (defaults to today UTC)
    - `:metadata` — map of additional metadata (tags, source, etc.)
  """
  def append_memory(content, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    authored_by = Keyword.get(opts, :authored_by)
    memory_type = Keyword.get(opts, :memory_type, "daily")
    date = Keyword.get(opts, :date, Date.utc_today())
    metadata = Keyword.get(opts, :metadata, %{})

    result =
      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        workspace_id: workspace_id,
        content: content,
        authored_by: authored_by,
        memory_type: memory_type,
        date: date,
        metadata: metadata
      })
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        :telemetry.execute(
          [:platform, :org_context, :memory_appended],
          %{system_time: System.system_time()},
          %{
            entry_id: entry.id,
            workspace_id: workspace_id,
            memory_type: memory_type,
            date: date,
            authored_by: authored_by
          }
        )

        {:ok, entry}

      error ->
        error
    end
  end

  @doc """
  Search org memory entries by content (case-insensitive substring match).

  ## Options
    - `:workspace_id` — scope to a specific workspace (nil = default/global)
    - `:memory_type` — filter to "daily" or "long_term" (nil = both)
    - `:date_from` — filter entries on or after this date
    - `:date_to` — filter entries on or before this date
    - `:limit` — max entries to return (default 50)
  """
  def search_memory(query_string, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    memory_type = Keyword.get(opts, :memory_type)
    date_from = Keyword.get(opts, :date_from)
    date_to = Keyword.get(opts, :date_to)
    limit = Keyword.get(opts, :limit, 50)

    pattern = "%#{String.replace(query_string, "%", "\\%")}%"

    MemoryEntry
    |> where([e], ilike(e.content, ^pattern))
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_memory_type(memory_type)
    |> maybe_filter_date_from(date_from)
    |> maybe_filter_date_to(date_to)
    |> order_by([e], desc: e.date, desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  List org memory entries with optional filters.

  ## Options
    - `:workspace_id` — scope to a specific workspace (nil = default/global)
    - `:memory_type` — filter to "daily" or "long_term" (nil = both)
    - `:date_from` — filter entries on or after this date
    - `:date_to` — filter entries on or before this date
    - `:limit` — max entries to return (default 50)
  """
  def list_memory_entries(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    memory_type = Keyword.get(opts, :memory_type)
    date_from = Keyword.get(opts, :date_from)
    date_to = Keyword.get(opts, :date_to)
    limit = Keyword.get(opts, :limit, 50)

    MemoryEntry
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_memory_type(memory_type)
    |> maybe_filter_date_from(date_from)
    |> maybe_filter_date_to(date_to)
    |> order_by([e], desc: e.date, desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ── Context Bundle Assembly ───────────────────────────────────────────────

  @doc """
  Assemble the full org context bundle for injection into agent sessions.

  Returns a map with:
    - `"ORG_IDENTITY.md"` — the org identity file content
    - `"ORG_MEMORY.md"` — the long-term org memory file content
    - `"ORG_AGENTS.md"` — agent conventions and guidelines
    - `"ORG_DIRECTORY.md"` — auto-generated org directory
    - `"ORG_NOTES-YYYY-MM-DD"` — last 2 days of daily memory entries,
      formatted as date-keyed markdown notes (mirrors OpenClaw's daily
      memory/YYYY-MM-DD.md pattern)

  ## Options
    - `:workspace_id` — scope to a specific workspace (nil = default)
    - `:days_back` — how many days of daily notes to include (default 2)
  """
  def build_context(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    days_back = Keyword.get(opts, :days_back, 2)

    # Fetch all context files
    files = list_context_files(workspace_id)
    file_map = Map.new(files, &{&1.file_key, &1.content})

    # Fill in defaults for missing files
    workspace_files = %{
      "ORG_IDENTITY.md" => Map.get(file_map, "ORG_IDENTITY.md", ""),
      "ORG_MEMORY.md" => Map.get(file_map, "ORG_MEMORY.md", ""),
      "ORG_AGENTS.md" => Map.get(file_map, "ORG_AGENTS.md", ""),
      "ORG_DIRECTORY.md" => Map.get(file_map, "ORG_DIRECTORY.md", "")
    }

    # Fetch last N days of daily memory entries
    today = Date.utc_today()
    cutoff = Date.add(today, -days_back + 1)

    daily_entries =
      list_memory_entries(
        workspace_id: workspace_id,
        memory_type: "daily",
        date_from: cutoff
      )

    # Group entries by date and format as ORG_NOTES-YYYY-MM-DD keys
    daily_notes =
      daily_entries
      |> Enum.group_by(& &1.date)
      |> Enum.map(fn {date, entries} ->
        date_str = Calendar.strftime(date, "%Y-%m-%d")
        key = "ORG_NOTES-#{date_str}"

        content =
          entries
          |> Enum.sort_by(& &1.inserted_at)
          |> Enum.map_join("\n\n---\n\n", & &1.content)

        {key, content}
      end)
      |> Map.new()

    Map.merge(workspace_files, daily_notes)
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp maybe_filter_workspace(query, nil), do: where(query, [e], is_nil(e.workspace_id))

  defp maybe_filter_workspace(query, workspace_id),
    do: where(query, [e], e.workspace_id == ^workspace_id)

  defp maybe_filter_memory_type(query, nil), do: query

  defp maybe_filter_memory_type(query, memory_type),
    do: where(query, [e], e.memory_type == ^memory_type)

  defp maybe_filter_date_from(query, nil), do: query
  defp maybe_filter_date_from(query, date), do: where(query, [e], e.date >= ^date)

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, date), do: where(query, [e], e.date <= ^date)
end
