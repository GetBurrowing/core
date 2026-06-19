defmodule Platform.Files.Extractor.PDF do
  @moduledoc """
  PDF text extractor — shells out to `pdftotext` (poppler-utils).

  Pages are split on the form-feed character (`\\f`), which is what
  `pdftotext` emits between pages by default.

  Returns `{:error, :tool_unavailable}` when `pdftotext` is not on
  `$PATH` so callers can render the gap instead of crashing.
  """

  alias Platform.Files.Extractor

  @binary "pdftotext"

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, _path_to_binary} <- ensure_binary(),
         {:ok, path} <- Extractor.local_path(file),
         {:ok, output} <- run(path) do
      pages = String.split(output, "\f", trim: false)
      # pdftotext typically emits a trailing form-feed → drop the empty
      # tail page so the list reflects the actual page count.
      pages = drop_trailing_empty(pages)
      {:ok, %{text: Enum.join(pages, "\n\n"), pages: pages}}
    end
  end

  defp ensure_binary do
    case System.find_executable(@binary) do
      nil -> {:error, :tool_unavailable}
      path -> {:ok, path}
    end
  end

  defp run(path) do
    case System.cmd(@binary, ["-layout", path, "-"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:pdftotext_failed, code, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:pdftotext_crashed, Exception.message(e)}}
  end

  defp drop_trailing_empty(pages) do
    case Enum.reverse(pages) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> pages
    end
  end
end
