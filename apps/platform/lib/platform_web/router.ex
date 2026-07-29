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

  # GitHub webhook pipeline — task 019f9b11 stage 2. Same shape as
  # `:livekit_webhook`: the endpoint's `Plug.Parsers`/`CacheBodyReader` has
  # already populated `conn.assigns[:raw_body]` by the time this fires, and
  # the plug verifies `X-Hub-Signature-256` against the per-project secret or
  # the app-level `GITHUB_WEBHOOK_SECRET`, halting with 401 on failure.
  # Enforcement lives here rather than in the controller so a future action on
  # `GithubWebhookController` cannot ship unauthenticated, and so the 401
  # happens before any controller code runs. Rollback valve:
  # `:github_webhook_signature_required` — see
  # `docs/runbooks/github_webhook_secret.md`.
  pipeline :github_webhook do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.VerifyGithubSignature)
  end

  pipeline :mcp do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.RuntimeBearerAuth)
  end

  pipeline :require_auth do
    plug(PlatformWeb.Plugs.RequireAuth)
  end

  # Authorization gate for external users (rbac-external-users M6, task
  # 019f8837). MUST run AFTER `:require_auth` — it reads the assigns that
  # RequireAuth sets. Kept as a SEPARATE pipeline (rather than appended
  # inside `:require_auth`) so the auth-vs-authz seam stays legible and
  # other scopes can opt in independently. No-op for internal users.
  pipeline :enforce_external_scope do
    plug(PlatformWeb.Plugs.ExternalUserScope)
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

  # ── External-chat host scope (rbac-external-users M4, task 019f8837) ──
  #
  # INERT / DARK scaffold. Mirrors the `meet.` guest scope structurally
  # (see the `meet.` scope near the bottom of this file) but for the
  # authenticated external-chat surface. Phoenix matches on `conn.host`
  # starting with `chat.`, so `chat.example.com` (prod),
  # `chat.localhost` (dev via /etc/hosts), and `chat.<any>` route here
  # while the default `app.*` / `localhost` domain does not. No environment
  # declares a `chat.` host until the M14 subdomain go-live, so this route
  # is unreachable without an explicit spoofed host header — it ships dark.
  #
  # The `:external_chat` live_session pairs the shell-less `:external`
  # layout with a `chat_mode: "external"` session key (merged into the
  # connect session and flowed to `ChatLive.mount/3`, the same mechanism as
  # meet.'s `chrome_mode: "none"`). Layouts are locked at the live_session
  # boundary, so this seam is what lets ChatLive serve BOTH the
  # authenticated `/chat` shell surface (default host) AND the shell-less
  # `chat.` external surface without a router-topology surprise. The
  # `chat_mode` key is dormant until M5 branches ChatLive on it.
  #
  # ── PLACEMENT: this scope is deliberately defined BEFORE the default
  # authenticated `scope "/"` below — a divergence from `meet.`, which
  # sits at the end of the file. Reason: `/chat` and `/chat/:space_slug`
  # OVERLAP the default scope's paths. Phoenix generates one
  # `__match_route__/3` clause per route in definition order and the FIRST
  # matching clause wins; the default `/chat` route carries a
  # match-any-host pattern, so if it were defined first it would win even
  # on `chat.localhost` and shadow `:external_chat` entirely. Defining the
  # host-constrained `chat.` clause first means it wins on the chat host,
  # while its `"chat." <> _` host guard makes it a no-op on the default
  # host (which then falls through to the authenticated `/chat` below).
  # `meet.` never hit this because `/:slug/:token` overlaps no default
  # route, so its end-placement was safe; ours is not.
  #
  # ── Three deliberate divergences from `meet.` (all beyond placement):
  #   1. `pipe_through([:browser, :require_auth])`, NOT the guest pipeline
  #      — external users are authenticated real OIDC accounts (design
  #      canvas §3/§6), not anonymous guests.
  #   2. Reuses the `:browser` pipeline's full `:root` document head (PWA
  #      push, canvas §10-8) rather than a stripped guest_root — external
  #      users get push, so only the APP layout is swapped, to `:external`.
  #   3. Reuses `on_mount: [ShellLive, {LiveAuth, :default}]` — identical
  #      to the `:authenticated` live_session below — so ChatLive mounts
  #      with the assigns its current template references and renders
  #      WITHOUT crashing while inert. M5 replaces this mount chain with
  #      the external branch; M6/M7 add scope auth. No `/` root redirect
  #      (the external landing UX is M5's call) and no endpoint/config
  #      change (the host scope is the whole mechanism, exactly like meet.).
  #
  # NOTE (M4 dormancy limit, surfaced for M6/M7): route omission does NOT
  # limit this host's surface. The default authenticated `scope "/"` below
  # carries a match-any-host pattern, so /tasks, /admin, /org_memory, etc.
  # still resolve on `chat.localhost` via that scope. Restricting the chat
  # host to only /chat is scope-enforcement work owned by M6/M7 (or a
  # host-constrained default scope), not achievable by adding this scope
  # alone. See `router_external_chat_host_test.exs` for the exact contract.
  scope "/", PlatformWeb, host: "chat." do
    pipe_through([:browser, :require_auth, :enforce_external_scope])

    live_session :external_chat,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :external},
      session: %{"chat_mode" => "external"} do
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
    end
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth, :enforce_external_scope])

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

    # Task 019e2c4b stage 3 — the standalone canvas page, the destination a
    # pasted canvas URL resolves to. Same `[:browser, :require_auth,
    # :enforce_external_scope]` pipeline as everything else in this scope.
    #
    # ITS OWN `live_session`, deliberately, and NOT folded into
    # `:authenticated` above even though the `on_mount` chain and layout are
    # identical. `:enforce_external_scope` is an HTTP PLUG, and a
    # `live_redirect` WITHIN a single `live_session` never re-enters the plug
    # pipeline — so a chat-to-canvas hop inside `:authenticated` would skip
    # the external gate entirely. `ExternalUserScope.gate_external/2`
    # (`plugs/external_user_scope.ex:49-62`) additionally falls through to
    # `conn` when `CHAT_HOST` is unset, which is the case in dev and test, so
    # the gap would not show up locally. Crossing a `live_session` boundary
    # forces a full HTTP round-trip, which means the plug always runs.
    #
    # The cost is a full page load on chat-to-canvas navigation. That is
    # irrelevant for a share-link destination, and
    # `assets/js/hooks/route_resume.js` already treats `/canvases` as its own
    # top-level module, so per-module resume behaviour is unaffected.
    #
    # NO NEW ROUTER SCOPE: `/canvases/:id` overlaps neither `/chat` nor
    # `/chat/:space_slug`, so the first-matching-clause host-ordering hazard
    # documented above the `chat.` scope does not apply here. Adding a scope
    # would inherit that hazard for no benefit.
    live_session :canvas_standalone,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/canvases/:id", CanvasLive, :show)
    end

    # rbac-external-users M3 stage 2 (task 019f8837): the zero-access
    # "your workspace is being set up" holding landing. It gets its OWN
    # `live_session` — NOT the `:authenticated` one above, whose `:shell`
    # layout would render the icon rail (a discovery leak that breaks
    # zero-access) — paired with the chrome-less `:holding` layout. Same
    # `on_mount: [ShellLive, {LiveAuth, :default}]` prefix so
    # `current_user_record` + membership assigns are present; ShellLive
    # tolerates a holding user (current_user_id set, zero scoped rows).
    #
    # A no-host route matches BOTH the app host and M4's future `chat.`
    # host — M4's chat scope claims only `/chat` + `/chat/:slug`, so
    # `/welcome` falls through to here on either host with one route. The
    # default scope's `:enforce_external_scope` plug is a no-op for holding
    # users (they hold no external membership, so `external_user?/1` is
    # false), so it does not fence `/welcome`.
    live_session :external_holding,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :holding} do
      live("/welcome", ExternalHoldingLive, :index)
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
      # rbac-external-users M3 stage 4 (task 019f8837): the Fabrikam-admin
      # recovery queue for external logins awaiting setup. Inherits the
      # `:ensure_admin` gate + `:shell` chrome from this live_session.
      live("/admin/external-logins", ExternalRecoveryLive, :index)
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
    pipe_through(:github_webhook)
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
