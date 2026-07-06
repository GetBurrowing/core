defmodule PlatformWeb.Plugs.VerifyLivekitSignature do
  @moduledoc """
  Verify the HMAC-JWT signature LiveKit attaches to webhook requests.

  LiveKit sends the JWT in the `Authorization` header (LiveKit convention
  omits the `Bearer ` prefix; we tolerate both). The token is HS256-signed
  under `LIVEKIT_API_SECRET` and carries a `sha256` claim that must equal
  the base64-standard-encoded SHA256 hash of the raw request body.

  The raw body must already be cached on `conn.assigns[:raw_body]` — this
  is done by `PlatformWeb.Plugs.CacheBodyReader` at the endpoint's
  `Plug.Parsers` layer, which runs before router pipelines.

  ## Feature flag

  When `Application.get_env(:platform, :livekit_webhook_signature_required, true)`
  is `false`, verification failures are logged as warnings but the
  request passes through. This is a rollback safety valve — flip in
  prod runtime config to disable enforcement without a redeploy. The
  test suite pins the flag to `false` so the existing controller tests
  keep exercising handler behaviour without minting a JWT per payload.

  Task 019f3312 stage 2 — phantom-fix v4 hardening.
  """

  import Plug.Conn

  alias Platform.Meetings

  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    raw_body = conn.assigns[:raw_body] || ""
    token = extract_token(conn)

    case Meetings.verify_livekit_jwt(token, raw_body) do
      :ok ->
        conn

      {:error, reason} ->
        if signature_required?() do
          Logger.warning(
            "[LiveKit] Rejecting webhook: signature verification failed (reason=#{reason})"
          )

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{status: "error", reason: to_string(reason)}))
          |> halt()
        else
          Logger.warning(
            "[LiveKit] Signature verification failed (reason=#{reason}) — passing through " <>
              "because :livekit_webhook_signature_required is false"
          )

          conn
        end
    end
  end

  defp signature_required? do
    Application.get_env(:platform, :livekit_webhook_signature_required, true)
  end

  # LiveKit's SDK omits the `Bearer ` scheme; some proxies (or manual
  # curl-based test payloads) add it. Accept both.
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] ->
        value
        |> String.trim()
        |> strip_bearer_prefix()

      _ ->
        nil
    end
  end

  defp strip_bearer_prefix("Bearer " <> rest), do: String.trim(rest)
  defp strip_bearer_prefix("bearer " <> rest), do: String.trim(rest)
  defp strip_bearer_prefix(token), do: token
end
