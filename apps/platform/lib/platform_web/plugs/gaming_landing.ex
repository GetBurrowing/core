defmodule PlatformWeb.Plugs.GamingLanding do
  @moduledoc "Send only the gaming install's app-host root to its public game home."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  def init(opts), do: opts

  def call(%{method: "GET", request_path: "/"} = conn, _opts) do
    if PlatformWeb.ExternalSurface.router_surface(conn) == :app and Platform.Gaming.enabled?() do
      conn |> redirect(to: "/play") |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
