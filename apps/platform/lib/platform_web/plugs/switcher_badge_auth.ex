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
      `{"error": "unauthorized"}`, and (task 01a1ccd4 stage 3) it echoes a
      well-formed request `Origin` exactly as the preflight already does, so
      the switcher page holding a revoked or expired key can READ the 401
      and show "Reconnect" instead of "Can't reach". The body says nothing
      but "unauthorized"; a malformed or missing `Origin` still gets no
      allow header.

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

    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         [origin] <- get_req_header(conn, "origin"),
         {:ok, user, key} <- Switcher.verify(token, origin) do
      :ok = Switcher.touch(key)

      conn
      |> put_resp_header("access-control-allow-origin", key.bound_origin)
      |> assign(:current_user, user)
      |> assign(:switcher_badge_key, key)
    else
      _ ->
        conn
        |> allow_request_origin()
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp allow_request_origin(conn) do
    case request_origin(conn) do
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
