defmodule Platform.Memory.Providers.MemoryService do
  @moduledoc """
  HTTP client for the Burrow [memory-service](https://github.com/Startup-Suite/memory-service).

  Implements the `Platform.Memory.Provider` behaviour by calling the
  service's OpenAI-shaped REST surface:

  - `POST /ingest`   — embed and store a batch of entries
  - `POST /search`   — vector similarity search, returns `{entry_id, score}`
    plus `memory_type` once the service supplies it (passed through as-is;
    omitted from the hit when the service does not send a non-empty tag)
  - `DELETE /entries` — remove entries from the index
  - `GET /health`    — readiness probe

  Configuration is read from `config :platform, :memory_service, ...` keyword
  list (see `Platform.Memory`). Required: `:base_url`. Optional: `:api_key`,
  `:timeout`, `:ingest_timeout`.

  ## Timeouts

  Two receive timeouts, one per kind of call:

    * `:ingest_timeout` (default 120_000ms) bounds `POST /ingest` and
      nothing else. An ingest embeds every chunk of every entry before it
      answers, so a batch of large wiki pages legitimately takes tens of
      seconds. Ingest does NOT fall back to `:timeout`: a client that gives
      up on an ingest the service is still working on, and then resends
      it, makes the service embed the same content again (task 01a0d8c9 —
      one 5-page write cost 1,880 embed calls at a 5s bound).
    * `:timeout` (default 5_000ms) bounds `/search`, `DELETE /entries` and
      `/health`. These are interactive or cheap; a slow answer there is a
      fault, and a long bound would make a caller wait on it.

  A caller that must not block long on an ingest (e.g. an ingest made
  synchronously in someone else's process) passes its own
  `ingest_timeout:` through `Platform.Memory.ingest/2`.
  """

  @behaviour Platform.Memory.Provider

  @default_timeout 5_000
  @default_ingest_timeout 120_000

  @impl true
  def ingest(entries, config) do
    timeout = Keyword.get(config, :ingest_timeout, @default_ingest_timeout)

    case request(config, :post, "/ingest", %{entries: entries}, timeout) do
      {:ok, %{status: 200, body: %{"ingested" => count}}} ->
        emit(:ingested, %{count: count}, %{})
        {:ok, count}

      {:ok, %{status: status, body: body}} ->
        emit(:error, %{}, %{op: :ingest, status: status})
        {:error, {:http, status, body}}

      {:error, reason} ->
        emit(:error, %{}, %{op: :ingest, reason: inspect(reason)})
        {:error, reason}
    end
  end

  @impl true
  def search(query, opts, config) do
    body = build_search_body(query, opts)

    case post(config, "/search", body) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        hits =
          Enum.map(results, fn r ->
            %{entry_id: r["entry_id"], score: r["score"]}
            |> maybe_put_memory_type(r["memory_type"])
          end)

        emit(:searched, %{count: length(hits)}, %{
          query_bytes: byte_size(query),
          workspace_id: Keyword.get(opts, :workspace_id),
          project_id: Keyword.get(opts, :project_id),
          org_id: Keyword.get(opts, :org_id),
          memory_type: Keyword.get(opts, :memory_type)
        })

        {:ok, hits}

      {:ok, %{status: status, body: body}} ->
        emit(:error, %{}, %{op: :search, status: status})
        {:error, {:http, status, body}}

      {:error, reason} ->
        emit(:error, %{}, %{op: :search, reason: inspect(reason)})
        {:error, reason}
    end
  end

  @impl true
  def delete(entry_ids, config) do
    case request(config, :delete, "/entries", %{entry_ids: entry_ids}) do
      {:ok, %{status: 200, body: %{"deleted" => count}}} ->
        emit(:deleted, %{count: count}, %{})
        {:ok, count}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health(config) do
    case get(config, "/health") do
      {:ok, %{status: 200, body: %{"status" => "ok"}}} -> :ok
      {:ok, %{status: 200, body: %{"status" => other}}} -> {:error, {:service_status, other}}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp post(config, path, body), do: request(config, :post, path, body)
  defp get(config, path), do: request(config, :get, path, nil)

  defp request(config, method, path, body) do
    request(config, method, path, body, Keyword.get(config, :timeout, @default_timeout))
  end

  defp request(config, method, path, body, receive_timeout) do
    base_url = Keyword.fetch!(config, :base_url)
    url = String.trim_trailing(base_url, "/") <> path

    opts =
      [
        method: method,
        url: url,
        headers: headers(config),
        receive_timeout: receive_timeout
      ]
      |> maybe_put(:json, body)

    Req.request(req_client(), opts)
  end

  defp req_client do
    Application.get_env(:platform, :memory_service_req_client, Req.new())
  end

  defp headers(config) do
    base = [{"content-type", "application/json"}]

    case Keyword.get(config, :api_key) do
      key when is_binary(key) and key != "" -> [{"x-api-key", key} | base]
      _ -> base
    end
  end

  defp build_search_body(query, opts) do
    %{query: query}
    |> maybe_put_opt(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put_opt(:project_id, Keyword.get(opts, :project_id))
    |> maybe_put_opt(:org_id, Keyword.get(opts, :org_id))
    |> maybe_put_opt(:memory_type, Keyword.get(opts, :memory_type))
    |> maybe_put_opt(:date_from, normalize_date(Keyword.get(opts, :date_from)))
    |> maybe_put_opt(:date_to, normalize_date(Keyword.get(opts, :date_to)))
    |> maybe_put_opt(:limit, Keyword.get(opts, :limit))
  end

  # The corpus tag is optional on the wire: older memory-service builds omit
  # it. Only a non-empty binary is forwarded; anything else leaves the key
  # out entirely (never `memory_type: nil`) so `Platform.Org.Wiki.Search`
  # takes its untagged id-lookup path.
  defp maybe_put_memory_type(hit, tag) when is_binary(tag) and tag != "",
    do: Map.put(hit, :memory_type, tag)

  defp maybe_put_memory_type(hit, _), do: hit

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe_put_opt(map, _key, nil), do: map
  defp maybe_put_opt(map, _key, ""), do: map
  defp maybe_put_opt(map, key, value), do: Map.put(map, key, value)

  defp normalize_date(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize_date(date), do: date

  defp emit(event, measurements, metadata) do
    :telemetry.execute(
      [:platform, :memory, event],
      Map.merge(%{system_time: System.system_time()}, measurements),
      metadata
    )
  rescue
    _ -> :ok
  end
end
