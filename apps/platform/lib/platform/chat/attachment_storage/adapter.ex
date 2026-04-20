defmodule Platform.Chat.AttachmentStorage.Adapter do
  @moduledoc "Behaviour implemented by attachment storage backends (ADR 0039)."

  @type key :: String.t()
  @type source :: {:path, Path.t()} | {:binary, binary()}
  @type persist_ok :: %{byte_size: non_neg_integer(), content_hash: String.t()}
  @type presign_ok :: %{url: String.t(), expires_at: DateTime.t()}

  @callback persist(key, source) :: {:ok, persist_ok} | {:error, term()}
  @callback read_stream(key) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback delete(key) :: :ok
  @callback presign_upload(key, pos_integer(), pos_integer()) ::
              {:ok, presign_ok} | {:error, term()}
end
