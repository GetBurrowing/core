defmodule Platform.Chat.AttachmentStorage do
  @moduledoc """
  Thin dispatcher over a pluggable storage adapter (ADR 0039 phase 2).

  The public surface (persist_upload/3, delete/1, delete_many/1, path_for/1,
  storage_root/0, ensure_writable!/0) stays stable for all existing callers.
  Internally, persist/delete/read now route through the configured adapter;
  LocalDisk-specific filesystem accessors continue to resolve against the
  local-disk adapter until an S3/R2 implementation makes a different shape
  necessary.
  """

  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk

  @storage_prefix "chat"

  @spec persist_upload(binary(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_upload(temp_path, client_name, client_type \\ nil) do
    persist_source({:path, temp_path}, client_name, client_type)
  end

  @doc """
  Same as `persist_upload/3`, but for content that only ever exists as an
  in-memory binary — never written to a local path by the caller.

  Task 01a0d4a0 stage 5: `send_media`'s hand-off callers can be a remote MCP
  client (a `services/meeting-voice-agent` worker running in its own
  container) that has no filesystem in common with Core. Passing a local
  path in that shape is a guaranteed `:enoent` on Core's side — a path is
  only ever meaningful on the filesystem that wrote it. This entry point
  lets `Platform.Federation.ToolSurface`'s `send_media` accept the content
  itself (already decoded from the wire, e.g. base64) and hand it straight
  to the storage adapter's own `{:binary, bytes}` clause
  (`Platform.Chat.AttachmentStorage.Adapter.LocalDisk.persist/2`), with no
  temp file anywhere in the path.
  """
  @spec persist_binary_upload(binary(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_binary_upload(bytes, client_name, client_type \\ nil) when is_binary(bytes) do
    persist_source({:binary, bytes}, client_name, client_type)
  end

  defp persist_source(source, client_name, client_type) do
    filename = sanitize_filename(client_name || "attachment")
    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    stored_name = "#{Ecto.UUID.generate()}-#{filename}"
    storage_key = Path.join([@storage_prefix, bucket, stored_name])

    # Infer from the raw client_name (not the sanitized filename) because
    # sanitization could in principle strip the extension and silently break
    # MIME inference. `safe_infer/1` is allowlist-gated so passing attacker-
    # controlled raw input here is still safe.
    inference_hint = client_name || filename

    case adapter().persist(storage_key, source) do
      {:ok, %{byte_size: size, content_hash: hash}} ->
        {:ok,
         %{
           filename: client_name || filename,
           content_type: normalize_content_type(client_type, inference_hint),
           byte_size: size,
           storage_key: storage_key,
           content_hash: hash,
           metadata: %{}
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @spec delete(binary()) :: :ok
  def delete(storage_key), do: adapter().delete(storage_key)

  @spec delete_many([map()]) :: :ok
  def delete_many(attachments) do
    Enum.each(attachments, fn
      %{storage_key: storage_key} -> delete(storage_key)
      _ -> :ok
    end)

    :ok
  end

  defdelegate path_for(storage_key), to: LocalDisk
  defdelegate storage_root(), to: LocalDisk
  defdelegate ensure_writable!(), to: LocalDisk

  defp adapter do
    Application.get_env(:platform, :attachment_storage_adapter, LocalDisk)
  end

  # Only override a missing or generic client-reported MIME type when the
  # extension-inferred type is in this allowlist. Restricting to formats that
  # browsers render without script execution avoids turning a filename-based
  # override into a stored-XSS path — e.g. an attacker uploading `evil.html`
  # with client_type = "application/octet-stream" must NOT be re-labeled
  # text/html and served inline.
  # SVG is intentionally excluded — SVG can embed <script>.
  # text/* is intentionally excluded — text/html executes as HTML.
  @safe_override_types ~w(
    image/jpeg
    image/png
    image/gif
    image/webp
    image/heic
    image/heif
    application/pdf
  )

  defp normalize_content_type(nil, filename), do: safe_infer(filename)
  defp normalize_content_type("", filename), do: safe_infer(filename)

  # iOS Safari and some mobile browsers label photos "application/octet-stream"
  # on upload. Trust the filename extension over that generic label, but only
  # when it resolves to a known-safe image MIME type.
  defp normalize_content_type("application/octet-stream", filename),
    do: safe_infer(filename)

  defp normalize_content_type(content_type, _filename), do: content_type

  defp safe_infer(filename) do
    inferred = MIME.from_path(filename)
    if inferred in @safe_override_types, do: inferred, else: "application/octet-stream"
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "attachment"
      sanitized -> sanitized
    end
  end
end
