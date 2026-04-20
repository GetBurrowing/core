defmodule Platform.Chat.AttachmentStorage.Adapter.LocalDisk do
  @moduledoc "Local-disk implementation of the attachment storage adapter."

  @behaviour Platform.Chat.AttachmentStorage.Adapter

  require Logger

  @read_chunk_bytes 64 * 1024

  @impl true
  def persist(storage_key, {:path, temp_path}) do
    dest = path_for(storage_key)

    with :ok <- mkdir_p(Path.dirname(dest)),
         :ok <- copy(temp_path, dest) do
      hash_and_size(dest)
    end
  end

  def persist(storage_key, {:binary, bytes}) when is_binary(bytes) do
    dest = path_for(storage_key)

    with :ok <- mkdir_p(Path.dirname(dest)),
         :ok <- File.write(dest, bytes) do
      {:ok,
       %{
         byte_size: byte_size(bytes),
         content_hash: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
       }}
    end
  end

  @impl true
  def read_stream(storage_key) do
    path = path_for(storage_key)

    if File.exists?(path) do
      {:ok, File.stream!(path, [], @read_chunk_bytes)}
    else
      {:error, :enoent}
    end
  end

  @impl true
  def delete(storage_key) do
    path = path_for(storage_key)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[chat.attachment_storage.local_disk] File.rm failed (continuing): path=#{inspect(path)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @impl true
  def presign_upload(storage_key, max_bytes, ttl_s)
      when is_binary(storage_key) and is_integer(max_bytes) and max_bytes > 0 and
             is_integer(ttl_s) and ttl_s > 0 do
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_s, :second)

    token =
      Plug.Crypto.sign(signing_key(), "attachment_upload", %{
        key: storage_key,
        max_bytes: max_bytes,
        expires_at: DateTime.to_unix(expires_at)
      })

    {:ok,
     %{
       url: "/chat/attachments/upload/#{token}",
       expires_at: expires_at
     }}
  end

  @spec path_for(binary()) :: binary()
  def path_for(storage_key), do: Path.join(storage_root(), storage_key)

  @spec storage_root() :: binary()
  def storage_root do
    Application.get_env(
      :platform,
      :chat_attachments_root,
      Path.join(System.tmp_dir!(), "platform-chat-uploads")
    )
  end

  @doc """
  Verifies the configured storage root exists and is writable by the running
  process. Writes+deletes a zero-byte sentinel file. Raises on failure with
  a message pointing at the most common cause (missing persistent volume
  mount in the deployment manifest).
  """
  @spec ensure_writable!() :: :ok
  def ensure_writable! do
    root = storage_root()
    sentinel = Path.join(root, ".write-check-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(sentinel, <<>>) do
      case File.rm(sentinel) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[chat.attachment_storage.local_disk] sentinel delete failed (accumulating noise, not a block): sentinel=#{inspect(sentinel)} reason=#{inspect(reason)}"
          )

          :ok
      end
    else
      {:error, reason} ->
        raise """
        Chat attachment storage is not writable.

          storage_root: #{inspect(root)}
          reason: #{inspect(reason)}

        This usually means the deployment manifest is missing a persistent
        volume mount at this path, or the app user (UID 1000) cannot write
        to it. Files written here must survive container restarts —
        otherwise attachments go 404 on the next redeploy.

        Fix: mount a persistent volume at #{root} and ensure it is owned
        by UID 1000 (the `app` user).
        """
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "[chat.attachment_storage.local_disk] mkdir_p failed: dir=#{inspect(dir)} reason=#{inspect(reason)} storage_root=#{inspect(storage_root())}"
        )

        err
    end
  end

  defp copy(src, dest) do
    case File.cp(src, dest) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "[chat.attachment_storage.local_disk] File.cp failed: src_basename=#{inspect(Path.basename(src))} dest=#{inspect(dest)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp hash_and_size(path) do
    {ctx, size} =
      path
      |> File.stream!([], @read_chunk_bytes)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {ctx, size} ->
        {:crypto.hash_update(ctx, chunk), size + byte_size(chunk)}
      end)

    {:ok,
     %{
       byte_size: size,
       content_hash: ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
     }}
  rescue
    e in File.Error ->
      Logger.error(
        "[chat.attachment_storage.local_disk] hash_and_size failed: path=#{inspect(path)} reason=#{inspect(e.reason)}"
      )

      {:error, e.reason}
  end

  defp signing_key do
    Application.get_env(:platform, :attachment_signing_key) ||
      raise """
      :attachment_signing_key not configured for Platform.Chat.AttachmentStorage.

      Set config :platform, :attachment_signing_key, "..." (32+ bytes) in
      config/runtime.exs. Phase 4+5 of ADR 0039 enforces this at boot; until
      then, dev/test configs should set a stable value.
      """
  end
end
