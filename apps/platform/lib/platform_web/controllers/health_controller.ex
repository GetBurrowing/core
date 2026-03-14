defmodule PlatformWeb.HealthController do
  use PlatformWeb, :controller

  def index(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
