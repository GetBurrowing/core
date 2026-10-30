defmodule PlatformWeb.BookingRateLimitPlug do
  @moduledoc "Bounds unauthenticated public booking requests before resolving tokens."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    case Platform.Calendar.BookingRateLimit.check({:ip, conn.remote_ip}, 1, 60) do
      :ok ->
        conn

      _ ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, "Too many requests. Try again shortly.")
        |> halt()
    end
  end
end
