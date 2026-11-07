defmodule PlatformWeb.SupportGrantController do
  @moduledoc """
  `POST /api/support-access/v1/grants` (task 01a1b362 stage 1, ADR 0059).
  The verdict lives in `Platform.SupportAccess.request_grant/3`; this
  controller reads the raw body (capped at `Grant.max_bytes/0` while
  reading), answers the result, and counts failed signatures against the
  caller's IP.

  A refusal answers `{"error": "<reason>"}` with `Grant.status_for/1` and
  never echoes the request. A success answers the session: for `admin`,
  `session_id`, `sign_in_url`, `not_after`; for `repair`, `session_id`,
  `principal`, `not_after`. The sign-in URL appears only in this response.
  """
  use PlatformWeb, :controller

  alias Platform.SupportAccess
  alias Platform.SupportAccess.Grant
  alias Platform.SupportAccess.JunkLimit

  def create(conn, _params) do
    case read_capped(conn) do
      {:ok, raw, conn} ->
        case SupportAccess.request_grant(raw, conn.req_headers) do
          {:ok, response} ->
            conn |> put_status(201) |> json(response)

          {:error, reason} ->
            unless Grant.signed?(reason), do: JunkLimit.count(conn.remote_ip)
            refuse(conn, reason)
        end

      {:error, reason, conn} ->
        JunkLimit.count(conn.remote_ip)
        refuse(conn, reason)
    end
  end

  defp read_capped(conn) do
    max = Grant.max_bytes()

    case read_body(conn, length: max + 1, read_length: max + 1) do
      {:ok, body, conn} when byte_size(body) <= max -> {:ok, body, conn}
      {:ok, _body, conn} -> {:error, :too_large, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, _} -> {:error, :bad_signature, conn}
    end
  end

  defp refuse(conn, reason) do
    conn
    |> put_status(Grant.status_for(reason))
    |> json(%{error: to_string(reason)})
  end
end
