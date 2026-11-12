defmodule PlatformWeb.Plugs.SwitcherBadgeAuth do
  @moduledoc """
  CORS and badge-key authentication for `GET /api/switcher/unread` (task
  01a1ccd4 stage 2, see `Platform.Switcher`) and `DELETE /api/switcher/key`
  (stage 3: the key revoking itself when A's switcher removes B). Those two
  are the only routes a badge key opens.

  No session is fetched and no cookie is read: the key travels in the
  `Authorization: Bearer` header only, never the query string.

    * `OPTIONS` (the preflight carries no credential) answers `204`. It
      echoes `Access-Control-Allow-Origin` for a well-formed request `Origin`
      so the browser will send the real request, and allows the `GET` and
      `DELETE` methods and the `Authorization` header. A missing or
      malformed `Origin` gets no allow header.
    * `GET` and `DELETE` verify the key against the request `Origin`
      (`Platform.Switcher.verify/2`). On success
      `Access-Control-Allow-Origin` is the request `Origin`, which then
      equals the key's `bound_origin`. A refusal is `401`
      `{"error": "unauthorized"}`. It carries `Access-Control-Allow-Origin`
      only when the presented key is one this install minted (live, revoked
      or expired) and the request `Origin` is that key's own bound origin
      (`Platform.Switcher.refusal_origin/2`, task 01a1ccd4 stage 4): the
      switcher page holding a revoked or expired key can READ the 401 and
      show "Reconnect" instead of "Can't reach", while any other origin (a
      hostile page replaying the key, an unknown key) gets no allow header
      and the browser hides the response from it.

  Never `*`, never `Access-Control-Allow-Credentials`, always
  `Vary: Origin`.
  """

  import Plug.Conn

  alias Platform.Switcher

  @max_age "600"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn = put_resp_header(conn, "vary", "Origin")

    conn =
      case request_origin(conn) do
        {:ok, origin} ->
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("access-control-allow-methods", "GET, DELETE")
          |> put_resp_header("access-control-allow-headers", "Authorization")
          |> put_resp_header("access-control-max-age", @max_age)

        :error ->
          conn
      end

    conn |> send_resp(204, "") |> halt()
  end

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("vary", "Origin")
      |> put_resp_header("cache-control", "no-store")

    token = bearer(conn)
    origin = single_header(conn, "origin")

    case Switcher.verify(token, origin) do
      {:ok, user, key} ->
        :ok = Switcher.touch(key)

        conn
        |> put_resp_header("access-control-allow-origin", key.bound_origin)
        |> assign(:current_user, user)
        |> assign(:switcher_badge_key, key)

      :error ->
        conn
        |> allow_key_origin(token, origin)
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  defp allow_key_origin(conn, token, origin) do
    case Switcher.refusal_origin(token, origin) do
      {:ok, origin} -> put_resp_header(conn, "access-control-allow-origin", origin)
      :error -> conn
    end
  end

  defp request_origin(conn) do
    with [origin] <- get_req_header(conn, "origin"),
         {:ok, normalized} <- Switcher.normalize_origin(origin) do
      {:ok, normalized}
    else
      _ -> :error
    end
  end
end
