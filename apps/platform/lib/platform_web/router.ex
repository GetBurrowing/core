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

    if Mix.env() == :dev do
      get("/dev/login", AuthController, :dev_login)
    end
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth])

    # Root redirects to /chat
    get("/", PageController, :home)

    get("/chat/attachments/:id", ChatAttachmentController, :show)
    get("/artifacts/preview", ArtifactPreviewController, :show)

    live_session :authenticated,
      on_mount: [PlatformWeb.ShellLive],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
      live("/tasks", TasksLive, :index)
      live("/tasks/:task_id", TasksLive, :show)
      live("/skills", SkillsLive, :index)
      live("/skills/:slug", SkillsLive, :show)
      live("/changelog", ChangelogLive, :index)
      live("/control", ControlCenterLive, :index)
      live("/control/usage", UsageLive, :index)
      live("/control/:agent_slug", ControlCenterLive, :show)
      live("/admin/prompts", AdminPromptsLive, :index)
      live("/admin/prompts/:slug", AdminPromptsLive, :edit)
      live("/admin/federation", AdminFederationLive, :index)
    end
  end

  scope "/api/internal", PlatformWeb do
    pipe_through(:api)
    post("/usage-events", UsageEventController, :create)
  end

  scope "/api/webhooks", PlatformWeb do
    pipe_through(:api)
    post("/github", GithubWebhookController, :handle)
  end
end
