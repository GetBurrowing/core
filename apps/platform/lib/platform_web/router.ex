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

  # Guest meeting ingress pipeline (task 019f2483 stage 3). Mirrors :browser
  # but installs the stripped `guest_root` layout (no shell chrome, no
  # sidebar, no sign-in CTA) and — critically — does NOT apply
  # `:require_auth`. Mounted under the dedicated `meet.` host scope below
  # so `/:slug/:token` on `meet.example.com` renders the guest
  # LiveView while the primary hostname remains fully authenticated.
  pipeline :guest_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PlatformWeb.Layouts, :guest_root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # LiveKit webhook pipeline — task 019f3312 stage 2. Runs after the
  # endpoint's global `Plug.Parsers`, so `conn.assigns[:raw_body]` is
  # already populated by `CacheBodyReader` by the time this pipeline
  # fires. The signature plug verifies the HMAC-JWT signature (HS256 +
  # `sha256` body-hash claim) and halts with 401 on failure when the
  # `:livekit_webhook_signature_required` flag is on (prod default).
  # The flag is `false` in `config/test.exs` so existing controller
  # tests keep exercising handlers without minting a JWT per payload.
  pipeline :livekit_webhook do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.VerifyLivekitSignature)
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
    get("/org-context/*file_key", PageController, :org_context_redirect)

    if Mix.env() == :dev do
      get("/dev/login", AuthController, :dev_login)
    end
  end

  # Dev-only evidence helpers: POST endpoints to drive `@meeting_active`
  # on the shell for screenshot capture of `#meeting-watchdog` mount/
  # unmount (task 019ee06b-d62d stage 2 v2). Separate scope so the
  # session is fetched but CSRF protection (which would reject the
  # bare CDP-issued POST) is bypassed. Unreachable in prod — the
  # `Mix.env() == :dev` guard prevents route registration entirely.
  if Mix.env() == :dev do
    pipeline :dev_session_json do
      plug(:accepts, ["json"])
      plug(:fetch_session)
    end

    scope "/dev", PlatformWeb do
      pipe_through(:dev_session_json)

      post("/meeting_evidence/join", DevMeetingEvidenceController, :join)
      post("/meeting_evidence/leave", DevMeetingEvidenceController, :leave)
    end
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth])

    # Root redirects to /chat
    get("/", PageController, :home)

    get("/artifacts/preview", ArtifactPreviewController, :show)
    get("/api/transcripts/:id/download", TranscriptController, :show)

    # ADR-0042 stage 5: inline preview for FilesLive (images / PDFs / text).
    # Same `:require_auth` browser pipeline as the /files LV routes — the
    # controller does the per-file org-membership check.
    get("/files/blob/:id", FileBlobController, :show)

    live_session :authenticated,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
      live("/activity", ActivityLive, :index)
      live("/inbox", InboxLive, :index)
      live("/tasks", TasksLive, :index)
      live("/tasks/:task_id", TasksLive, :show)
      # ADR-0042 stage 5: project-scoped document store
      live("/files", FilesLive, :index)
      live("/files/:project_id", FilesLive, :show)
      live("/meetings", MeetingLive, :index)
      live("/meetings/:slug", MeetingLive, :show)
      live("/skills", SkillsLive, :index)
      live("/skills/:slug", SkillsLive, :show)
      live("/changelog", ChangelogLive, :index)
      live("/control", ControlCenterLive, :index)
      live("/control/usage", UsageLive, :index)
      live("/control/:agent_slug", ControlCenterLive, :show)
      live("/org_memory", OrgMemoryLive, :index)
      # Task 019f70e9 stage 4 — direct entry to the proposals tab.
      # `live_action == :proposals` mounts the same OrgMemoryLive and
      # `handle_params/3` switches view_mode + preloads the pending
      # stream before first render.
      live("/memory/proposals", OrgMemoryLive, :proposals)
      # Glob route: path-style file_keys (`org/identity.md`) span multiple
      # segments, so `:show` must match `/org_memory/*file_key`.
      live("/org_memory/*file_key", OrgMemoryLive, :show)
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
      live("/admin/recovery", RecoveryLive, :index)
      live("/admin/users", UserAccessLive, :index)
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
  end

  scope "/api/webhooks", PlatformWeb do
    pipe_through(:livekit_webhook)
    post("/livekit", LivekitWebhookController, :handle)
  end

  scope "/mcp", PlatformWeb do
    pipe_through(:mcp)
    post("/", MCPController, :handle)
    get("/", MCPController, :stream)
  end

  # Guest meeting ingress (task 019f2483 stage 3, consolidated onto
  # MeetingLive in task 019f498d stage 5). Bound to the dedicated
  # `meet.` host prefix — Phoenix matches on `conn.host` starting with
  # this string, so `meet.example.com` (prod), `meet.localhost`
  # (dev with `/etc/hosts`), and `meet.<any>.<tld>` all route here while
  # the primary `app.*` / `localhost` domain does not. Ships without a
  # `Mix.env()` guard because the guest flow must work in prod, dev, and
  # test alike (the test harness sets `conn.host` explicitly per case).
  #
  # The `:guest_meeting` live_session pairs the stripped `:guest` layout
  # with the `chrome_mode: "none"` session key — LiveView layouts are
  # locked at the `live_session` boundary and cannot be re-chosen at
  # mount time, so this seam is what lets MeetingLive serve both the
  # authenticated `/meetings/:slug` shell surface AND the shellless
  # `meet.` guest surface without a router topology surprise. The mount
  # branch inside `MeetingLive.mount/3` selects on the injected session
  # key; the `:show` action lines up with the existing
  # `MeetingLive.handle_params/3` contract.
  scope "/", PlatformWeb, host: "meet." do
    pipe_through(:guest_browser)

    live_session :guest_meeting,
      layout: {PlatformWeb.Layouts, :guest},
      session: %{"chrome_mode" => "none"} do
      live("/:slug/:token", MeetingLive, :show)
    end
  end
end
