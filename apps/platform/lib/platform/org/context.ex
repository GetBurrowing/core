defmodule Platform.Org.Context do
  @moduledoc """
  Business logic for org-level context files and memory entries.

  Provides CRUD for versioned context files (ORG_IDENTITY.md, etc.),
  append-only memory entries (daily, long_term), and a `build_context/1`
  function that assembles workspace files and recent daily entries into a
  map suitable for injection into agent sessions.
  """

  import Ecto.Query

  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  # ── Context files ────────────────────────────────────────────────────

  @doc "Fetch a single context file by file_key, optionally scoped to a workspace."
  @spec get_context_file(String.t(), binary() | nil) :: ContextFile.t() | nil
  def get_context_file(file_key, workspace_id \\ nil) do
    ContextFile
    |> where([f], f.file_key == ^file_key)
    |> filter_workspace(workspace_id)
    |> Repo.one()
  end

  @doc """
  List all context files for a workspace.

  ## Options

    * `:workspace_id` - scope to a specific workspace (default: nil)
  """
  @spec list_context_files(keyword()) :: [ContextFile.t()]
  def list_context_files(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    ContextFile
    |> filter_workspace(workspace_id)
    |> order_by([f], asc: f.file_key)
    |> Repo.all()
  end

  @doc """
  Create or update a context file with optimistic locking.

  New files start at version 1. Existing files increment their version on
  each successful write. When `:expected_version` is supplied, a mismatch
  returns `{:error, :stale}`.
  """
  @spec upsert_context_file(String.t(), map(), keyword()) ::
          {:ok, ContextFile.t()} | {:error, Ecto.Changeset.t() | :stale}
  def upsert_context_file(file_key, attrs, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    expected_version = Keyword.get(opts, :expected_version)

    Repo.transaction(fn ->
      existing =
        ContextFile
        |> where([f], f.file_key == ^file_key)
        |> filter_workspace(workspace_id)
        |> Repo.one()

      case existing do
        nil ->
          %ContextFile{}
          |> ContextFile.changeset(
            Map.merge(attrs, %{file_key: file_key, workspace_id: workspace_id})
          )
          |> Repo.insert()
          |> unwrap_or_rollback()

        %ContextFile{} = file ->
          if not is_nil(expected_version) and file.version != expected_version do
            Repo.rollback(:stale)
          else
            file
            |> ContextFile.changeset(%{
              content: Map.get(attrs, :content, Map.get(attrs, "content")),
              updated_by: Map.get(attrs, :updated_by, Map.get(attrs, "updated_by")),
              version: file.version + 1
            })
            |> Repo.update()
            |> unwrap_or_rollback()
          end
      end
    end)
    |> tap_ok(fn file ->
      :telemetry.execute(
        [:platform, :org, :context_file_written],
        %{system_time: System.system_time()},
        %{file_key: file.file_key, version: file.version, workspace_id: file.workspace_id}
      )
    end)
    |> normalize_transaction_result()
  end

  # ── Memory entries ───────────────────────────────────────────────────

  @doc """
  Append a memory entry.

  Attrs should include `:content`, `:date`, and optionally `:memory_type`,
  `:workspace_id`, `:authored_by`, `:metadata`.
  """
  @spec append_memory_entry(map(), keyword()) ::
          {:ok, MemoryEntry.t()} | {:error, Ecto.Changeset.t()}
  def append_memory_entry(attrs, opts \\ []) do
    attrs = maybe_put_workspace(attrs, Keyword.get(opts, :workspace_id))

    result =
      %MemoryEntry{}
      |> MemoryEntry.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        :telemetry.execute(
          [:platform, :org, :memory_entry_written],
          %{system_time: System.system_time()},
          %{
            memory_entry_id: entry.id,
            memory_type: entry.memory_type,
            date: entry.date,
            workspace_id: entry.workspace_id
          }
        )

        {:ok, entry}

      error ->
        error
    end
  end

  @doc """
  Search memory entries with optional filters.

  ## Options

    * `:query` - case-insensitive substring match on content
    * `:memory_type` - filter by memory type
    * `:date_from` - include entries on/after this date
    * `:date_to` - include entries on/before this date
    * `:workspace_id` - scope to a workspace
    * `:limit` - max results (default: 50)
  """
  @spec search_memory_entries(keyword()) :: [MemoryEntry.t()]
  def search_memory_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)

    MemoryEntry
    |> filter_workspace(workspace_id)
    |> maybe_filter_memory_type(Keyword.get(opts, :memory_type))
    |> maybe_filter_date_from(Keyword.get(opts, :date_from))
    |> maybe_filter_date_to(Keyword.get(opts, :date_to))
    |> maybe_filter_query(Keyword.get(opts, :query))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  # ── Build context ────────────────────────────────────────────────────

  @doc """
  Assemble org context for injection into an agent session.

  Returns a map of filename => content, including workspace context files
  and the last 2 days of daily memory entries as `ORG_NOTES-YYYY-MM-DD`.

  ## Options

    * `:workspace_id` - scope to a workspace (default: nil)
  """
  @spec build_context(keyword()) :: %{String.t() => String.t()}
  def build_context(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    files =
      list_context_files(workspace_id: workspace_id)
      |> Map.new(fn f -> {f.file_key, f.content} end)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    daily_entries =
      search_memory_entries(
        workspace_id: workspace_id,
        memory_type: "daily",
        date_from: yesterday,
        date_to: today,
        limit: 1000
      )

    notes =
      daily_entries
      |> Enum.group_by(& &1.date)
      |> Enum.into(%{}, fn {date, entries} ->
        content =
          entries
          |> Enum.sort_by(& &1.inserted_at, DateTime)
          |> Enum.map_join("\n", & &1.content)

        {"ORG_NOTES-#{Date.to_iso8601(date)}", content}
      end)

    Map.merge(files, notes)
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp filter_workspace(queryable, nil) do
    where(queryable, [r], is_nil(r.workspace_id))
  end

  defp filter_workspace(queryable, workspace_id) do
    where(queryable, [r], r.workspace_id == ^workspace_id)
  end

  defp maybe_filter_memory_type(query, nil), do: query

  defp maybe_filter_memory_type(query, type) do
    where(query, [m], m.memory_type == ^to_string(type))
  end

  defp maybe_filter_date_from(query, nil), do: query
  defp maybe_filter_date_from(query, %Date{} = d), do: where(query, [m], m.date >= ^d)

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, %Date{} = d), do: where(query, [m], m.date <= ^d)

  defp maybe_filter_query(queryable, nil), do: queryable
  defp maybe_filter_query(queryable, ""), do: queryable

  defp maybe_filter_query(queryable, query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      queryable
    else
      pattern = "%#{trimmed}%"
      where(queryable, [m], ilike(m.content, ^pattern))
    end
  end

  defp maybe_put_workspace(attrs, nil), do: attrs

  defp maybe_put_workspace(attrs, workspace_id) when is_map(attrs) do
    Map.put(attrs, :workspace_id, workspace_id)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp tap_ok({:ok, value}, fun) do
    fun.(value)
    {:ok, value}
  end

  defp tap_ok(error, _fun), do: error

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
