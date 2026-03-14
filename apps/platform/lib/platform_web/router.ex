defmodule PlatformWeb.Router do
  use PlatformWeb, :router

  @session_options [
    store: :cookie,
    key: "_platform_session",
    signing_salt: "LVkhtRt/",
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:platform, :env) == :prod
  ]

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(Plug.Session, @session_options)
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PlatformWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :require_auth do
    plug(PlatformWeb.Plugs.RequireAuth)
  end

  scope "/", PlatformWeb do
    pipe_through(:browser)

    get("/health", HealthController, :index)
    get("/auth/login", AuthController, :login)
    get("/auth/oidc/callback", AuthController, :callback)
    get("/auth/logout", AuthController, :logout)
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth])

    live("/", ChatLive, :index)
  end

  # Other scopes may use custom stacks.
  # scope "/api", PlatformWeb do
  #   pipe_through :api
  # end
end
