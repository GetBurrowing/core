defmodule Platform.Files.Extractor.Text do
  @moduledoc """
  Pass-through extractor for `text/plain` and `text/markdown`.

  No HTTP, no shelling out — the bytes ARE the text. `:pages` is always
  nil; the whole document is one flow.
  """

  alias Platform.Files.Extractor

  @spec extract(binary()) :: {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(bytes) when is_binary(bytes) do
    {:ok, %{text: bytes, pages: nil}}
  end
end
