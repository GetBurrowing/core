defmodule Platform.Files.Extractor.GDoc do
  @moduledoc """
  Google Docs extractor — stub.

  Google Docs aren't extracted through `files-service`. They live in
  Drive and we get their text via the Drive `files.export` API
  (`mimeType=text/plain`). That code path is owned by a follow-up
  workstream (see task `019ee080-7004-7b69-aead-c45dc4f47d76`), at
  which point this module will be replaced by a real Drive client.

  For now, `extract/1` returns `{:error, :handled_externally}` so the
  Files dispatch surface still resolves `application/vnd.google-apps.document`
  to a known module. Callers (the ingester) treat `:handled_externally`
  as a signal that the file should be skipped — Drive export happens in
  the caller, not here.
  """

  alias Platform.Files.File, as: FileRow

  @spec extract(FileRow.t() | binary()) :: {:error, :handled_externally}
  def extract(%FileRow{}), do: {:error, :handled_externally}
  def extract(bytes) when is_binary(bytes), do: {:error, :handled_externally}
end
