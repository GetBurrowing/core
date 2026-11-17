defmodule PlatformWeb.SwitcherUnreadController do
  @moduledoc """
  `GET /api/switcher/unread` (task 01a1ccd4 stage 2): the unread total another
  install's web switcher shows as a dot. Authenticated and CORS-gated by
  `PlatformWeb.Plugs.SwitcherBadgeAuth`; the body is exactly
  `{"unread": <integer>, "as_of": <ISO-8601>}` (`Platform.Switcher.unread_payload/1`).
  """
  use PlatformWeb, :controller

  def show(conn, _params) do
    json(conn, Platform.Switcher.unread_payload(conn.assigns.current_user))
  end
end
