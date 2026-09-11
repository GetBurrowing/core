defmodule Platform.Files.Storage do
  @moduledoc """
  Thin wrapper over `Platform.Chat.AttachmentStorage` for files written by
  the centralized document store (ADR 0042).

  We deliberately reuse the chat adapter so:

    * Dev / test (local disk) and prod (R2/S3) behave identically without
      a second wiring path.
    * Operators only have to mount + monitor one persistent volume.
    * The Stage 6 backfill can leave existing chat_attachments bytes in
      place and point the new `platform_files` row at the same key — no
      copy round-trip.

  ## Key layout

      files/<project_id>/<file_id>/<sha256_prefix>-<safe_filename>

  The `files/` namespace keeps the new surface visually distinct from the
  `chat/` namespace the attachments adapter already writes under, so an
  operator listing the bucket can tell them apart at a glance.

  This module does NOT generate `file_id` — callers (Stage 3 ingester,
  Stage 5 LV upload handler) build the key before insert because the
  primary key is set by the schema's UUIDv7 autogenerate. For Stage 6
  backfill the caller passes the existing chat_attachments storage_key
  through verbatim (see `passthrough_key/1`).
  """

  @namespace "files"

  @doc """
  Persists bytes (either a temp file path or an in-memory binary) under a
  project-scoped key and returns the metadata the schema needs.

  ## Returns

      {:ok, %{storage_key: key, content_hash: hex, byte_size: n}}

  …or `{:error, reason}` from the adapter.

  Callers append the returned `:storage_key`, `:content_hash`, and
  `:byte_size` to the file changeset attrs alongside their own
  `:project_id`, `:content_type`, `:original_filename`, etc.
  """
  @spec put(
          source :: {:path, Path.t()} | {:binary, binary()},
          project_id :: binary(),
          opts :: keyword()
        ) ::
          {:ok,
           %{storage_key: String.t(), content_hash: String.t(), byte_size: non_neg_integer()}}
          | {:error, term()}
  def put(source, project_id, opts \\ []) when is_binary(project_id) do
    file_id = Keyword.get(opts, :file_id, Ecto.UUID.generate())
    filename = opts |> Keyword.get(:filename, "attachment") |> sanitize_filename()
    storage_key = build_key(project_id, file_id, filename)

    case adapter().persist(storage_key, source) do
      {:ok, %{byte_size: size, content_hash: hash}} ->
        {:ok, %{storage_key: storage_key, content_hash: hash, byte_size: size}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Streams bytes back from the adapter. Returns `{:ok, stream}` or `{:error, reason}`.
  """
  @spec get(String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(storage_key) when is_binary(storage_key), do: adapter().read_stream(storage_key)

  @doc """
  Deletes the underlying object. Caller is responsible for the
  `platform_files` row; see `Platform.Files.delete_file/1`.
  """
  @spec delete(String.t()) :: :ok
  def delete(storage_key) when is_binary(storage_key), do: adapter().delete(storage_key)

  @doc """
  Returns a presigned upload URL for `storage_key`. Under the LocalDisk
  adapter (the only one on main) the URL is a host-relative signed route
  served by `PlatformWeb.ChatAttachmentUploadController`, which accepts
  the byte POST for BOTH chat (`attachment.upload_start`) and Files
  (`file_add` presigned branch) reservations and finalizes whichever
  table owns the key (task 01a091b7). A future native-presign adapter
  (R2/S3 presigned POST) would bypass that controller and needs its own
  finalize hook for `platform_files` (`Platform.Files.finalize_presigned_upload/3`).
  """
  @spec presigned_url(String.t(), keyword()) ::
          {:ok, %{url: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def presigned_url(storage_key, opts \\ []) when is_binary(storage_key) do
    max_bytes = Keyword.get(opts, :max_bytes, 50_000_000)
    ttl_s = Keyword.get(opts, :ttl_s, 900)
    adapter().presign_upload(storage_key, max_bytes, ttl_s)
  end

  @doc """
  Builds the canonical storage key for a new file.

  ## Layout

      files/<project_id>/<file_id>/<filename>

  Stable so Stage 6 backfill can compute the same key from
  chat_attachments metadata when needed.
  """
  @spec build_key(binary(), binary(), String.t()) :: String.t()
  def build_key(project_id, file_id, filename)
      when is_binary(project_id) and is_binary(file_id) and is_binary(filename) do
    Path.join([@namespace, project_id, file_id, sanitize_filename(filename)])
  end

  @doc """
  Returns the chat_attachments storage_key unchanged.

  Stage 6 backfill points platform_files at the existing chat_attachments
  bytes rather than copying them. This helper exists so the call site
  reads as a deliberate decision instead of an unwrapped variable.
  """
  @spec passthrough_key(String.t()) :: String.t()
  def passthrough_key(chat_attachment_storage_key) when is_binary(chat_attachment_storage_key),
    do: chat_attachment_storage_key

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

  # We dispatch through the chat-attachment adapter so dev/prod parity is
  # automatic. If we ever need a files-specific adapter we can swap this
  # to a `:platform, :files_storage_adapter` config knob.
  defp adapter do
    Application.get_env(
      :platform,
      :attachment_storage_adapter,
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk
    )
  end
end
