defmodule PlatformWeb.Plugs.SupportActionAudit do
  @moduledoc """
  Per-action audit for vendor support admin sessions (task 01a1b362 stage 1,
  ADR 0059). For every non-GET, non-HEAD request by a `support_vendor` user it
  records `support.action` with the method, the request path and the sha256
  of the params (`Platform.SupportAccess.record_action/3`). Never the param
  values, never a response body. A no-op for every other user.

  Runs after `RequireAuth` / `RequireAuthAPI`, which have already refused a
  support user without an active session. The LiveView half is
  `PlatformWeb.LiveAuth`'s `handle_event` hook.
  """

  import Plug.Conn

  alias Platform.Accounts.User
  alias Platform.SupportAccess

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %User{support_vendor: true} = user}} = conn, _opts)
      when conn.method not in ["GET", "HEAD"] do
    conn = fetch_session(conn)

    SupportAccess.record_action(user, get_session(conn, :support_session_id), %{
      kind: "http",
      method: conn.method,
      route: conn.request_path,
      params: conn.params
    })

    conn
  end

  def call(conn, _opts), do: conn
end
