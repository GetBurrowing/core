defmodule Platform.Chat.AttachmentPresigner do
  @moduledoc """
  HMAC sign / verify for attachment upload tokens (ADR 0039 phase 4+5).

  A presigned upload URL is just `/chat/attachments/upload/<token>` where
  `<token>` carries the signed payload `{key, max_bytes, expires_at}`. The
  upload controller verifies the token against the configured signing key
  and enforces the payload constraints (size, expiry) before writing bytes.
  """

  @salt "attachment_upload"

  @type payload :: %{
          required(:key) => String.t(),
          required(:max_bytes) => pos_integer(),
          required(:expires_at) => integer()
        }

  @spec sign(payload) :: String.t()
  def sign(%{key: key, max_bytes: max_bytes, expires_at: expires_at} = payload)
      when is_binary(key) and is_integer(max_bytes) and is_integer(expires_at) do
    Plug.Crypto.sign(signing_key(), @salt, payload)
  end

  @doc """
  Verify a token. Returns the payload on success.

  `max_age_seconds` is an upper bound from issue time; the `expires_at`
  field in the payload is checked independently so callers can reject
  even earlier when desired.
  """
  @spec verify(String.t(), keyword()) :: {:ok, payload} | {:error, :invalid | :expired}
  def verify(token, opts \\ []) when is_binary(token) do
    max_age = Keyword.get(opts, :max_age_seconds, 7 * 24 * 60 * 60)

    case Plug.Crypto.verify(signing_key(), @salt, token, max_age: max_age) do
      {:ok, %{key: _, max_bytes: _, expires_at: expires_at} = payload} ->
        if DateTime.utc_now() |> DateTime.to_unix() > expires_at do
          {:error, :expired}
        else
          {:ok, payload}
        end

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  defp signing_key do
    Application.get_env(:platform, :attachment_signing_key) ||
      raise """
      :attachment_signing_key not configured.

      Set `config :platform, :attachment_signing_key, "..."` (32+ bytes) in
      config/runtime.exs. Dev and test configs already set a stable value
      (phase 2). Prod must read from an env var.
      """
  end
end
