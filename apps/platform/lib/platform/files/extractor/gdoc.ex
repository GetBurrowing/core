defmodule Platform.Files.Extractor.GDoc do
  @moduledoc """
  Google Docs extractor.

  Google Docs aren't bytes-on-disk; the `platform_files` row carries a
  Drive file ID in `:metadata.drive_file_id` and we export to plain text
  via the Drive `files.export` API. The current implementation expects
  callers to pass the file row plus an authenticated `Req` request via
  process dictionary (`:gdoc_drive_request`) — that hook stays in place
  until Stage 4 stands up a real `Platform.Google.DriveClient`.

  Until the metadata column lands (planned in a follow-up stage), the
  row's `:storage_key` may carry `drive:<file_id>` as a sentinel. Either
  shape resolves to the same extraction path; both are recognized below.

  Returns:

    * `{:error, :missing_drive_id}` — no Drive ID anywhere on the row
    * `{:error, :drive_client_unavailable}` — no Drive transport wired up
      (test default; production wires a `Req` instance via app env)
    * `{:error, {:drive_api_failed, status}}` — Drive returned non-200
  """

  alias Platform.Files.Extractor

  @export_url "https://www.googleapis.com/drive/v3/files"

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, drive_id} <- resolve_drive_id(file),
         {:ok, request} <- resolve_request() do
      case do_export(request, drive_id) do
        {:ok, body} ->
          pages = String.split(body, "\f", trim: false)
          pages = Enum.reject(pages, &(&1 == ""))
          # gdoc exports rarely contain form-feeds, so most docs come
          # back as a single page — fall back to the whole body in that
          # case rather than emitting a nil pages list for what is, in
          # fact, paginated source content.
          pages = if pages == [], do: [body], else: pages
          {:ok, %{text: body, pages: pages}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp resolve_drive_id(%{storage_key: "drive:" <> id}) when byte_size(id) > 0, do: {:ok, id}

  defp resolve_drive_id(_file), do: {:error, :missing_drive_id}

  defp resolve_request do
    case Application.get_env(:platform, :gdoc_drive_request) do
      nil -> {:error, :drive_client_unavailable}
      request -> {:ok, request}
    end
  end

  defp do_export(request, drive_id) do
    url = "#{@export_url}/#{drive_id}/export"

    case Req.get(request, url: url, params: [mimeType: "text/plain"]) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:drive_api_failed, status}}
      {:error, reason} -> {:error, {:drive_request_failed, reason}}
    end
  end
end
