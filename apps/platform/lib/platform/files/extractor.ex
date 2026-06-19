defmodule Platform.Files.Extractor do
  @moduledoc """
  Per-format text extractor dispatch for `Platform.Files.File` rows.

  The Stage 3 ingester calls `extract/1` to get a string body suitable for
  embedding + (optionally) a per-page split. The result is a pure function
  of the file row + the bytes referenced by its `:storage_key` — no
  GenServers, no caching, no concurrency. The caller fans out.

  ## Result shape

      {:ok, %{text: String.t(), pages: [String.t()] | nil}}

  `:pages` is only populated for paginated formats (PDF, Google Docs).
  Flow formats (CSV, plain text, OCR'd images) keep `:pages` nil and
  return the full body under `:text`.

  ## Dispatch table

  Dispatch is on `file.content_type`. Unknown MIME types return
  `{:error, {:unsupported_content_type, ct}}`.

    * `application/pdf` → `Platform.Files.Extractor.PDF`
    * `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
      → `Platform.Files.Extractor.DOCX`
    * `text/csv` → `Platform.Files.Extractor.CSV`
    * `text/plain`, `text/markdown` → `Platform.Files.Extractor.Text`
    * `image/png`, `image/jpeg`, `image/jpg`, `image/webp` →
      `Platform.Files.Extractor.Image`
    * `application/vnd.google-apps.document` →
      `Platform.Files.Extractor.GDoc`

  ## Tool availability

  PDF, DOCX, and Image extraction shell out to `pdftotext`, `pandoc`, and
  `tesseract` respectively. When those binaries aren't on `$PATH` (e.g.
  the hive CI box doesn't ship them) the extractor returns
  `{:error, :tool_unavailable}` (or `{:error, :ocr_unavailable}` for
  Image) so the caller can surface the gap without crashing. Production
  images install the binaries.
  """

  alias Platform.Files.File, as: FileRow

  @type ok_result :: %{text: String.t(), pages: [String.t()] | nil}

  @spec extract(FileRow.t()) :: {:ok, ok_result()} | {:error, term()}
  def extract(%FileRow{content_type: nil}), do: {:error, {:unsupported_content_type, nil}}

  def extract(%FileRow{content_type: ct} = file) do
    case dispatch(ct) do
      {:ok, module} -> module.extract(file)
      :error -> {:error, {:unsupported_content_type, ct}}
    end
  end

  defp dispatch("application/pdf"), do: {:ok, __MODULE__.PDF}

  defp dispatch("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    do: {:ok, __MODULE__.DOCX}

  defp dispatch("text/csv"), do: {:ok, __MODULE__.CSV}
  defp dispatch("text/plain"), do: {:ok, __MODULE__.Text}
  defp dispatch("text/markdown"), do: {:ok, __MODULE__.Text}
  defp dispatch("image/png"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/jpeg"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/jpg"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/webp"), do: {:ok, __MODULE__.Image}
  defp dispatch("application/vnd.google-apps.document"), do: {:ok, __MODULE__.GDoc}
  defp dispatch(_), do: :error

  @doc """
  Returns the absolute filesystem path for a stored `Platform.Files.File`
  on the local-disk adapter. Format extractors that must shell out to a
  binary use this to feed the tool a path instead of streaming bytes
  through stdin.

  Returns `{:error, :unsupported_adapter}` for non-local-disk adapters —
  the Stage 3 ingester is responsible for materializing remote bytes to a
  temp path before calling the extractor in that case.
  """
  @spec local_path(FileRow.t()) :: {:ok, Path.t()} | {:error, term()}
  def local_path(%FileRow{storage_key: nil}), do: {:error, :missing_storage_key}

  def local_path(%FileRow{storage_key: key}) do
    case Application.get_env(
           :platform,
           :attachment_storage_adapter,
           Platform.Chat.AttachmentStorage.Adapter.LocalDisk
         ) do
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk ->
        root =
          Application.get_env(:platform, :chat_attachments_root) ||
            Path.join(System.tmp_dir!(), "platform-chat-attachments")

        {:ok, Path.join(root, key)}

      _other ->
        {:error, :unsupported_adapter}
    end
  end
end
