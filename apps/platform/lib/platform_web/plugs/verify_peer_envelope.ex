defmodule PlatformWeb.Plugs.VerifyPeerEnvelope do
  @moduledoc """
  Transport half of the peer inbox (task 01a0d90f stage 3, ADR 0054 section
  2). The verdict lives in `Platform.Federation.Peers.Envelope.verify/3`, the
  same split as `PlatformWeb.Plugs.VerifyGithubSignature` and
  `Platform.Webhooks.GithubSignature`.

  ## This plug reads the body itself, with the cap applied while reading

  The GitHub and LiveKit pipelines verify `conn.assigns[:raw_body]`, which
  `PlatformWeb.Plugs.CacheBodyReader` fills at the endpoint's `Plug.Parsers`.
  That is the wrong shape for a 256 KB cap: `Plug.Parsers` reads the WHOLE
  body (up to its 8 MB default) before any router plug runs, and
  `CacheBodyReader` appends every chunk to `:raw_body`, so a cap checked here
  afterwards would only decide whether to use bytes already buffered.

  So the inbox path is on `PlatformWeb.Plugs.RawBodyPaths`' skip-list, the
  parsers never touch it, and this plug reads the body with
  `Plug.Conn.read_body/2` limited to `max_bytes + 1`:

    * a `content-length` above the cap is refused before any byte is read;
    * otherwise at most `max_bytes + 1` bytes are read, in chunks of
      `@read_length`, and if the body is longer the rest is never read.

  The raw bytes are then cached on `conn.assigns[:raw_body]` like the other
  signed routes.

  ## Refusals

  A refusal answers `{"error": "<reason atom>"}` with a status from
  `status_for/1` and halts. It NEVER echoes the request: no body bytes,
  header values or field values reach the response or the log line, which
  carries only the reason.

  While `PEER_FEDERATION_ENABLED` is off the plug answers the same 404 as a
  route that does not exist and reads nothing.
  """

  import Plug.Conn

  require Logger

  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.Envelope

  @behaviour Plug

  @read_length 64 * 1024

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Config.enabled?() do
      verify(conn)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{errors: %{detail: "Not Found"}}))
      |> halt()
    end
  end

  @doc "HTTP status for a refusal reason."
  @spec status_for(atom()) :: pos_integer()
  def status_for(:too_large), do: 413
  def status_for(reason) when reason in [:invalid_json, :malformed_envelope, :read_error], do: 400
  def status_for(:unsupported_version), do: 400
  def status_for(:wrong_recipient), do: 421
  def status_for(reason) when reason in [:unknown_peer, :peer_revoked, :peer_not_active], do: 403
  def status_for(:replayed_nonce), do: 409
  def status_for(_signature_or_time), do: 401

  # Every refusal after the read is sent on the conn RETURNED by the read, so
  # the adapter's state (how much body was consumed) matches the response.
  defp verify(conn) do
    case read_capped(conn) do
      {:ok, raw, conn} ->
        conn = assign(conn, :raw_body, raw)

        case Envelope.verify(raw, conn.req_headers, System.system_time(:millisecond)) do
          {:ok, verified} -> assign(conn, :peer_envelope, verified)
          {:error, reason} -> refuse(conn, reason)
        end

      {:error, reason, conn} ->
        refuse(conn, reason)
    end
  end

  defp read_capped(conn) do
    max = Envelope.max_bytes()

    if declared_length(conn) > max do
      {:error, :too_large, conn}
    else
      case read_body(conn, length: max + 1, read_length: @read_length) do
        {:ok, body, conn} when byte_size(body) <= max -> {:ok, body, conn}
        {:ok, _body, conn} -> {:error, :too_large, conn}
        {:more, _partial, conn} -> {:error, :too_large, conn}
        {:error, _} -> {:error, :read_error, conn}
      end
    end
  end

  defp declared_length(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> 0
    end
  end

  defp refuse(conn, reason) do
    Logger.info("[federation] inbox refused reason=#{reason}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_for(reason), Jason.encode!(%{error: to_string(reason)}))
    |> halt()
  end
end
