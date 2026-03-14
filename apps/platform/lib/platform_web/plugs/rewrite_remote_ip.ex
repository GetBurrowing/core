defmodule PlatformWeb.Plugs.RewriteRemoteIp do
  @moduledoc """
  Rewrites `conn.remote_ip` from the `X-Forwarded-For` header so that audit
  events and logs record the real client IP instead of the reverse-proxy IP.

  **Only enable this when the app is behind a trusted reverse proxy** (Traefik,
  nginx, Caddy, etc.) that sets `X-Forwarded-For`. Set `TRUST_PROXY_HEADERS=true`
  in the environment to activate it.

  Do NOT enable this if the app is exposed directly to the internet — it would
  allow clients to spoof their IP address by forging the header.

  Uses the *first* (leftmost) value in `X-Forwarded-For`, which is the
  original client IP as appended by the outermost proxy.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Application.get_env(:platform, :trust_proxy_headers, false) do
      rewrite_ip(conn)
    else
      conn
    end
  end

  defp rewrite_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        ip_string =
          forwarded
          |> String.split(",")
          |> List.first()
          |> String.trim()

        case :inet.parse_address(String.to_charlist(ip_string)) do
          {:ok, ip_tuple} -> %{conn | remote_ip: ip_tuple}
          _ -> conn
        end

      [] ->
        conn
    end
  end
end
