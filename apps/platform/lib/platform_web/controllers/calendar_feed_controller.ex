defmodule PlatformWeb.CalendarFeedController do
  use PlatformWeb, :controller

  def show(conn, %{"token" => token}) do
    conn =
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    case Platform.Calendar.feed_scope(token) do
      {:ok, scope} ->
        conn
        |> put_resp_content_type("text/calendar")
        |> send_resp(200, Platform.Calendar.Feed.render(scope))

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end
