defmodule Platform.Files.Extractor.Audio do
  @moduledoc """
  Audio transcription extractor — delegates to the external
  `files-service` via `Platform.Files.ServiceClient`.

  The service transcribes audio through an external STT backend (gated
  there by `STT_BASE_URL`) and returns the transcript text. When the
  service is unreachable / unconfigured, the caller sees
  `{:error, :service_disabled}` (no service configured) or
  `{:error, :tool_unavailable}` (configured but the transcription
  backend is missing / disabled).
  """

  alias Platform.Files.Extractor
  alias Platform.Files.ServiceClient

  @spec extract(binary(), String.t()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes, content_type) when is_binary(bytes) and is_binary(content_type) do
    ServiceClient.extract(bytes, content_type)
  end
end
