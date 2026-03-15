defmodule Platform.Chat.AttachmentStorage do
  @moduledoc """
  Persists chat attachments on local disk under the configured chat uploads root.

  The database stores only metadata and the relative `storage_key`; the file
  contents live on disk and are served through an authenticated controller.
  """

  @storage_prefix "chat"

  @spec persist_upload(binary(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_upload(temp_path, client_name, client_type \\ nil) do
    filename = sanitize_filename(client_name || "attachment")
    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    stored_name = "#{Ecto.UUID.generate()}-#{filename}"
    storage_key = Path.join([@storage_prefix, bucket, stored_name])
    destination = path_for(storage_key)

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(temp_path, destination),
         {:ok, stat} <- File.stat(destination) do
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

  @spec delete(binary()) :: :ok
  def delete(storage_key) do
    case File.rm(path_for(storage_key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
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
