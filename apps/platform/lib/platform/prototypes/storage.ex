defmodule Platform.Prototypes.Storage do
  @moduledoc """
  Bytes for prototype versions, through the same storage adapter as
  `Platform.Files.Storage` and chat attachments (local disk in dev/test,
  R2/S3 in prod), under its own namespace:

      prototypes/<prototype_id>/<version>/<path>

  `<path>` has already passed `Platform.Prototypes.Bundle.validate_path/1`,
  so it carries no `..`, absolute or backslash segment.
  """

  @namespace "prototypes"

  @doc "The storage key for one file of one version."
  @spec key(binary(), pos_integer(), String.t()) :: String.t()
  def key(prototype_id, version, path)
      when is_binary(prototype_id) and is_integer(version) and is_binary(path),
      do: Enum.join([@namespace, prototype_id, Integer.to_string(version), path], "/")

  @spec put(String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def put(key, bytes) when is_binary(key) and is_binary(bytes),
    do: adapter().persist(key, {:binary, bytes})

  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(key) when is_binary(key) do
    case adapter().read_stream(key) do
      {:ok, stream} -> {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
      {:error, _} = err -> err
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key), do: adapter().delete(key)

  defp adapter do
    Application.get_env(
      :platform,
      :attachment_storage_adapter,
      Platform.Chat.AttachmentStorage.Adapter.LocalDisk
    )
  end
end
