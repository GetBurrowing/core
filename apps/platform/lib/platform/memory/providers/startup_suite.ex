defmodule Platform.Memory.Providers.StartupSuite do
  @moduledoc """
  Memory provider that connects to the Startup Suite external memory service.

  Communicates via HTTP (Req) with endpoints:
  - `POST /ingest` — index a memory entry
  - `POST /search` — semantic search over indexed entries
  - `DELETE /entries` — remove entries from the index

  Configured when `MEMORY_SERVICE_URL` is set. See ADR 0033.
  """

  @behaviour Platform.Memory.Provider

  require Logger

  @receive_timeout 10_000

  @impl true
  def ingest(entry) do
    case Req.post(req_client(), url: "/ingest", json: %{entries: [serialize_entry(entry)]}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Memory service ingest returned #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("Memory service ingest request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def search(query, opts) do
    body =
      %{
        query: query,
        workspace_id: Keyword.get(opts, :workspace_id),
        memory_type: Keyword.get(opts, :memory_type),
        date_from: format_date(Keyword.get(opts, :date_from)),
        date_to: format_date(Keyword.get(opts, :date_to)),
        limit: Keyword.get(opts, :limit, 50)
      }
      |> reject_nils()

    case Req.post(req_client(), url: "/search", json: body) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize_search_result/1)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Memory service search returned #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("Memory service search request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def delete(entry_id) do
    case Req.request(req_client(),
           method: :delete,
           url: "/entries",
           json: %{entry_ids: [entry_id]}
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Memory service delete returned #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("Memory service delete request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp req_client do
    case Application.get_env(:platform, :memory_service_req_client) do
      nil ->
        Req.new(
          base_url: memory_service_url(),
          headers: [{"accept", "application/json"}],
          receive_timeout: @receive_timeout
        )

      client ->
        client
    end
  end

  defp memory_service_url do
    Application.get_env(:platform, :memory_service_url) ||
      raise "MEMORY_SERVICE_URL not configured but StartupSuite provider is active"
  end

  defp serialize_entry(entry) do
    %{
      id: entry.id,
      content: entry.content,
      memory_type: to_string(entry.memory_type),
      date: format_date(entry.date),
      workspace_id: entry.workspace_id,
      metadata: entry.metadata || %{}
    }
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = d), do: Date.to_iso8601(d)
  defp format_date(s) when is_binary(s), do: s

  defp normalize_search_result(%{"entry_id" => id, "score" => score}) do
    %{entry_id: id, score: score}
  end

  defp normalize_search_result(%{"entry_id" => id}) do
    %{entry_id: id, score: 0.0}
  end

  defp reject_nils(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
