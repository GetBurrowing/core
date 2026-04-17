defmodule Platform.Memory do
  @moduledoc """
  Entry point for the memory-service integration — semantic ingest, search,
  and deletion of org memory entries via a pluggable provider.

  The concrete provider is chosen at runtime via application config:

      config :platform, :memory_service,
        provider: Platform.Memory.Providers.StartupSuite,
        base_url: "http://memory-service:8100",
        api_key: "optional-shared-secret",
        model: "embeddings",
        timeout: 5_000

  When `MEMORY_SERVICE_URL` isn't set at boot the provider falls back to
  `Platform.Memory.Providers.Noop` so the app still starts and the existing
  keyword-search path keeps working.

  ## Typical flow

      {:ok, entry} = Platform.Org.Context.append_memory_entry(attrs)
      Platform.Memory.ingest([entry])  # fire-and-forget embed + index

      {:ok, hits} = Platform.Memory.search("what did we decide about the db",
        workspace_id: ws_id, limit: 10)
      # -> [%{entry_id: "01...", score: 0.87}, ...]
  """

  require Logger

  @type entry :: Platform.Memory.Provider.entry()
  @type search_result :: Platform.Memory.Provider.search_result()

  @doc """
  Returns `true` when a real provider (anything other than Noop) is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: provider() != Platform.Memory.Providers.Noop

  @doc """
  Ingest memory entries for embedding + indexing.

  Accepts structs (e.g. `%Platform.Org.MemoryEntry{}`) or maps with the
  required shape (see `Platform.Memory.Provider.entry/0`). Normalizes each
  entry into the payload the provider expects.
  """
  @spec ingest([entry() | struct()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ingest(entries, opts \\ []) when is_list(entries) do
    payload = Enum.map(entries, &normalize/1)
    provider().ingest(payload, Keyword.merge(config(), opts))
  end

  @doc """
  Vector-search memory entries by natural-language query.

  Returns `{:ok, [%{entry_id, score}]}` ordered by descending similarity.
  """
  @spec search(String.t(), Platform.Memory.Provider.search_opts(), keyword()) ::
          {:ok, [search_result()]} | {:error, term()}
  def search(query, opts \\ [], provider_opts \\ []) when is_binary(query) do
    provider().search(query, opts, Keyword.merge(config(), provider_opts))
  end

  @doc "Remove entries from the vector index by id."
  @spec delete([String.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete(entry_ids, opts \\ []) when is_list(entry_ids) do
    provider().delete(entry_ids, Keyword.merge(config(), opts))
  end

  @doc "Health check against the memory service."
  @spec health(keyword()) :: :ok | {:error, term()}
  def health(opts \\ []), do: provider().health(Keyword.merge(config(), opts))

  @doc """
  Ingest asynchronously — spawned task logs on failure and never blocks the
  caller. Use this from write paths (like `append_memory_entry`) so Postgres
  writes don't wait on the embed round-trip.
  """
  @spec ingest_async([entry() | struct()]) :: :ok
  def ingest_async(entries) when is_list(entries) do
    if enabled?() do
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        case ingest(entries) do
          {:ok, _count} ->
            :ok

          {:error, reason} ->
            ids = Enum.map(entries, & &1.id)

            Logger.warning(
              "Platform.Memory async ingest failed for #{inspect(ids)}: #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp provider do
    Keyword.get(config(), :provider, Platform.Memory.Providers.Noop)
  end

  defp config, do: Application.get_env(:platform, :memory_service, [])

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(%{} = attrs) do
    %{
      id: to_string(Map.get(attrs, :id) || Map.get(attrs, "id")),
      content: Map.get(attrs, :content) || Map.get(attrs, "content"),
      memory_type:
        (Map.get(attrs, :memory_type) || Map.get(attrs, "memory_type") || "daily")
        |> to_string(),
      date: normalize_date(Map.get(attrs, :date) || Map.get(attrs, "date")),
      workspace_id:
        nil_or_string(Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id")),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    }
  end

  defp normalize_date(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize_date(date) when is_binary(date), do: date
  defp normalize_date(nil), do: nil

  defp nil_or_string(nil), do: nil
  defp nil_or_string(v), do: to_string(v)
end
