defmodule Platform.Files.Extractor.DOCX do
  @moduledoc """
  DOCX text extractor — shells out to `pandoc` converting to plain text.

  `:pages` is nil; DOCX pagination depends on the rendering engine and
  isn't a property of the bytes themselves. The full body lands under
  `:text`.

  Returns `{:error, :tool_unavailable}` when `pandoc` is missing.
  """

  alias Platform.Files.Extractor

  @binary "pandoc"

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, _path_to_binary} <- ensure_binary(),
         {:ok, path} <- Extractor.local_path(file),
         {:ok, output} <- run(path) do
      {:ok, %{text: output, pages: nil}}
    end
  end

  defp ensure_binary do
    case System.find_executable(@binary) do
      nil -> {:error, :tool_unavailable}
      path -> {:ok, path}
    end
  end

  defp run(path) do
    case System.cmd(@binary, ["-f", "docx", "-t", "plain", path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:pandoc_failed, code, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:pandoc_crashed, Exception.message(e)}}
  end
end
