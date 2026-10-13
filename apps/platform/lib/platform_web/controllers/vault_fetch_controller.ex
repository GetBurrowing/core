defmodule PlatformWeb.VaultFetchController do
  @moduledoc """
  `GET /vault/fetch/:token` — redeem a single-use vault fetch ticket
  (`Platform.Vault.Fetch`).

  No session and no bearer: the token is the auth. `"token"` is in
  `:phoenix, :filter_parameters`, so the path param is filtered from request
  logs.

    * 200 — the raw value as `application/octet-stream`, `no-store`.
    * 410 — unknown, consumed or expired ticket.
    * 403 — the agent's grant was removed after the ticket was issued.
  """
  use PlatformWeb, :controller

  alias Platform.Vault.Fetch

  def show(conn, %{"token" => token}) do
    case Fetch.redeem(token, remote_ip(conn)) do
      {:ok, value} ->
        conn
        |> put_resp_header("content-type", "application/octet-stream")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("content-disposition", "attachment")
        |> send_resp(200, value)

      {:error, :access_denied} ->
        plain(conn, 403, "forbidden\n")

      {:error, _} ->
        plain(conn, 410, "gone\n")
    end
  end

  defp plain(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet.ntoa() |> to_string()

  defp remote_ip(_conn), do: nil
end
