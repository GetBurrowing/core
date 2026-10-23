defmodule Platform.Files.SignedUrl do
  @moduledoc """
  Short-lived, signed GET URLs for one `Platform.Files.File` (task 01a165ec
  stage 1, absorbing 01a142c4).

  An outside service (a publishing vendor fetching a video, say) carries no
  Burrow session, so `/files/blob/:id` is unreachable to it. `url/2` mints
  `<endpoint>/files/signed/<token>`, where `<token>` is a `Plug.Crypto`
  signature over `%{file_id: id, expires_at: unix_seconds}`. The token is the
  whole authorization: `PlatformWeb.FileSignedController` serves exactly the
  one file it names and nothing else.

  The salt (`"file_get"`) is this module's own. A token minted for a different
  purpose under the same key (an attachment upload token, salt
  `"attachment_upload"`) does not verify here, and vice versa.

  Possession of the URL is possession of the bytes until it expires, so mint
  one only at the moment it is handed to the party that needs it, with the
  shortest expiry that works.
  """

  alias Platform.Files

  @salt "file_get"
  @path "/files/signed/"
  @default_ttl_seconds 3600

  @doc """
  Mints an absolute signed GET URL for `file_or_id`.

  Options:

    * `:expires_at` — a `DateTime` or unix seconds. Defaults to now + 3600s.
      Must be in the future.

  Returns `{:error, :not_found}` for an unknown or deleted file id and
  `{:error, :invalid_expiry}` for an expiry that is not in the future.
  """
  @spec url(Files.File.t() | Ecto.UUID.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def url(file_or_id, opts \\ [])

  def url(%Files.File{id: id}, opts) when is_binary(id), do: mint(id, opts)

  def url(id, opts) when is_binary(id) do
    case Files.get_file(id) do
      %Files.File{id: id} -> mint(id, opts)
      nil -> {:error, :not_found}
    end
  end

  def url(_other, _opts), do: {:error, :not_found}

  @doc """
  Verifies a token minted by `url/2`. Returns the file id it names.

  `{:error, :expired}` past its `expires_at`; `{:error, :invalid}` for any
  token that does not carry this module's signature (tampered, other salt,
  other key, garbage).
  """
  @spec verify(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :invalid | :expired}
  def verify(token) when is_binary(token) do
    case Plug.Crypto.verify(signing_key(), @salt, token) do
      {:ok, %{file_id: file_id, expires_at: expires_at}}
      when is_binary(file_id) and is_integer(expires_at) ->
        if now() > expires_at, do: {:error, :expired}, else: {:ok, file_id}

      {:error, :expired} ->
        {:error, :expired}

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  @doc false
  # Signs an arbitrary payload under this module's salt and key. Tests use it
  # to build an already-expired token without waiting.
  def sign_payload(%{file_id: _, expires_at: expires_at} = payload) do
    max_age = max(expires_at - now(), 1)
    Plug.Crypto.sign(signing_key(), @salt, payload, max_age: max_age)
  end

  defp mint(file_id, opts) do
    with {:ok, expires_at} <- expires_at(opts) do
      token = sign_payload(%{file_id: file_id, expires_at: expires_at})
      {:ok, PlatformWeb.Endpoint.url() <> @path <> token}
    end
  end

  defp expires_at(opts) do
    expires_at =
      case Keyword.get(opts, :expires_at) do
        nil -> now() + @default_ttl_seconds
        %DateTime{} = dt -> DateTime.to_unix(dt)
        unix when is_integer(unix) -> unix
        _ -> :invalid
      end

    if is_integer(expires_at) and expires_at > now(),
      do: {:ok, expires_at},
      else: {:error, :invalid_expiry}
  end

  defp now, do: System.os_time(:second)

  # Same configured key as the attachment upload tokens; the salt above is
  # what keeps the two token families apart.
  defp signing_key do
    Application.get_env(:platform, :attachment_signing_key) ||
      raise ":attachment_signing_key not configured (see Platform.Chat.AttachmentPresigner)"
  end
end
