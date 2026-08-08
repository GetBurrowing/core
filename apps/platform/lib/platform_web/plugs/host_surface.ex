defmodule PlatformWeb.Plugs.HostSurface do
  @moduledoc """
  Fence for the DEFAULT (app-host) router scope: a request whose hostname
  belongs to another surface's host scope does not get to reach an app route.

  WHY A PIPELINE PLUG AND NOT A `host:` SCOPE. Phoenix's `host:` option is a
  COMPILE-TIME string prefix baked into `__match_route__/3`. The app host is
  `PHX_HOST`, read at RUNTIME in `config/runtime.exs`, so
  `scope "/", host: <app host>` is not expressible. The achievable and
  structurally correct equivalent is this plug applied to the default scope's
  PIPELINE. That is still a real improvement over route-level allowlisting:
  `PlatformWeb.Plugs.ExternalUserScope` allowlists ROUTES and must be edited
  whenever anyone adds one, whereas a scope-level pipeline plug is inherited
  automatically by every route added to the scope.

  The surface answer comes from `PlatformWeb.ExternalSurface.router_surface/1`
  — the prefix rule, which is the complement of the router's own mechanism —
  and NOT from `for_conn/1`, whose exact `:meet_host` match is unset in dev
  and test and would make this fence fail-open there.

  SHIPS DARK. `call/2` is a no-op unless
  `Application.get_env(:platform, :host_surface_enforcement, :off)` is
  anything other than `:off`. Flipping it is a one-line, independently
  revertible change.

  A denial is a flat `404` rendered through `PlatformWeb.ErrorHTML` /
  `PlatformWeb.ErrorJSON`, mirroring `ExternalUserScope`'s deny path. The body
  deliberately does not echo `conn.request_path` and does not redirect to the
  requested path on another host: reflecting the path both confirms the route
  exists (an existence oracle) and is an open-redirect shape.
  """

  import Plug.Conn

  alias PlatformWeb.ExternalSurface

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    if enforcement() == :off do
      conn
    else
      case ExternalSurface.router_surface(conn) do
        :app -> conn
        _other -> deny(conn)
      end
    end
  end

  defp enforcement, do: Application.get_env(:platform, :host_surface_enforcement, :off)

  # Uniform 404. The catch-all `render/2` in ErrorHTML/ErrorJSON already
  # yields "Not Found" for the `:"404"` template, so no new template clause is
  # needed — and no request-derived value reaches the response body.
  defp deny(conn) do
    conn
    |> put_status(:not_found)
    |> Phoenix.Controller.put_view(html: PlatformWeb.ErrorHTML, json: PlatformWeb.ErrorJSON)
    |> Phoenix.Controller.render(:"404")
    |> halt()
  end
end
