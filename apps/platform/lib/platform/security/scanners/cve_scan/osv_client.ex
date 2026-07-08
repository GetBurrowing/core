defmodule Platform.Security.Scanners.CveScan.OsvClient do
  @moduledoc """
  Thin `Req` wrapper around OSV.dev's `POST /v1/querybatch` endpoint
  (task `019f3e8e-4406` stage 3, ADR-0043).

  OSV.dev's public API is anonymous — no API key, no rate-limit
  auth. The batch endpoint accepts up to 1000 queries per request
  and returns one `vulns` list per query, positionally aligned with
  the request.

  ## Behaviour + injection seam

  A production caller invokes `query_batch/1` on this module. Tests
  override the client module via
  `Application.get_env(:platform, :cve_scan_osv_client, __MODULE__)`
  so a `MockOsv` module can return canned fixtures without ever
  hitting the network. See `Platform.Security.Scanners.CveScanTest`
  for the mock pattern.

  ## Query shape

      %{
        queries: [
          %{package: %{name: "plug", ecosystem: "Hex"}, version: "1.14.0"},
          %{package: %{name: "lodash", ecosystem: "npm"}, version: "4.17.15"}
        ]
      }

  ## Response shape

      %{
        results: [
          %{vulns: [%{id: "GHSA-...", aliases: ["CVE-2024-1234"], ...}]},
          %{vulns: []}
        ]
      }

  ## Return contract

    * `{:ok, results}` — list of per-query result maps in request order
    * `{:error, term}` — transport / HTTP / decode error; the caller
      logs at warn and moves on (a scanner network hiccup should not
      crash the sweeper)
  """

  @behaviour Platform.Security.Scanners.CveScan.OsvClientBehaviour

  require Logger

  @endpoint "https://api.osv.dev/v1/querybatch"
  @default_timeout_ms :timer.seconds(15)

  @doc """
  POST a batch of `{name, version, ecosystem}` queries to OSV.dev
  and return the raw per-query results list.

  When `queries` is empty, short-circuits to `{:ok, []}` without
  hitting the network — a repo with no lockfiles should still exit
  the scanner path cleanly.
  """
  @impl true
  @spec query_batch([map()]) :: {:ok, [map()]} | {:error, term()}
  def query_batch([]), do: {:ok, []}

  def query_batch(queries) when is_list(queries) do
    body = %{queries: queries}

    case Req.post(req_client(),
           url: @endpoint,
           json: body,
           receive_timeout: @default_timeout_ms
         ) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.warning(
          "[CveScan.OsvClient] OSV 200 body missing :results — body=#{inspect(body)}"
        )

        {:error, :malformed_body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[CveScan.OsvClient] OSV #{status} — body=#{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[CveScan.OsvClient] OSV transport error — reason=#{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("[CveScan.OsvClient] OSV client raised — #{Exception.message(error)}")

      {:error, {:exception, error}}
  end

  # Test-injection seam. Prod path builds a fresh Req client on each
  # call — the batch endpoint isn't hot enough to warrant a pooled
  # client and the fresh-client path keeps this module trivially
  # `Req.Test.stub`-able if a caller does prefer plug-based mocking
  # over the module-level `:cve_scan_osv_client` override.
  defp req_client do
    Application.get_env(
      :platform,
      :cve_scan_osv_req_client,
      Req.new(headers: [{"content-type", "application/json"}])
    )
  end
end
