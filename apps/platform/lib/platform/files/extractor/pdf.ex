defmodule Platform.Files.Extractor.PDF do
  @moduledoc """
  PDF text extractor — delegates to the external `files-service` via
  `Platform.Files.ServiceClient`.

  The service uses `pypdf` (with a `pdftotext` fallback for layout
  preservation) to extract text and returns the page list. When the
  service is unreachable / unconfigured, the caller sees
  `{:error, :service_disabled}` (no service configured) or
  `{:error, :tool_unavailable}` (configured but the extraction backend
  is missing in the container).
  """

  alias Platform.Files.Extractor
  alias Platform.Files.ServiceClient

  @content_type "application/pdf"

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    ServiceClient.extract(bytes, @content_type)
  end
end
