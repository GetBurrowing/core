defmodule Platform.Files.Extractor.Image do
  @moduledoc """
  Image OCR — delegates to the external `files-service` via
  `Platform.Files.ServiceClient`.

  The service runs `pytesseract` (English) against the supplied bytes
  and returns the recognized text. The MIME type sent over the wire is
  hard-coded as `image/png` here because the upload route in the parent
  caller (Stage 5 / FilesLive) currently treats all OCR-eligible
  formats through a single dispatch; if you need to forward a specific
  MIME (`image/jpeg`, `image/webp`), call
  `ServiceClient.extract(bytes, "image/jpeg")` directly — the service
  accepts any `image/*` MIME and Pillow opens whatever it finds.
  """

  alias Platform.Files.Extractor
  alias Platform.Files.ServiceClient

  @default_content_type "image/png"

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    ServiceClient.extract(bytes, @default_content_type)
  end

  @spec extract(binary(), String.t()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes, content_type) when is_binary(bytes) and is_binary(content_type) do
    ServiceClient.extract(bytes, content_type)
  end
end
