defmodule Platform.Chat.AttachmentStorage do
  @moduledoc """
  Persists chat attachments on local disk under the configured chat uploads root.

  The database stores only metadata and the relative `storage_key`; the file
  contents live on disk and are served through an authenticated controller.
  """

  require Logger

  @storage_prefix "chat"

  @spec persist_upload(binary(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_upload(temp_path, client_name, client_type \\ nil) do
    filename = sanitize_filename(client_name || "attachment")
    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    stored_name = "#{Ecto.UUID.generate()}-#{filename}"
    storage_key = Path.join([@storage_prefix, bucket, stored_name])
    destination = path_for(storage_key)
    dir = Path.dirname(destination)

    with :ok <- mkdir_p(dir),
         :ok <- copy(temp_path, destination),
         {:ok, stat} <- stat(destination) do
      {:ok,
       %{
         filename: client_name || filename,
         content_type: normalize_content_type(client_type, filename),
         byte_size: stat.size,
         storage_key: storage_key,
         metadata: %{}
       }}
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "[chat.attachment_storage] mkdir_p failed: dir=#{inspect(dir)} reason=#{inspect(reason)} storage_root=#{inspect(storage_root())}"
        )

        err
    end
  end

  defp copy(src, dest) do
    case File.cp(src, dest) do
      :ok ->
        :ok

      {:error, reason} = err ->
        # Log the source as basename only — the full tmp path has no debug
        # value and exposes filesystem layout to log aggregators.
        Logger.error(
          "[chat.attachment_storage] File.cp failed: src_basename=#{inspect(Path.basename(src))} dest=#{inspect(dest)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        Logger.error(
          "[chat.attachment_storage] File.stat failed after write: path=#{inspect(path)} reason=#{inspect(reason)}"
        )

        err
    end
  end

  @spec delete(binary()) :: :ok
  def delete(storage_key) do
    path = path_for(storage_key)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[chat.attachment_storage] File.rm failed (continuing): path=#{inspect(path)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  @spec delete_many([map()]) :: :ok
  def delete_many(attachments) do
    Enum.each(attachments, fn
      %{storage_key: storage_key} -> delete(storage_key)
      _ -> :ok
    end)

    :ok
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

  Called from `Platform.Application.start/2` in prod so misconfigured
  deploys crash at boot rather than silently 404'ing attachment reads after
  the first container restart.
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
            "[chat.attachment_storage] sentinel delete failed (accumulating noise, not a block): sentinel=#{inspect(sentinel)} reason=#{inspect(reason)}"
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

  defp normalize_content_type(nil, filename), do: infer_content_type(filename)
  defp normalize_content_type("", filename), do: infer_content_type(filename)
  defp normalize_content_type(content_type, _filename), do: content_type

  defp infer_content_type(filename) do
    filename
    |> MIME.from_path()
    |> case do
      nil -> "application/octet-stream"
      type -> type
    end
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
