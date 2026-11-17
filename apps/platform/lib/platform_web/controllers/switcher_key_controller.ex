defmodule PlatformWeb.SwitcherKeyController do
  @moduledoc """
  `DELETE /api/switcher/key` (task 01a1ccd4 stage 3): the badge key in the
  Authorization header revokes itself. Install A's web switcher calls this,
  best effort and never awaited, when the person removes install B in
  Manage installs, so the Remove copy ("A stops getting its unread count")
  holds on B's side too. Authenticated and CORS-gated by
  `PlatformWeb.Plugs.SwitcherBadgeAuth`, exactly as the unread route is: the
  key must be live and the request `Origin` must be the key's origin.
  """
  use PlatformWeb, :controller

  def delete(conn, _params) do
    :ok = Platform.Switcher.revoke_key(conn.assigns.switcher_badge_key)
    send_resp(conn, 204, "")
  end
end
