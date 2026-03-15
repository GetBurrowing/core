defmodule PlatformWeb.Router do
  use PlatformWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
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

    # Root redirects to /chat
    get("/", PageController, :home)

    get("/chat/attachments/:id", ChatAttachmentController, :show)

    live_session :authenticated,
      on_mount: [PlatformWeb.ShellLive],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
      live("/control", ControlCenterLive, :index)
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", PlatformWeb do
  #   pipe_through :api
  # end
end
