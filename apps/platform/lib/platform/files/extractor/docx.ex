defmodule Platform.Files.Extractor.DOCX do
  @moduledoc """
  DOCX text extractor — delegates to the external `files-service` via
  `Platform.Files.ServiceClient`.

  The service uses `pypandoc` to convert DOCX → plain text. Pages aren't
  meaningful for DOCX (pagination is renderer-dependent) so `:pages`
  comes back nil.
  """

  alias Platform.Files.Extractor
  alias Platform.Files.ServiceClient

  @content_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    ServiceClient.extract(bytes, @content_type)
  end
end
