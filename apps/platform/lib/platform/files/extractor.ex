defmodule Platform.Files.Extractor do
  @moduledoc """
  Per-format text extractor dispatch for `Platform.Files.File` rows.

  The Stage 3 ingester calls `extract/1` (FileRow) to get a string body
  suitable for embedding + (optionally) a per-page split. Binary formats
  (PDF, DOCX, image OCR) are delegated to the external `files-service`
  via `Platform.Files.ServiceClient`; pure-text formats (text, csv) are
  handled in-process.

  ## Result shape

      {:ok, %{text: String.t(), pages: [String.t()] | nil}}

  `:pages` is only populated for paginated formats (PDF, Google Docs).
  Flow formats (CSV, plain text, OCR'd images) keep `:pages` nil.

  ## Dispatch table

  Dispatch is on `file.content_type`. Unknown MIME types return
  `{:error, {:unsupported_content_type, ct}}`.

  `supported_content_type?/1` is the canonical predicate for "will this
  MIME extract?" — it asks the same private `dispatch/1` clauses the
  extractor itself routes through, so the two cannot drift. The
  default-ingestion-intent logic in `Platform.Files` keys off it.

    * `application/pdf` → `Platform.Files.Extractor.PDF`
    * `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
      → `Platform.Files.Extractor.DOCX`
    * `text/csv` → `Platform.Files.Extractor.CSV`
    * `text/plain`, `text/markdown` → `Platform.Files.Extractor.Text`
    * `image/png`, `image/jpeg`, `image/jpg`, `image/webp` →
      `Platform.Files.Extractor.Image`
    * `application/vnd.google-apps.document` →
      `Platform.Files.Extractor.GDoc`
    * `audio/mpeg`, `audio/mp4`, `audio/x-m4a`, `audio/m4a`, `audio/wav`,
      `audio/x-wav`, `audio/webm`, `audio/ogg` →
      `Platform.Files.Extractor.Audio`

  ## Two entry points

  - `extract/1` takes a `%Platform.Files.File{}` row, resolves its bytes
    via `local_path/1`, and dispatches by MIME. This is what the
    ingester calls.
  - `extract/2` takes raw bytes + MIME directly. Useful for tests, for
    the planner's e2e_behavior cases, and for any future caller that
    already has bytes in hand (e.g. an in-memory upload).
  """

  alias Platform.Files.File, as: FileRow

  @type ok_result :: %{text: String.t(), pages: [String.t()] | nil}

  @spec extract(FileRow.t()) :: {:ok, ok_result()} | {:error, term()}
  def extract(%FileRow{content_type: nil}), do: {:error, {:unsupported_content_type, nil}}

  def extract(%FileRow{content_type: ct} = file) do
    case dispatch(ct) do
      {:ok, module} ->
        case fetch_bytes(file, module) do
          {:ok, :no_bytes_needed} -> filerow_extract(module, file)
          {:ok, bytes} -> call_extractor(module, bytes, ct)
          {:error, _} = err -> err
        end

      :error ->
        {:error, {:unsupported_content_type, ct}}
    end
  end

  # Modules supporting the bytes overload — `extract(binary())`. GDoc accepts
  # FileRow only, so it is intentionally excluded here. This is the authoritative
  # whitelist for `extract/2`; do NOT add `function_exported?/3` as an extra
  # guard — in a cold BEAM the per-format module isn't loaded until first call,
  # so the introspection check returns false and the whole dispatcher falls
  # through to `:unsupported_content_type` (e2e failure observed at task 019ee080
  # stage 3 review). Membership in this list IS the contract.
  @bytes_overload_modules [
    __MODULE__.PDF,
    __MODULE__.DOCX,
    __MODULE__.Image,
    __MODULE__.Text,
    __MODULE__.CSV,
    __MODULE__.HTML,
    __MODULE__.Audio
  ]

  @spec extract(binary(), String.t()) :: {:ok, ok_result()} | {:error, term()}
  def extract(bytes, content_type) when is_binary(bytes) and is_binary(content_type) do
    case dispatch(content_type) do
      {:ok, module} when module in @bytes_overload_modules ->
        call_extractor(module, bytes, content_type)

      {:ok, _module} ->
        {:error, {:unsupported_content_type, content_type}}

      :error ->
        {:error, {:unsupported_content_type, content_type}}
    end
  end

  # Every bytes-overload module except Audio handles exactly one MIME, so it
  # can hardcode its own content type (see PDF, DOCX, ...). Audio is the one
  # module fielding several distinct MIME types that all need to reach
  # `ServiceClient.extract/2` with the ORIGINAL content type (files-service
  # forwards it into the STT backend, so collapsing to a single audio/* value
  # would mis-decode non-default formats) — so it alone takes the 2-arg form.
  defp call_extractor(__MODULE__.Audio, bytes, content_type),
    do: __MODULE__.Audio.extract(bytes, content_type)

  defp call_extractor(module, bytes, _content_type), do: module.extract(bytes)

  # `fetch_bytes/2` answers `:no_bytes_needed` for GDoc alone — the one module
  # whose `extract/1` takes the FileRow and fetches its own content over the
  # Drive API — so this is the only reachable clause. It matches the module
  # explicitly rather than calling `module.extract(file)`, because the bare
  # dynamic call makes the compiler consider every dispatch target and Audio
  # deliberately exposes only `extract/2` (warnings-as-errors fails on it).
  # A future no-bytes module must add its own clause here; a FunctionClauseError
  # is the intended outcome of forgetting, not a silent fallthrough.
  defp filerow_extract(__MODULE__.GDoc, file), do: __MODULE__.GDoc.extract(file)

  @doc """
  True when `content_type` has an extractor, i.e. when ingestion has any
  chance of producing text. Conservative: an unknown or nil MIME answers
  `false` rather than optimistically `true`.

  Implemented by asking `dispatch/1` — the SAME clauses `extract/1` and
  `extract/2` route through. There is deliberately no
  `@supported_content_types` module attribute mirroring the dispatch
  table: a second hand-typed list drifts from the real one and the drift
  is silent. If a caller ever genuinely needs to *enumerate* supported
  types, generate that list from the clauses (e.g. via
  `__MODULE__.__info__/1` on a public dispatcher) rather than typing it
  a second time.
  """
  @spec supported_content_type?(String.t() | nil) :: boolean()
  def supported_content_type?(nil), do: false
  def supported_content_type?(content_type), do: match?({:ok, _}, dispatch(content_type))

  defp dispatch("application/pdf"), do: {:ok, __MODULE__.PDF}

  defp dispatch("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    do: {:ok, __MODULE__.DOCX}

  defp dispatch("text/csv"), do: {:ok, __MODULE__.CSV}
  defp dispatch("text/plain"), do: {:ok, __MODULE__.Text}
  defp dispatch("text/markdown"), do: {:ok, __MODULE__.Text}
  # NOT __MODULE__.Text: routing HTML at the pass-through extractor flips the
  # row to `succeeded` and indexes markup, CSS and nav chrome with no error and
  # no failed status. See the HTML module's moduledoc.
  defp dispatch("text/html"), do: {:ok, __MODULE__.HTML}
  defp dispatch("image/png"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/jpeg"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/jpg"), do: {:ok, __MODULE__.Image}
  defp dispatch("image/webp"), do: {:ok, __MODULE__.Image}
  defp dispatch("application/vnd.google-apps.document"), do: {:ok, __MODULE__.GDoc}
  defp dispatch("audio/mpeg"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/mp4"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/x-m4a"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/m4a"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/wav"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/x-wav"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/webm"), do: {:ok, __MODULE__.Audio}
  defp dispatch("audio/ogg"), do: {:ok, __MODULE__.Audio}
  defp dispatch(_), do: :error

  # GDoc never reads bytes off disk (it goes through Drive's export API
  # — or in the current stage, returns :handled_externally). Skip the
  # local_path step for it; the per-format module deals with the row.
  defp fetch_bytes(_file, __MODULE__.GDoc), do: {:ok, :no_bytes_needed}

  defp fetch_bytes(%FileRow{} = file, _module) do
    with {:ok, path} <- local_path(file),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    end
  end

  @doc """
  Returns the absolute filesystem path for a stored `Platform.Files.File`
  on the local-disk adapter.

  Returns `{:error, :unsupported_adapter}` for non-local-disk adapters —
  callers must materialize remote bytes to a temp path before calling
  the extractor in that case.
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
        # Unchanged app-env resolution, wrapped so a test process can own its
        # own root instead of repointing a VM-global key that its concurrently
        # running siblings also read. See `Platform.Chat.AttachmentStorage.Root`.
        root =
          Platform.Chat.AttachmentStorage.Root.get(
            Application.get_env(:platform, :chat_attachments_root) ||
              Path.join(System.tmp_dir!(), "platform-chat-attachments")
          )

        {:ok, Path.join(root, key)}

      _other ->
        {:error, :unsupported_adapter}
    end
  end
end
