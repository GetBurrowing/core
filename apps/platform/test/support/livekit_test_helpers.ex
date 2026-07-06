defmodule Platform.LivekitTestHelpers do
  @moduledoc """
  Test helpers for building signed LiveKit webhook payloads.

  Mints a JWT that satisfies `Platform.Meetings.verify_livekit_jwt/2`:

    * HS256-signed under a supplied (or default fixture) secret
    * `sha256` claim = base64-standard-encoded SHA256 of the raw body
    * `exp` in the near future

  Used by `PlatformWeb.Plugs.VerifyLivekitSignatureTest` and by any
  future test that wants to hit `/api/webhooks/livekit` with signature
  enforcement toggled on.

  Task 019f3312 stage 2 — phantom-fix v4.
  """

  alias Platform.Meetings

  @default_secret "test-livekit-secret-0123456789abcdef"

  @doc """
  Return `{signed_body, auth_header}` for the given payload.

  `payload` may be a map (JSON-encoded here) or an already-encoded
  binary. The returned `signed_body` is the exact byte sequence the
  request must transmit — mint the header FROM this body so the
  `sha256` claim matches.
  """
  @spec sign_livekit_payload(map() | binary()) :: {binary(), String.t()}
  def sign_livekit_payload(payload), do: sign_livekit_payload(payload, @default_secret)

  @spec sign_livekit_payload(map() | binary(), String.t()) :: {binary(), String.t()}
  def sign_livekit_payload(payload, secret) when is_map(payload) do
    sign_livekit_payload(Jason.encode!(payload), secret)
  end

  def sign_livekit_payload(body, secret) when is_binary(body) and is_binary(secret) do
    body_hash = :crypto.hash(:sha256, body) |> Base.encode64()
    now = System.system_time(:second)

    claims = %{
      "iss" => "test-livekit-key",
      "nbf" => now,
      "exp" => now + 300,
      "sha256" => body_hash
    }

    {body, Meetings.encode_jwt(claims, secret)}
  end

  @doc """
  The default fixture secret. Callers that want to poke the LiveKit
  config to match this secret should push it in via
  `Application.put_env(:platform, :livekit, api_secret: default_secret())`
  in their setup block.
  """
  @spec default_secret() :: String.t()
  def default_secret, do: @default_secret
end
