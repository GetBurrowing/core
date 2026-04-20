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
    filename = sanitize_filename(client_name || "attachment")
    bucket = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    stored_name = "#{Ecto.UUID.generate()}-#{filename}"
    storage_key = Path.join([@storage_prefix, bucket, stored_name])

    case adapter().persist(storage_key, {:path, temp_path}) do
      {:ok, %{byte_size: size, content_hash: hash}} ->
        {:ok,
         %{
           filename: client_name || filename,
           content_type: normalize_content_type(client_type, filename),
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
