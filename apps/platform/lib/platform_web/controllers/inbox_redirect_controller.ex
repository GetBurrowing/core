defmodule PlatformWeb.InboxRedirectController do
  @moduledoc """
  `/inbox` -> `/brief`, query string and all (task 01a1b721 stage 4).

  The Inbox index is now `PlatformWeb.SecretaryLive` at `/brief`. This
  route stays as a redirect for the native tab bar, saved route-resume paths
  and `?open=<id>` links already in the wild (pushes, briefings), so
  `/inbox?open=<id>` opens that row on `/brief` exactly as before. The
  detail routes `/inbox/briefing/:date` and `/inbox/meeting/:meeting_id`
  are untouched: they still render `PlatformWeb.InboxLive`.

  Registered in `Platform.ParallelUI` as `inbox-index-redirect`; its cutover
  is child task 01a1b754-4998-7000-8816-d2be5e640f5f.
  """

  # parallel-ui: inbox-index-redirect

  use PlatformWeb, :controller

  def index(conn, _params) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/brief" <> query)
  end
end
