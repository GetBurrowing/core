defmodule Platform.Agents.MemoryContext do
  @moduledoc """
  Persistent memory/workspace context for agents.

  This module is the v1 read/write layer for agent identity data described in
  ADR 0007:

    * versioned workspace files (`SOUL.md`, `MEMORY.md`, `AGENTS.md`, etc.)
    * append-only memories (`long_term`, `daily`, `snapshot`)
    * assembled runtime context for later AgentServer work

  Keyword recall is intentionally simple in v1: agent + type/date filters and a
  case-insensitive content search via `ilike/2`.
  """

  import Ecto.Query

  alias Platform.Agents.{Context, Memory, WorkspaceFile}
  alias Platform.Repo

  @memory_types ~w(long_term daily snapshot)
  @default_context_limits %{
    "long_term" => 25,
    "daily" => 7,
    "snapshot" => 5
  }

  @doc "Returns the memory types supported by the runtime."
  @spec memory_types() :: [String.t()]
  def memory_types, do: @memory_types

  @doc """
  List workspace files for an agent.

  ## Options

    * `:keys` - restrict to specific file keys (for example `["SOUL.md", "USER.md"]`)
  """
  @spec list_workspace_files(Ecto.UUID.t(), keyword()) :: [WorkspaceFile.t()]
  def list_workspace_files(agent_id, opts \\ []) do
    keys = Keyword.get(opts, :keys)

    WorkspaceFile
    |> where([wf], wf.agent_id == ^agent_id)
    |> maybe_filter_workspace_keys(keys)
    |> order_by([wf], asc: wf.file_key)
    |> Repo.all()
  end

  @doc "Fetch a single workspace file by agent + file key."
  @spec get_workspace_file(Ecto.UUID.t(), String.t()) :: WorkspaceFile.t() | nil
  def get_workspace_file(agent_id, file_key) do
    Repo.get_by(WorkspaceFile, agent_id: agent_id, file_key: file_key)
  end

  @doc """
  Create or update a workspace file.

  New files start at version `1`. Existing files increment their version on each
  successful write. When `:expected_version` is supplied, mismatches return
  `{:error, :stale_workspace_file}` instead of overwriting.
  """
  @spec upsert_workspace_file(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, WorkspaceFile.t()} | {:error, Ecto.Changeset.t() | :stale_workspace_file}
  def upsert_workspace_file(agent_id, file_key, content, opts \\ []) do
    expected_version = Keyword.get(opts, :expected_version)

    Repo.transaction(fn ->
      case Repo.get_by(WorkspaceFile, agent_id: agent_id, file_key: file_key) do
        nil ->
          %WorkspaceFile{}
          |> WorkspaceFile.changeset(%{agent_id: agent_id, file_key: file_key, content: content})
          |> Repo.insert()
          |> unwrap_or_rollback()

        %WorkspaceFile{} = workspace_file ->
          if not is_nil(expected_version) and workspace_file.version != expected_version do
            Repo.rollback(:stale_workspace_file)
          else
            workspace_file
            |> WorkspaceFile.changeset(%{
              content: content,
              version: workspace_file.version + 1
            })
            |> Repo.update()
            |> unwrap_or_rollback()
          end
      end
    end)
    |> normalize_transaction_result()
  end

  @doc """
  Append a new memory entry.

  ## Options

    * `:date` - explicit `Date` for daily memories (defaults to `Date.utc_today/0`)
    * `:metadata` - arbitrary metadata map
  """
  @spec append_memory(Ecto.UUID.t(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, Memory.t()} | {:error, Ecto.Changeset.t()}
  def append_memory(agent_id, memory_type, content, opts \\ []) do
    memory_type = normalize_memory_type(memory_type)

    attrs = %{
      agent_id: agent_id,
      memory_type: memory_type,
      date: normalize_memory_date(memory_type, Keyword.get(opts, :date)),
      content: content,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    result =
      %Memory{}
      |> Memory.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, memory} ->
        :telemetry.execute(
          [:platform, :agent, :memory_written],
          %{system_time: System.system_time()},
          %{
            agent_id: agent_id,
            memory_id: memory.id,
            memory_type: memory.memory_type,
            date: memory.date
          }
        )

        {:ok, memory}

      error ->
        error
    end
  end

  @doc """
  List memories for an agent with optional type/date/query filters.

  ## Options

    * `:memory_type` - `"long_term" | "daily" | "snapshot"` (or atom equivalent)
    * `:date_from` - include memories on/after this `Date`
    * `:date_to` - include memories on/before this `Date`
    * `:query` - case-insensitive substring match on content
    * `:limit` - max results to return (default: 50)
  """
  @spec list_memories(Ecto.UUID.t(), keyword()) :: [Memory.t()]
  def list_memories(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Memory
    |> where([m], m.agent_id == ^agent_id)
    |> maybe_filter_memory_type(Keyword.get(opts, :memory_type))
    |> maybe_filter_date_from(Keyword.get(opts, :date_from))
    |> maybe_filter_date_to(Keyword.get(opts, :date_to))
    |> maybe_filter_query(Keyword.get(opts, :query))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Recall memories with a keyword query.

  This is the v1 recall API described in ADR 0007. It delegates to
  `list_memories/2` with a required `:query` filter.
  """
  @spec recall_memories(Ecto.UUID.t(), String.t(), keyword()) :: [Memory.t()]
  def recall_memories(agent_id, query, opts \\ []) when is_binary(query) do
    list_memories(agent_id, Keyword.put(opts, :query, query))
  end

  @doc """
  Build the runtime context for an agent/session.

  ## Options

    * `:session_id` - associated session UUID
    * `:workspace_keys` - restrict loaded workspace files
    * `:memory_types` - subset of memory types to load (default: all)
    * `:query` - optional recall filter applied to loaded memories
    * `:date_from` / `:date_to` - optional memory date filters
    * `:limit` - shared limit for all memory types
    * `:<type>_limit` - per-type limit (`:daily_limit`, `:snapshot_limit`, etc.)
  """
  @spec build_context(Ecto.UUID.t(), keyword()) :: Context.t()
  def build_context(agent_id, opts \\ []) do
    workspace =
      agent_id
      |> list_workspace_files(keys: Keyword.get(opts, :workspace_keys))
      |> Map.new(fn workspace_file -> {workspace_file.file_key, workspace_file.content} end)

    memory_types = normalize_memory_types(Keyword.get(opts, :memory_types, @memory_types))

    shared_memory_filters =
      opts
      |> Keyword.take([:query, :date_from, :date_to])
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    memory =
      Map.new(memory_types, fn memory_type ->
        limit =
          per_type_limit(opts, memory_type)

        bucket =
          list_memories(
            agent_id,
            Keyword.merge(shared_memory_filters, memory_type: memory_type, limit: limit)
          )

        {String.to_atom(memory_type), bucket}
      end)

    %Context{
      agent_id: agent_id,
      session_id: Keyword.get(opts, :session_id),
      workspace: workspace,
      memory: memory,
      metadata: %{
        memory_types: memory_types,
        query: Keyword.get(opts, :query),
        date_from: Keyword.get(opts, :date_from),
        date_to: Keyword.get(opts, :date_to)
      }
    }
  end

  defp maybe_filter_workspace_keys(query, nil), do: query
  defp maybe_filter_workspace_keys(query, []), do: where(query, [wf], false)
  defp maybe_filter_workspace_keys(query, keys), do: where(query, [wf], wf.file_key in ^keys)

  defp maybe_filter_memory_type(query, nil), do: query

  defp maybe_filter_memory_type(query, memory_type) do
    where(query, [m], m.memory_type == ^normalize_memory_type(memory_type))
  end

  defp maybe_filter_date_from(query, nil), do: query
  defp maybe_filter_date_from(query, %Date{} = date), do: where(query, [m], m.date >= ^date)

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, %Date{} = date), do: where(query, [m], m.date <= ^date)

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

  defp normalize_memory_type(memory_type) when memory_type in [:long_term, :daily, :snapshot],
    do: Atom.to_string(memory_type)

  defp normalize_memory_type(memory_type) when memory_type in @memory_types, do: memory_type
  defp normalize_memory_type(memory_type), do: to_string(memory_type)

  defp normalize_memory_date("daily", nil), do: Date.utc_today()
  defp normalize_memory_date(_memory_type, date), do: date

  defp normalize_memory_types(types) when is_list(types),
    do: Enum.map(types, &normalize_memory_type/1)

  defp per_type_limit(opts, memory_type) do
    per_type_key = String.to_atom("#{memory_type}_limit")

    Keyword.get(
      opts,
      per_type_key,
      Keyword.get(opts, :limit, Map.fetch!(@default_context_limits, memory_type))
    )
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
