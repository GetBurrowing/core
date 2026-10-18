defmodule Platform.Files.ServiceClient do
  @moduledoc """
  HTTP client for the Burrow [files-service](https://github.com/Startup-Suite/files-service).

  Per ADR (files extraction split-out, 2026-06-19) binary-format text
  extraction (PDF, DOCX, OCR'd images) is delegated to a separate Python
  microservice rather than shelling out to `pdftotext` / `pandoc` /
  `tesseract` inside the Elixir release. This keeps the BEAM image lean
  and lets extraction tooling iterate independently from the platform
  monolith — same pattern as `Platform.Memory.Providers.MemoryService` and
  the `memory-service` repo.

  The service exposes a single extraction endpoint:

  - `POST /extract` — multipart upload (`file` part = bytes, form-field
    `content_type` = MIME). Returns `{text, pages, metadata}` on 200,
    415 on unsupported MIME, 500 with `error: tool_unavailable` when a
    backend binary is missing.

  Configuration is read from `config :platform, :files_service, ...`
  (set by `apps/platform/config/runtime.exs` when `FILES_SERVICE_URL`
  is present in the environment). When the env var is unset, the config
  key is absent and `extract/2` short-circuits with
  `{:error, :service_disabled}` — no log spam, no telemetry, just a
  clean signal to the caller that extraction isn't available in this
  environment.

  ## Return shape

      @spec extract(binary(), String.t()) ::
              {:ok, %{text: String.t(), pages: [String.t()] | nil}}
              | {:error, :service_disabled | :unsupported_type | :tool_unavailable | term()}

  Telemetry events:

    * `[:platform, :files, :extracted]` —
      measurements: `%{duration: native, text_bytes: integer()}`
      metadata: `%{content_type: String.t()}`
    * `[:platform, :files, :error]` —
      measurements: `%{duration: native}`
      metadata: `%{content_type, reason}`
  """

  @default_timeout 30_000

  @type ok_result :: %{text: String.t(), pages: [String.t()] | nil}

  @spec extract(binary(), String.t()) ::
          {:ok, ok_result()}
          | {:error, :service_disabled | :unsupported_type | :tool_unavailable | term()}
  def extract(bytes, content_type) when is_binary(bytes) and is_binary(content_type) do
    config = Application.get_env(:platform, :files_service, [])
    base_url = Keyword.get(config, :base_url)

    if is_binary(base_url) and base_url != "" do
      do_extract(bytes, content_type, config)
    else
      {:error, :service_disabled}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp do_extract(bytes, content_type, config) do
    base_url = Keyword.fetch!(config, :base_url)
    url = String.trim_trailing(base_url, "/") <> "/extract"
    timeout = Keyword.get(config, :timeout, @default_timeout)
    monotonic_start = System.monotonic_time()

    form_multipart = [
      file: {bytes, filename: "upload", content_type: content_type},
      content_type: content_type
    ]

    headers =
      [{"accept", "application/json"}]
      |> maybe_add_bearer(config)

    opts = [
      method: :post,
      url: url,
      headers: headers,
      form_multipart: form_multipart,
      receive_timeout: timeout
    ]

    case Req.request(req_client(), opts) do
      {:ok, %{status: 200, body: %{"text" => text} = body_map}} ->
        pages = Map.get(body_map, "pages")
        duration = System.monotonic_time() - monotonic_start

        emit(:extracted, %{duration: duration, text_bytes: byte_size(text)}, %{
          content_type: content_type
        })

        {:ok, %{text: text, pages: pages}}

      {:ok, %{status: 415}} ->
        duration = System.monotonic_time() - monotonic_start

        emit(:error, %{duration: duration}, %{
          content_type: content_type,
          reason: :unsupported_type
        })

        {:error, :unsupported_type}

      {:ok, %{status: 500, body: %{"error" => "tool_unavailable"}}} ->
        duration = System.monotonic_time() - monotonic_start

        emit(:error, %{duration: duration}, %{
          content_type: content_type,
          reason: :tool_unavailable
        })

        {:error, :tool_unavailable}

      {:ok, %{status: status, body: body}} ->
        duration = System.monotonic_time() - monotonic_start

        emit(:error, %{duration: duration}, %{
          content_type: content_type,
          reason: {:http, status}
        })

        {:error, {:http, status, body}}

      {:error, reason} ->
        duration = System.monotonic_time() - monotonic_start

        emit(:error, %{duration: duration}, %{
          content_type: content_type,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp req_client do
    Application.get_env(:platform, :files_service_req_client, Req.new())
  end

  defp maybe_add_bearer(headers, config) do
    case Keyword.get(config, :token) do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | headers]

      _ ->
        headers
    end
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute(
      [:platform, :files, event],
      Map.merge(%{system_time: System.system_time()}, measurements),
      metadata
    )
  rescue
    _ -> :ok
  end
end
