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

  pipeline :mcp do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.RuntimeBearerAuth)
  end

  pipeline :require_auth do
    plug(PlatformWeb.Plugs.RequireAuth)
  end

  # JSON-API auth: same session check as :require_auth but returns 401 JSON
  # on failure instead of redirecting. Mounted on /api/* routes that need
  # an authenticated browser session (e.g. PATCH /api/messages/:id).
  pipeline :require_auth_api do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(PlatformWeb.Plugs.RequireAuthAPI)
  end

  # Attachment reads accept either a browser session or a runtime bearer
  # token. The plug assigns `conn.assigns.principal` in either shape so the
  # controller can authorize against the attachment's `space_id`.
  pipeline :attachment_auth do
    plug(:accepts, ["html", "json"])
    plug(:fetch_session)
    plug(PlatformWeb.Plugs.AttachmentAuth)
  end

  scope "/", PlatformWeb do
    pipe_through(:attachment_auth)

    get("/chat/attachments/:id", ChatAttachmentController, :show)
  end

  # Presigned upload POST — HMAC token in the URL is the only auth. No
  # session / no bearer. Body parsers are bypassed via the endpoint's
  # body-reader skip-list so the controller can stream raw bytes.
  scope "/", PlatformWeb do
    pipe_through(:api)

    post("/chat/attachments/upload/:token", ChatAttachmentUploadController, :create)
  end

  scope "/", PlatformWeb do
    pipe_through(:browser)

    get("/health", HealthController, :index)
    get("/auth/login", AuthController, :login)
    get("/auth/oidc/callback", AuthController, :callback)
    get("/auth/logout", AuthController, :logout)

    # T7 stage 2 (task 019e41da-3610-7972-8573-54121ea1f3f5): retired
    # `/org-context[/:file_key]` paths 301-redirect to the new
    # `/org_memory[/:file_key]` surface. Mounted in the unauthenticated
    # `:browser` scope so old bookmarks redirect first, then the new
    # path applies its own auth gate.
    get("/org-context", PageController, :org_context_redirect)
    get("/org-context/:file_key", PageController, :org_context_redirect)

    if Mix.env() == :dev do
      get("/dev/login", AuthController, :dev_login)
    end
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth])

    # Root redirects to /chat
    get("/", PageController, :home)

    get("/artifacts/preview", ArtifactPreviewController, :show)
    get("/api/transcripts/:id/download", TranscriptController, :show)

    live_session :authenticated,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
      live("/activity", ActivityLive, :index)
      live("/inbox", InboxLive, :index)
      live("/tasks", TasksLive, :index)
      live("/tasks/:task_id", TasksLive, :show)
      live("/meetings", MeetingLive, :index)
      live("/meetings/:slug", MeetingLive, :show)
      live("/skills", SkillsLive, :index)
      live("/skills/:slug", SkillsLive, :show)
      live("/changelog", ChangelogLive, :index)
      live("/control", ControlCenterLive, :index)
      live("/control/usage", UsageLive, :index)
      live("/control/:agent_slug", ControlCenterLive, :show)
      live("/org_memory", OrgMemoryLive, :index)
      live("/org_memory/:file_key", OrgMemoryLive, :show)
    end

    # MT/RBAC stack 2 (task 019e3c4a) — `/admin/*` lives in its own
    # `live_session` so the `:ensure_admin` hook can halt-and-redirect
    # non-admin mounts. Keeps the same `ShellLive` + `LiveAuth :default`
    # prefix so the shell chrome renders before the admin gate fires.
    live_session :admin,
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.LiveAuth, :ensure_admin}
      ],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/admin", AdminLive, :index)
      live("/admin/prompts", AdminPromptsLive, :index)
      live("/admin/prompts/:slug", AdminPromptsLive, :edit)
      live("/admin/federation", AdminFederationLive, :index)
    end
  end

  scope "/api/internal", PlatformWeb do
    pipe_through(:api)
    post("/usage-events", UsageEventController, :create)
  end

  # Editable-messages API (task 019df568-97a4). PATCH for author-only
  # edits; GET versions for the Version History popover. Both require
  # an authenticated browser session via :require_auth_api.
  scope "/api/messages", PlatformWeb do
    pipe_through(:require_auth_api)

    patch("/:id", MessageController, :update)
    get("/:id/versions", MessageController, :versions)
  end

  scope "/api/meetings", PlatformWeb do
    pipe_through(:api)
    post("/segments", MeetingAgentController, :segments)
  end

  scope "/api/webhooks", PlatformWeb do
    pipe_through(:api)
    post("/github", GithubWebhookController, :handle)
    post("/livekit", LivekitWebhookController, :handle)
  end

  scope "/mcp", PlatformWeb do
    pipe_through(:mcp)
    post("/", MCPController, :handle)
    get("/", MCPController, :stream)
  end
end
