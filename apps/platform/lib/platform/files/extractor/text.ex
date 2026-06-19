defmodule Platform.Files.Extractor.Text do
  @moduledoc """
  Pass-through extractor for `text/plain` and `text/markdown`.

  No shelling out — `File.read/1` returns the bytes unchanged. `:pages`
  is always nil; the whole document is one flow.
  """

  alias Platform.Files.Extractor

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, path} <- Extractor.local_path(file),
         {:ok, body} <- File.read(path) do
      {:ok, %{text: body, pages: nil}}
    end
  end
end
