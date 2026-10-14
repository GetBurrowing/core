defmodule PlatformWeb.Plugs.RequireSignInAdmin do
  @moduledoc """
  Answers 404 for `/admin/sign-in-users` whenever
  `Platform.SignInAdmin.Config.enabled?/0` is false (task
  01a113ea-3ef4-7001-b3fc-5d0a1bafc5df).

  It runs BEFORE `:require_auth` in the route's pipeline, so a signed-out
  caller, a non-admin and an admin all get the same 404 on an install without
  the switch: the page does not exist there, and a login redirect would say
  that it does. `PlatformWeb.AdminSignInUsersLive.mount/3` raises the same
  404, which covers a websocket mount after the environment changed.
  """

  @behaviour Plug

  defmodule NotFoundError do
    @moduledoc "Raised to answer 404 while the sign-in users page is switched off."
    defexception message: "not found", plug_status: 404
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Platform.SignInAdmin.Config.enabled?() do
      conn
    else
      raise NotFoundError
    end
  end
end
