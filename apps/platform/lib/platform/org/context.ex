defmodule Platform.Org.Context do
  @moduledoc """
  Business logic for org-level context files and memory entries.

  Provides CRUD for versioned context files (ORG_IDENTITY.md, etc.),
  append-only memory entries (daily, long_term), and a `build_context/1`
  function that assembles workspace files and recent daily entries into a
  map suitable for injection into agent sessions.

  ## Quick reference

      Platform.Org.Context.list_files()
      Platform.Org.Context.get_file("ORG_IDENTITY.md")
      Platform.Org.Context.upsert_file(%{file_key: "ORG_IDENTITY.md", content: "# Our Org", updated_by: user_id})
      Platform.Org.Context.delete_file("CUSTOM_FILE.md")
  """

  import Ecto.Query
  require Logger

  alias Platform.Memory
  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  # ── Default templates ─────────────────────────────────────────────────

  @default_templates %{
    "ORG_IDENTITY.md" => """
    # Organization Identity

    ## Mission
    _What is your organization's mission?_

    ## Values
    _What principles guide your team?_

    ## Product Summary
    _Brief description of what you're building._

    ## Team
    _Who are the key people and what are their roles?_
    """,
    "ORG_MEMORY.md" => """
    # Organization Memory

    Long-term curated knowledge for the organization. Agents reference this
    for persistent context about decisions, patterns, and institutional knowledge.

    ## Key Decisions
    _Record important decisions and their rationale here._

    ## Patterns & Conventions
    _Document recurring patterns, naming conventions, and standards._

    ## Lessons Learned
    _Capture insights from past experiences._
    """,
    "ORG_AGENTS.md" => """
    # Organization Agents

    Registry of agents and their roles within the organization.

    ## Active Agents

    | Agent | Role | Capabilities |
    |-------|------|-------------|
    | _agent-name_ | _role_ | _what it does_ |

    ## Agent Guidelines
    _Shared guidelines for how agents should behave._
    """
  }

  @doc "Returns the default template content for a given file key, or nil."
  def default_template(file_key), do: Map.get(@default_templates, file_key)

  @doc "Returns the map of all default templates."
  def default_templates, do: @default_templates

  # ── Context files ────────────────────────────────────────────────────

  @doc "Fetch a single context file by file_key, optionally scoped to a workspace."
  @spec get_context_file(String.t(), binary() | nil) :: ContextFile.t() | nil
  def get_context_file(file_key, workspace_id \\ nil) do
    ContextFile
    |> where([f], f.file_key == ^file_key)
    |> filter_workspace(workspace_id)
    |> Repo.one()
  end

  @doc "Gets a single org context file by file_key. Alias for `get_context_file/2`."
  def get_file(file_key, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    get_context_file(file_key, workspace_id)
  end

  @doc "Gets a single org context file by ID."
  def get_file_by_id(id) do
    Repo.get(ContextFile, id)
  end

  @doc """
  List all context files, optionally scoped to a workspace.

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

  @doc "Lists all org context files, ordered by file_key. Alias for `list_context_files/1`."
  def list_files(opts \\ []), do: list_context_files(opts)

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

  @doc """
  Creates or updates an org context file (simple interface).
  On update, the version is incremented.
  """
  def upsert_file(attrs) do
    file_key = Map.get(attrs, :file_key) || Map.get(attrs, "file_key")
    content = Map.get(attrs, :content) || Map.get(attrs, "content")
    updated_by = Map.get(attrs, :updated_by) || Map.get(attrs, "updated_by")

    upsert_context_file(file_key, %{content: content, updated_by: updated_by})
  end

  @doc "Deletes a context file. Returns {:ok, file} or {:error, :not_found}."
  def delete_file(file_key) do
    case get_file(file_key) do
      nil -> {:error, :not_found}
      file -> Repo.delete(file)
    end
  end

  @doc """
  Seeds default org context files if they don't already exist.
  Typically called during application startup or from a migration seed.
  """
  def seed_defaults(opts \\ []) do
    updated_by = Keyword.get(opts, :updated_by)

    Enum.each(@default_templates, fn {file_key, template} ->
      case get_file(file_key) do
        nil ->
          %ContextFile{}
          |> ContextFile.changeset(%{
            file_key: file_key,
            content: template,
            updated_by: updated_by
          })
          |> Repo.insert!()

        _exists ->
          :ok
      end
    end)
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

        # Fire-and-forget: embed + index via memory-service if configured.
        # Entry is already durably in Postgres; failures are logged and can
        # be backfilled later via the /sync endpoint.
        Memory.ingest_async([entry])

        {:ok, entry}

      error ->
        error
    end
  end

  @doc "Appends a new memory entry. Alias for `append_memory_entry/2`."
  def append_memory(attrs), do: append_memory_entry(attrs)

  @doc """
  Search memory entries with optional filters.

  When `:query` is provided and a memory-service provider is configured
  (see `Platform.Memory`), results are ranked by semantic similarity via
  vector search. Without `:query` — or when memory-service is unreachable
  — this falls back to plain SQL filters ordered by `inserted_at desc`.

  ## Options

    * `:query` - natural-language query for semantic retrieval (falls back
      to case-insensitive substring match if memory-service is unavailable)
    * `:memory_type` - filter by memory type
    * `:date_from` - include entries on/after this date
    * `:date_to` - include entries on/before this date
    * `:workspace_id` - scope to a workspace
    * `:limit` - max results (default: 50)
  """
  @spec search_memory_entries(keyword()) :: [MemoryEntry.t()]
  def search_memory_entries(opts \\ []) do
    query = Keyword.get(opts, :query)

    if is_binary(query) and query != "" and Memory.enabled?() do
      vector_search_memory_entries(query, opts) || sql_search_memory_entries(opts)
    else
      sql_search_memory_entries(opts)
    end
  end

  @doc """
  Vector-search variant that returns `[{entry, score}]` for callers that
  need the similarity score alongside the entry (e.g. the `org_memory_search`
  tool). Returns `nil` when memory-service is unavailable so callers can
  decide whether to fall back.
  """
  @spec search_memory_with_scores(String.t(), keyword()) ::
          [{MemoryEntry.t(), float()}] | nil
  def search_memory_with_scores(query, opts \\ []) when is_binary(query) do
    with true <- Memory.enabled?(),
         {:ok, hits} <- Memory.search(query, memory_search_opts(opts)) do
      entries_by_id =
        hits
        |> Enum.map(& &1.entry_id)
        |> fetch_entries_by_ids(Keyword.get(opts, :workspace_id))
        |> Map.new(fn entry -> {entry.id, entry} end)

      hits
      |> Enum.flat_map(fn %{entry_id: id, score: score} ->
        case Map.get(entries_by_id, id) do
          nil -> []
          entry -> [{entry, score}]
        end
      end)
    else
      false ->
        nil

      {:error, reason} ->
        Logger.warning("Platform.Memory.search failed: #{inspect(reason)}")
        nil
    end
  end

  defp vector_search_memory_entries(query, opts) do
    case search_memory_with_scores(query, opts) do
      nil -> nil
      results -> Enum.map(results, fn {entry, _score} -> entry end)
    end
  end

  defp sql_search_memory_entries(opts) do
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

  defp fetch_entries_by_ids([], _workspace_id), do: []

  defp fetch_entries_by_ids(ids, workspace_id) do
    MemoryEntry
    |> where([m], m.id in ^ids)
    |> filter_workspace(workspace_id)
    |> Repo.all()
  end

  defp memory_search_opts(opts) do
    opts
    |> Keyword.take([:workspace_id, :memory_type, :date_from, :date_to, :limit])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Searches org memory entries. Alias for `search_memory_entries/1`."
  def search_memory(opts \\ []), do: search_memory_entries(opts)

  @doc "Returns recent memory entries grouped by date (last N days)."
  def recent_memory(days \\ 7, opts \\ []) do
    date_from = Date.add(Date.utc_today(), -days)

    search_memory_entries(Keyword.merge(opts, date_from: date_from))
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
  end

  @doc "Fetches memory entries by a list of IDs."
  @spec get_memory_entries_by_ids([binary()]) :: [MemoryEntry.t()]
  def get_memory_entries_by_ids([]), do: []

  def get_memory_entries_by_ids(ids) do
    MemoryEntry
    |> where([m], m.id in ^ids)
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

  defp maybe_filter_date_from(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_from(query, date)
      _ -> query
    end
  end

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, %Date{} = d), do: where(query, [m], m.date <= ^d)

  defp maybe_filter_date_to(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_to(query, date)
      _ -> query
    end
  end

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
