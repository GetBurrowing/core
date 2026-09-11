defmodule PlatformWeb.ChatAttachmentUploadController do
  @moduledoc """
  Accepts raw bytes for a presigned upload (ADR 0039 phase 4+5).

  The HMAC-signed `<token>` in the URL is the only auth — the agent's
  bearer does not need to ride this request. The token carries
  `{key, max_bytes, expires_at}`; we verify signature + expiry, enforce
  size, stream bytes to the storage adapter, and then finalize the
  reservation that owns `key`.

  ## Two reservation tables

  A key is reserved in one of two places (task 01a091b7):

    * `chat_attachments` — `attachment.upload_start`; finalized through
      `Platform.Chat.Attachments.ToolHandlers.finalize_pending/2` (dedup
      included), response `%{id, url, byte_size, content_hash, deduplicated}`.
    * `platform_files` — `file_add`'s presigned branch; finalized through
      `Platform.Files.finalize_presigned_upload/2` (async ingest — the
      response goes out before extraction, matching the inline branch's
      `state: "ready"` contract), response `%{id, project_id, state,
      deduplicated, byte_size, content_hash, content_type}`.

  Lookup order: the chat row wins whenever one exists for the key, in
  ANY state — Stage 6 backfill (`Files.Storage.passthrough_key/1`) can
  alias a chat key onto a platform_files row, and a `ready` chat row must
  keep its 409. Only a `nil` chat lookup falls through to `platform_files`
  (live rows only; soft-deleted reservations read as absent -> 404). A
  platform_files row that already carries a content_hash (finalized,
  ingested or not — ingest is async, so `ingest_status` alone cannot
  tell), or a finalize race between two POSTs on one token, is 409 `attachment already finalized` — the message is shared
  with the chat branch on purpose so clients need one 409 handler.

  ## Adapter scope

  Only `LocalDisk` exists on main
  (`apps/platform/lib/platform/chat/attachment_storage/adapter/`); the
  token format is adapter-owned. A future S3/R2 adapter with a native
  presigned POST would bypass this controller entirely and needs its own
  finalize hook for both tables.
  """

  use PlatformWeb, :controller

  require Logger

  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Files
  alias Platform.Files.File, as: PFile
  alias Platform.Repo

  @read_chunk_bytes 64 * 1024

  def create(conn, %{"token" => token}) do
    with {:ok, %{key: key, max_bytes: max_bytes}} <- AttachmentPresigner.verify(token),
         {:ok, %{storage_key: ^key} = reservation} <- pending_reservation(key),
         :ok <- validate_content_type(conn, reservation),
         {:ok, tmp_path, byte_size} <- stream_body_to_tmp(conn, max_bytes),
         {:ok, %{byte_size: ^byte_size, content_hash: _} = stat} <-
           persist_bytes(reservation, tmp_path) do
      File.rm(tmp_path)

      case finalize(reservation, stat) do
        {:ok, payload} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(payload))

        {:error, :not_pending} ->
          send_error(conn, 409, "attachment already finalized")

        {:error, reason} ->
          send_error(conn, 500, "finalize failed: #{inspect(reason)}")
      end
    else
      {:error, :invalid} ->
        send_error(conn, 401, "invalid upload token")

      {:error, :expired} ->
        send_error(conn, 410, "upload token expired")

      {:error, :too_large} ->
        send_error(conn, 413, "body exceeds max_bytes")

      {:error, :content_type_mismatch} ->
        send_error(conn, 400, "content-type does not match reserved row")

      {:error, :not_found} ->
        send_error(conn, 404, "no pending reservation for key")

      {:error, :not_pending} ->
        send_error(conn, 409, "attachment already finalized")

      {:error, reason} ->
        send_error(conn, 500, "upload failed: #{inspect(reason)}")
    end
  end

  # The chat row is authoritative for its key in every state; only a nil
  # chat lookup consults platform_files (see moduledoc, "Two reservation
  # tables").
  defp lookup_pending(key) do
    case Repo.get_by(Attachment, storage_key: key) do
      nil -> Files.get_by_storage_key(key)
      attachment -> attachment
    end
  end

  defp pending_reservation(key) do
    case lookup_pending(key) do
      nil -> {:error, :not_found}
      %Attachment{state: "pending"} = attachment -> {:ok, attachment}
      %Attachment{} -> {:error, :not_pending}
      # `ingest_status: "pending"` alone is NOT "awaiting bytes": ingest
      # is async, so a just-finalized row is still "pending" until the
      # Ingester runs. The reservation marker is a nil content_hash.
      %PFile{ingest_status: "pending", content_hash: nil} = file -> {:ok, file}
      %PFile{} -> {:error, :not_pending}
    end
  end

  defp finalize(%Attachment{id: id}, stat), do: ToolHandlers.finalize_pending(id, stat)

  defp finalize(%PFile{} = file, stat) do
    with {:ok, %{file: done, deduplicated: dedup?}} <- Files.finalize_presigned_upload(file, stat) do
      # Same shape as `file_add_result_ready/2` in Platform.Federation.ToolSurface.
      {:ok,
       %{
         id: done.id,
         project_id: done.project_id,
         state: "ready",
         deduplicated: dedup?,
         byte_size: done.byte_size,
         content_hash: done.content_hash,
         content_type: done.content_type
       }}
    end
  end

  defp validate_content_type(conn, %{content_type: declared}) do
    case get_req_header(conn, "content-type") do
      [] ->
        :ok

      [^declared | _] ->
        :ok

      [sent | _] ->
        if strip_params(sent) == strip_params(declared) do
          :ok
        else
          {:error, :content_type_mismatch}
        end
    end
  end

  defp strip_params(ct) when is_binary(ct) do
    ct |> String.split(";", parts: 2) |> List.first() |> String.trim() |> String.downcase()
  end

  defp stream_body_to_tmp(conn, max_bytes) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "att-upload-#{System.unique_integer([:positive])}-#{Ecto.UUID.generate()}"
      )

    case File.open(tmp_path, [:write, :binary, :raw]) do
      {:ok, io} ->
        try do
          do_stream(conn, io, max_bytes, 0, tmp_path)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:open_failed, reason}}
    end
  end

  defp do_stream(conn, io, max_bytes, acc, tmp_path) do
    case Plug.Conn.read_body(conn, length: @read_chunk_bytes, read_length: @read_chunk_bytes) do
      {:ok, chunk, _conn} ->
        new_size = acc + byte_size(chunk)

        if new_size > max_bytes do
          File.rm(tmp_path)
          {:error, :too_large}
        else
          :ok = IO.binwrite(io, chunk)
          {:ok, tmp_path, new_size}
        end

      {:more, chunk, conn} ->
        new_size = acc + byte_size(chunk)

        if new_size > max_bytes do
          File.rm(tmp_path)
          {:error, :too_large}
        else
          :ok = IO.binwrite(io, chunk)
          do_stream(conn, io, max_bytes, new_size, tmp_path)
        end

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:read_body_failed, reason}}
    end
  end

  defp persist_bytes(%{storage_key: key}, tmp_path) do
    adapter().persist(key, {:path, tmp_path})
  end

  defp send_error(conn, status, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp adapter,
    do:
      Application.get_env(
        :platform,
        :attachment_storage_adapter,
        AttachmentStorage.Adapter.LocalDisk
      )
end
