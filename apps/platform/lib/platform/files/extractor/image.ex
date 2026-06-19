defmodule Platform.Files.Extractor.Image do
  @moduledoc """
  Image OCR via `tesseract`.

  When the binary isn't on `$PATH` we return `{:error, :ocr_unavailable}`
  rather than raising — same shape as the other extractors but explicitly
  named so callers can route around the gap (e.g. mark the file as
  "OCR pending" instead of "extraction failed").

  Tesseract writes output to a `<base>.txt` next to its input. We point
  it at a temp basename inside `System.tmp_dir!/0`, read the .txt back,
  and clean up.
  """

  alias Platform.Files.Extractor

  @binary "tesseract"

  @spec extract(Platform.Files.File.t()) ::
          {:ok, Extractor.ok_result()} | {:error, term()}
  def extract(file) do
    with {:ok, _path_to_binary} <- ensure_binary(),
         {:ok, path} <- Extractor.local_path(file),
         {:ok, text} <- run(path) do
      {:ok, %{text: text, pages: nil}}
    end
  end

  defp ensure_binary do
    case System.find_executable(@binary) do
      nil -> {:error, :ocr_unavailable}
      path -> {:ok, path}
    end
  end

  defp run(path) do
    base =
      Path.join(
        System.tmp_dir!(),
        "platform-files-ocr-#{System.unique_integer([:positive])}"
      )

    try do
      case System.cmd(@binary, [path, base], stderr_to_stdout: true) do
        {_output, 0} ->
          case File.read(base <> ".txt") do
            {:ok, body} -> {:ok, body}
            {:error, reason} -> {:error, {:tesseract_output_missing, reason}}
          end

        {output, code} ->
          {:error, {:tesseract_failed, code, String.trim(output)}}
      end
    rescue
      e in ErlangError -> {:error, {:tesseract_crashed, Exception.message(e)}}
    after
      File.rm(base <> ".txt")
    end
  end
end
