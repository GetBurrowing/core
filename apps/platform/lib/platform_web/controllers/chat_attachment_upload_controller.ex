defmodule PlatformWeb.ChatAttachmentUploadController do
  @moduledoc """
  Accepts raw bytes for a presigned attachment upload (ADR 0039 phase 4+5).

  The HMAC-signed `<token>` in the URL is the only auth — the agent's
  bearer does not need to ride this request. The token carries
  `{key, max_bytes, expires_at}`; we verify signature + expiry, enforce
  size, stream bytes to the storage adapter, and then finalize the
  pending `chat_attachments` row (dedup included).
  """

  use PlatformWeb, :controller

  require Logger

  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Repo

  @read_chunk_bytes 64 * 1024

  def create(conn, %{"token" => token}) do
    with {:ok, %{key: key, max_bytes: max_bytes}} <- AttachmentPresigner.verify(token),
         %Attachment{state: "pending", storage_key: ^key} = attachment <- lookup_pending(key),
         :ok <- validate_content_type(conn, attachment),
         {:ok, tmp_path, byte_size} <- stream_body_to_tmp(conn, max_bytes),
         {:ok, %{byte_size: ^byte_size, content_hash: _} = stat} <-
           persist_bytes(attachment, tmp_path) do
      File.rm(tmp_path)

      case ToolHandlers.finalize_pending(attachment.id, stat) do
        {:ok, payload} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(payload))

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

      {:error, reason} ->
        send_error(conn, 500, "upload failed: #{inspect(reason)}")

      nil ->
        send_error(conn, 404, "no pending reservation for key")

      %Attachment{} ->
        send_error(conn, 409, "attachment already finalized")
    end
  end

  defp lookup_pending(key) do
    Repo.get_by(Attachment, storage_key: key)
  end

  defp validate_content_type(conn, %Attachment{content_type: declared}) do
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

  defp persist_bytes(%Attachment{storage_key: key}, tmp_path) do
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
