defmodule PlatformWeb.Plugs.CacheBodyReader do
  @moduledoc """
  A custom body reader that caches the raw request body in `conn.assigns[:raw_body]`.

  This is required for HMAC webhook signature verification where we need
  the exact raw body bytes that GitHub signed.

  Used as the `:body_reader` option for `Plug.Parsers`.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        # Append to any previously read chunks
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> body)
        {:ok, body, conn}

      {:more, body, conn} ->
        existing = conn.assigns[:raw_body] || ""
        conn = Plug.Conn.assign(conn, :raw_body, existing <> body)
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
