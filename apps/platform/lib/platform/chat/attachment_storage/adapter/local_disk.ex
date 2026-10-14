defmodule Platform.Chat.AttachmentStorage.Adapter.LocalDisk do
  @moduledoc "Local-disk implementation of the attachment storage adapter."

  @behaviour Platform.Chat.AttachmentStorage.Adapter

  alias Platform.Chat.AttachmentStorage.Root

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
      {:ok, File.stream!(path, @read_chunk_bytes)}
    else
      {:error, :enoent}
    end
  end

  # ── Resumable chunked uploads (task 01a120be) ─────────────────────────
  #
  # Bytes land in `<dest>.part` by POSITIONED write (`write_at/3`), so a chunk
  # may arrive before the ones in front of it. Which byte ranges are really
  # on disk is recorded separately, in `<dest>.part.ranges` (`record_range/3`):
  # merged `start-end` lines, rewritten atomically (tmp + fsync + rename) so
  # the received set survives a restart and a torn write never shows. The
  # `.part`'s SIZE is not the offset: an out-of-order last chunk extends it
  # past a hole. Bytes written but never recorded (a crash between the two)
  # are simply re-sent; they are never counted.
  #
  # `upload_offset/1` is the CONTIGUOUS prefix from 0 that has been recorded.
  # The caller serializes `record_range/3` and `complete_upload/1` per key
  # (`PlatformWeb.ChatAttachmentUploadController` does it under a row lock);
  # `write_at/3` needs no lock.
  #
  # On completion the .part is hashed by streaming and RENAMED to dest: one
  # write of the bytes, not the tmp + `File.cp` double write that `persist/2`
  # does.

  @doc "Path of the in-progress `.part` file for `storage_key`."
  @spec part_path_for(binary()) :: binary()
  def part_path_for(storage_key), do: path_for(storage_key) <> ".part"

  @doc "Path of the received-ranges sidecar beside the `.part`."
  @spec ranges_path_for(binary()) :: binary()
  def ranges_path_for(storage_key), do: part_path_for(storage_key) <> ".ranges"

  @doc """
  Sequential append: writes `bytes` at `offset` only when `offset` is the
  contiguous offset, and records the range. Not serialized; the controller
  uses `write_at/3` + `record_range/3` instead.
  """
  @impl true
  def append_chunk(storage_key, offset, {:binary, bytes})
      when is_integer(offset) and offset >= 0 and is_binary(bytes) do
    with {:ok, actual} <- upload_offset(storage_key),
         :ok <- same_offset(offset, actual),
         :ok <- write_at(storage_key, offset, {:binary, bytes}) do
      record_range(storage_key, offset, offset + byte_size(bytes))
    end
  end

  @impl true
  def write_at(_storage_key, offset, {:binary, <<>>}) when is_integer(offset), do: :ok

  def write_at(storage_key, offset, {:binary, bytes})
      when is_integer(offset) and offset >= 0 and is_binary(bytes) do
    part = part_path_for(storage_key)

    with :ok <- mkdir_p(Path.dirname(part)) do
      # [:read, :write] opens without truncating (plain :write truncates).
      case File.open(part, [:read, :write, :binary, :raw]) do
        {:ok, io} ->
          try do
            :file.pwrite(io, offset, bytes)
          after
            File.close(io)
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def upload_ranges(storage_key) do
    case File.read(ranges_path_for(storage_key)) do
      {:ok, text} -> {:ok, parse_ranges(text)}
      {:error, :enoent} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @impl true
  def record_range(storage_key, from, to)
      when is_integer(from) and is_integer(to) and 0 <= from and from <= to do
    with {:ok, ranges} <- upload_ranges(storage_key),
         merged = merge_range(ranges, {from, to}),
         :ok <- write_ranges(storage_key, merged) do
      {:ok, contiguous(merged)}
    end
  end

  @impl true
  def upload_offset(storage_key) do
    # A missing .part with dest present means a previous completion renamed
    # it and the finalize step did not run; report dest's size so the client
    # sends a zero-length final PATCH that completes again.
    if File.exists?(part_path_for(storage_key)) do
      with {:ok, ranges} <- upload_ranges(storage_key), do: {:ok, contiguous(ranges)}
    else
      case File.stat(path_for(storage_key)) do
        {:ok, %{size: size}} -> {:ok, size}
        {:error, :enoent} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def complete_upload(storage_key) do
    part = part_path_for(storage_key)
    dest = path_for(storage_key)

    cond do
      File.exists?(part) ->
        with {:ok, stat} <- hash_and_size(part),
             :ok <- rename(part, dest) do
          _ = File.rm(ranges_path_for(storage_key))
          {:ok, stat}
        end

      File.exists?(dest) ->
        hash_and_size(dest)

      true ->
        # Zero bytes ever appended: an empty file is a legal upload.
        with :ok <- mkdir_p(Path.dirname(dest)),
             :ok <- File.write(dest, <<>>) do
          hash_and_size(dest)
        end
    end
  end

  @doc "Removes any `.part` and ranges sidecar for `storage_key`; never the object."
  @impl true
  def discard_part(storage_key) do
    _ = File.rm(part_path_for(storage_key))
    _ = File.rm(ranges_path_for(storage_key))
    :ok
  end

  defp same_offset(offset, offset), do: :ok
  defp same_offset(_offset, actual), do: {:error, {:offset_mismatch, actual}}

  # The end of the range that starts at 0, else 0.
  defp contiguous([{0, to} | _]), do: to
  defp contiguous(_), do: 0

  # `ranges` is sorted and disjoint; adjacent ranges merge.
  defp merge_range(ranges, {from, to}) when from == to, do: ranges

  defp merge_range(ranges, new) do
    [new | ranges]
    |> Enum.sort()
    |> Enum.reduce([], fn
      {s, e}, [{ps, pe} | rest] when s <= pe -> [{ps, max(pe, e)} | rest]
      r, acc -> [r | acc]
    end)
    |> Enum.reverse()
  end

  defp parse_ranges(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [a, b] <- String.split(line, "-", parts: 2),
           {from, ""} <- Integer.parse(a),
           {to, ""} <- Integer.parse(b),
           true <- 0 <= from and from <= to do
        [{from, to}]
      else
        _ -> []
      end
    end)
    |> Enum.reduce([], &merge_range(&2, &1))
  end

  defp write_ranges(storage_key, ranges) do
    path = ranges_path_for(storage_key)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    body = Enum.map_join(ranges, "", fn {from, to} -> "#{from}-#{to}\n" end)

    with :ok <- mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body, [:sync]),
         :ok <- rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp rename(src, dest) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "[chat.attachment_storage.local_disk] File.rename failed: src=#{inspect(src)} dest=#{inspect(dest)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  @impl true
  def delete(storage_key) do
    # A stray .part (and its ranges sidecar) from an abandoned chunked upload
    # goes with its key (AttachmentReaper deletes through here).
    _ = discard_part(storage_key)
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
    # The app-env resolution below is unchanged; `Root.get/1` returns it
    # verbatim unless the calling process (or an ancestor of it) claimed a
    # root for itself, which only tests do. See
    # `Platform.Chat.AttachmentStorage.Root` for why that indirection exists.
    Root.get(
      Application.get_env(
        :platform,
        :chat_attachments_root,
        Path.join(System.tmp_dir!(), "platform-chat-uploads")
      )
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
      |> File.stream!(@read_chunk_bytes)
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
