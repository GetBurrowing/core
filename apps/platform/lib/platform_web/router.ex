defmodule PlatformWeb.Router do
  @moduledoc """
  THE THREE-BUCKET RULE (task 019fcf22). Every route in this file is exactly
  one of three things, and adding a route means picking one deliberately:

    1. **App-fenced** — declared in the default `scope "/"`, whose pipeline
       ends in `:require_app_surface`. Reachable only on the app host. This is
       the default and the right answer for anything an internal user
       navigates to.
    2. **Host-scoped** — declared inside `scope "/", host: "chat."` or
       `host: "meet."`. Phoenix's `host:` is a compile-time hostname PREFIX
       match, and these scopes are the exact complement of
       `PlatformWeb.ExternalSurface.router_surface/1`, which the fence plug
       consults.
    3. **Host-agnostic** — deliberately answers on every host. This bucket is
       small, load-bearing, and the one that breaks silently, so each member
       carries a comment at its scope saying WHY. Today it is: `/health` and
       the `/auth/*` login flow (the OIDC callback especially — external
       sign-in begins on the chat host and the IdP's registered redirect URI
       is a fixed absolute URL), the `/org-context[/*file_key]` 301s, the
       HMAC-token attachment routes, the subscribed `invite.ics` calendar
       feed, the `/api/*` + `/mcp` machine callers, the
       `/files/signed/:token` signed file GET, and the
       `/.well-known/suite-federation` (and `/.well-known/burrow-federation`)
       peer descriptor.

  Enforcement of bucket 1 is the `:host_surface_enforcement` config flag, `:on`
  as of stage 4. The whole point of it being a flag is that the rollback is one
  line in `config/config.exs` and touches nothing else.

  Placement within this file is itself semantic: Phoenix emits one
  `__match_route__/3` clause per route in definition order and the first match
  wins, so a host scope must be declared ABOVE the match-any-host default
  scope or it is shadowed. See the comments above the `meet.` guest scope.
  """
  use PlatformWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PlatformWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Task 01a09415: content-negotiation variant of `:browser` used by ONE
  # route, `/files/blob/:id`. Identical to `:browser` — same plugs, same
  # order — except `:accepts` also admits "json".
  #
  # Why: `:browser`'s FIRST plug is `plug(:accepts, ["html"])`, which runs
  # ahead of `:require_auth`, so a caller sending `Accept: application/json`
  # was refused with 406 by content negotiation before the auth layer ever
  # ran. (Discriminator: the same request carrying a VALID session cookie
  # also returned 406, so the 406 was never an authentication outcome.)
  # Widening `:browser` itself was rejected — it is piped by the whole app —
  # and mounting the route on `:api` was rejected because `:api` has no
  # `fetch_session` and this route authorizes off the session.
  #
  # `put_secure_browser_headers` is LOAD-BEARING and must stay: the
  # controller's sandbox CSP APPENDS to the `base-uri` / `frame-ancestors`
  # this plug sets (see FileBlobController's "APPENDS rather than sets"
  # note). Dropping it would silently remove both while looking like a
  # hardening change.
  #
  # Widening `:accepts` here is behaviourally inert beyond removing the
  # 406: every exit path of `FileBlobController.show/2` is `send_download/3`
  # or `send_resp/3` — no `render`, no template lookup, no
  # `action_fallback` — so no already-working caller's bytes change.
  pipeline :blob_browser do
    plug(:accepts, ["html", "json"])
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
  # so `/:slug/:token` on the meet host renders the guest
  # LiveView while the primary hostname remains fully authenticated.
  pipeline :guest_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PlatformWeb.Layouts, :guest_root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Prototype bundles (task 01a1316b-4e46 stage 1, ADR 0057). No `:accepts`:
  # a bundle's `<script src>`, stylesheet, image and font requests send their
  # own Accept headers and every one must reach the controller. No root layout
  # and no `protect_from_forgery`: every route is a GET that renders nothing.
  # `put_secure_browser_headers` is LOAD-BEARING, as on `:blob_browser`: the
  # controller's sandbox CSP APPENDS to its `frame-ancestors 'self'`.
  pipeline :proto_browser do
    plug(:fetch_session)
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


  # Extension HTTP routes (ADR 0055 Follow-up 2): `/api/ext/<prefix>/...` is
  # dispatched at runtime to the extension claiming `<prefix>`
  # (`PlatformWeb.Plugs.ExtensionRoutes`). JSON only and NOTHING else on
  # purpose: no session, no CSRF, no current user. The extension's plug owns
  # its authentication (e.g. a webhook signature) and halts on failure.
  # `test/platform_web/plugs/extension_routes_test.exs` pins that this
  # pipeline never gains `fetch_session`.
  pipeline :extension_api do
    plug(:accepts, ["json"])
  end

  # Peer-install inbox pipeline — task 01a0d90f stage 3, ADR 0054. Unlike
  # `:github_webhook`, the body is NOT pre-read: the inbox path is on
  # `PlatformWeb.Plugs.RawBodyPaths`' skip-list, and `VerifyPeerEnvelope`
  # reads it itself with the 256 KB cap applied WHILE reading (see its
  # moduledoc), then verifies the Ed25519 envelope and halts on any refusal
  # before controller code runs.
  pipeline :peer_envelope do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.VerifyPeerEnvelope)
  end

  pipeline :mcp do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.RuntimeBearerAuth)
  end

  # Native app API (task 01a10882). Bearer-authenticated per request against
  # `app_sessions` (`AppBearerAuth`, the user-side mirror of the runtime
  # bearer above); no session cookie, no CSRF. External users are scoped in
  # the controller with the same predicates `:enforce_external_scope` uses
  # (`Platform.Chat.ExternalScope`), because that plug's allowlist is keyed
  # on browser paths and would 403 every `/api/app` route outright.
  pipeline :app_api do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.AppBearerAuth)
  end

  # Push relay (task 01a1261e stage 2): 404 unless relay mode is on, 401
  # without a live install credential.
  pipeline :push_relay do
    plug(:accepts, ["json"])
    plug(PlatformWeb.Plugs.PushRelayAuth)
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

  # App-surface fence (task 019fcf22 stage 3). `HostSurface` halts with 404
  # when the request arrives on a `chat.` or `meet.` prefixed host, so the
  # match-any-host default scope stops answering for the whole app on the
  # external hosts. Enforcement is a config flag
  # (`:host_surface_enforcement`, default `:off`), so wiring this pipeline in
  # changes NOTHING observable until that flag flips.
  #
  # Applied at the SCOPE, not per route: `ExternalUserScope` allowlists routes
  # and must be edited whenever anyone adds one; a pipeline plug is inherited
  # by every route added to the scope from then on.
  #
  # LIVE_SESSION NOTE: `HostSurface` is an HTTP plug, so a `live_redirect`
  # WITHIN one `live_session` does not re-enter it. That is acceptable here,
  # unlike for `:enforce_external_scope`: every `live_session` in the fenced
  # scope is entered by an HTTP mount that DID pass this plug, so a wrong-host
  # user never gets inside the session to begin with. Do NOT cargo-cult the
  # `:canvas_standalone` live_session split below on account of this plug —
  # that split exists for a different reason and adding more would buy nothing.
  pipeline :require_app_surface do
    plug(PlatformWeb.Plugs.HostSurface)
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

  # HOST-AGNOSTIC (deliberate, not an oversight — task 019fcf22 stage 3).
  # Attachment fetch authenticates off an HMAC token in the URL or a runtime
  # bearer, never a host. Attachment URLs are minted relative and pasted into
  # chat messages and canvases, so a URL copied while on the chat host must
  # keep resolving there. No `:require_app_surface`.
  scope "/", PlatformWeb do
    pipe_through(:attachment_auth)

    get("/chat/attachments/:id", ChatAttachmentController, :show)
  end

  # Agent avatar reads (task 01a00122 stage 1). A plain authenticated session
  # is the whole gate — see `AgentAvatarController`'s moduledoc for why the
  # two existing byte routes' gates (space membership / project org
  # membership) would blank the avatar for legitimate viewers.
  #
  # `:accepts ["html", "json"]` matches `:attachment_auth` rather than naming
  # an image type: browsers send `Accept: image/avif,…,*/*` for an <img>, and
  # this exact list already serves every inline chat image today.
  pipeline :agent_avatar do
    plug(:accepts, ["html", "json"])
    plug(:fetch_session)
    plug(PlatformWeb.Plugs.RequireAuth)
  end

  # HOST-AGNOSTIC (deliberate — same reasoning as the attachment scope
  # above). Avatar URLs are minted RELATIVE and rendered on the chat host,
  # the meet host and the default host alike. Under the fenced default scope
  # `:require_app_surface` would 404 this on `chat.`/`meet.` once
  # `:host_surface_enforcement` is on, breaking every agent avatar on two of
  # the three surfaces while the control center kept looking fine.
  scope "/", PlatformWeb do
    pipe_through(:agent_avatar)

    get("/agents/:id/avatar", AgentAvatarController, :show)
  end

  # Agent avatar reads for the native app (task 01a12773 stage 1). The FCM
  # service and the iOS Notification Service Extension hold an
  # `app_sessions` bearer and no session cookie, so `:agent_avatar` answers
  # them 401. Same controller, same 404s; only the authentication differs.
  #
  # A SEPARATE pipeline rather than a bearer branch inside `:agent_avatar`:
  # that pipeline is the browser <img> gate, and `RequireAuth`'s deny
  # contract (302 vs 401) is keyed on it. Mixing a bearer path in would
  # change every browser avatar request.
  #
  # NO `:accepts` plug, deliberately. `:agent_avatar`'s `["html", "json"]`
  # works for browsers only because an <img> request's Accept ends in
  # `*/*`; a bare `Accept: image/png` (or `image/*`) raises
  # `Phoenix.NotAcceptableError`, a 406. A native HTTP client may send
  # exactly that, and a 406 here is a silent fall back to the letter icon.
  # `:app_api` (json only) refuses the same requests. Nothing is negotiated
  # on this route: the controller takes the content type from the storage
  # key and ignores Accept, so an `:accepts` list could only ever refuse.
  pipeline :app_avatar do
    plug(PlatformWeb.Plugs.AppBearerAuth)
  end

  # HOST-AGNOSTIC, like the browser avatar scope above and every other
  # `/api/app` route.
  scope "/api/app", PlatformWeb do
    pipe_through(:app_avatar)

    # `:app_show`, not `:show`: the app gets a thumbnail of a large avatar,
    # because both Burrow apps drop a body over 256 KB (see
    # `AgentAvatarController.app_show/2`).
    get("/agents/:id/avatar", AgentAvatarController, :app_show)

    # A member's avatar for a push notification: `users.avatar_url` fetched
    # server-side and served at a size both apps accept (see
    # `UserAvatarController`).
    get("/users/:id/avatar", UserAvatarController, :app_show)
  end

  # Install PWA icon reads (task 01a0879a stage 3). NOTHING but `:accepts` —
  # no `fetch_session`, no `RequireAuth`, deliberately. See
  # `BrandingIconController`'s moduledoc: a PWA icon is fetched by the OS at
  # install time with no session and no cookie, and every other byte route's
  # gate answers that fetcher with a 401/redirect that shows up as a blank
  # glyph on a home screen with nothing logged.
  #
  # `:accepts ["html", "json"]` copies `:agent_avatar` rather than naming an
  # image type: browsers send `Accept: image/avif,…,*/*` for an <img>, and
  # naming an image type here would break the very requests this serves.
  pipeline :public_branding do
    plug(:accepts, ["html", "json"])
  end

  # HOST-AGNOSTIC and UNAUTHENTICATED, both deliberate: icon URLs are minted
  # RELATIVE into the <head> of pages served from the app, `chat.` and `meet.`
  # hosts alike (so `:require_app_surface` would 404 two of the three once
  # `:host_surface_enforcement` is on), and the OS installer that fetches them
  # carries no session to authenticate with. The version segment is a content
  # hash, which is what lets the controller cache these immutably.
  scope "/", PlatformWeb do
    pipe_through(:public_branding)

    # BEFORE the versioned route: a stable alias for callers that cannot be
    # re-rendered on upload (sw.js). Redirects, so the versioned url keeps
    # its immutable cache.
    get("/branding/current/:variant", BrandingIconController, :current)

    get("/branding/:version/:variant", BrandingIconController, :show)

    # The PWA manifest (stage 5). HOST-AGNOSTIC because `Plug.Static` served
    # `/manifest.json` on the app, `chat.` and `meet.` hosts alike and
    # app-fencing it would silently break install on the external surfaces;
    # UNAUTHENTICATED because the OS fetches it with no session, exactly as
    # it fetches the icons above.
    get("/manifest.json", ManifestController, :show)

    # The document-root favicon probe (stage 6). Clients request
    # `/favicon.ico` REGARDLESS of markup, so it must follow the upload like
    # the other six variants; a 302 to `Branding.icon_url(:favicon_ico)`
    # keeps one source of truth instead of a second knob. Host-agnostic and
    # unauthenticated for the same reasons as the two routes above.
    get("/favicon.ico", BrandingIconController, :favicon)
  end

  # Presigned upload POST — HMAC token in the URL is the only auth. No
  # session / no bearer. Body parsers are bypassed via the endpoint's
  # body-reader skip-list so the controller can stream raw bytes.
  #
  # HOST-AGNOSTIC (deliberate). The upload URL is handed to a client that
  # POSTs it back from whatever host it was issued on, including the chat
  # host. No `:require_app_surface`.
  scope "/", PlatformWeb do
    pipe_through(:api)

    post("/chat/attachments/upload/:token", ChatAttachmentUploadController, :create)
    # Resumable chunked verbs (task 01a120be). HEAD arrives here as GET:
    # the endpoint's `Plug.Head` rewrites it before the router runs.
    get("/chat/attachments/upload/:token", ChatAttachmentUploadController, :head)
    patch("/chat/attachments/upload/:token", ChatAttachmentUploadController, :append)
  end

  # Single-use vault fetch (task 01a131c5 stage 1). Same posture as the
  # presigned upload above: the token in the URL is the only auth — no
  # session, no bearer. An agent's shell curls it with `-o` to a private file
  # (`Platform.Vault.Fetch`). No `plug(:accepts, ...)`: curl's Accept header
  # is not ours to negotiate, and the controller sends a raw body.
  # HOST-AGNOSTIC: the URL is minted from `PlatformWeb.Endpoint.url/0`.
  pipeline :vault_fetch do
    plug(:put_secure_browser_headers)
  end

  scope "/", PlatformWeb do
    pipe_through(:vault_fetch)

    # `log: false`: no route-dispatch line for a secret download. The
    # endpoint's request line is suppressed for this path too
    # (`PlatformWeb.Endpoint.request_log_level/1`).
    get("/vault/fetch/:token", VaultFetchController, :show, log: false)
  end

  # Signed platform-file GET (task 01a165ec stage 1). Same posture as the
  # vault fetch above: the `Platform.Files.SignedUrl` token in the URL is the
  # only auth. An outside service (a publishing vendor fetching a video)
  # carries no session, so NO `fetch_session`, NO `:require_auth`, and the
  # response never sets a cookie. No `plug(:accepts, ...)`: vendor fetchers
  # send whatever Accept they like and the controller sends raw bytes.
  # HOST-AGNOSTIC: the URL is minted absolute from `PlatformWeb.Endpoint.url/0`
  # and fetched by a third-party server. Declared ABOVE the authenticated
  # scopes so no `/files/...` route there can shadow it.
  pipeline :signed_file do
    plug(:put_secure_browser_headers)
  end

  scope "/", PlatformWeb do
    pipe_through(:signed_file)

    get("/files/signed/:token", FileSignedController, :show)
  end

  # Calendar feed pipeline (task 019fb955-b702 stage 3) — same posture as
  # the presigned upload above: the HMAC token in the URL is the only auth.
  # No session, no bearer, no `:require_auth`, no `ExternalUserScope`,
  # because Google / Apple / Outlook fetch a subscribed .ics from THEIR
  # servers and carry none of our cookies.
  #
  # Deliberately NO `plug(:accepts, ...)`. Those same fetchers send
  # inconsistent Accept headers — `text/calendar`, `*/*`, sometimes none at
  # all — and an allowlist turns that into a 406 that never reproduces in a
  # browser, where the Accept header always looks fine. The controller
  # sends a raw response with an explicit content type, so there is no
  # format negotiation to drive anyway.
  pipeline :calendar_feed do
    plug(:put_secure_browser_headers)
  end

  # Declared BEFORE the authenticated `scope "/"` below. The path is three
  # segments so it cannot collide with `live("/meetings/:slug", ...)`, but
  # the ordering is what keeps it out of reach of the authenticated
  # scope's plugs regardless of what routes are added there later.
  # HOST-AGNOSTIC (deliberate — task 019fcf22 stage 3). Google / Apple /
  # Outlook fetch a SUBSCRIBED feed from their own servers against the
  # absolute URL the user copied. That URL is minted RELATIVE (see
  # `Platform.Meetings` and `components/meetings/meeting_detail.ex`) and
  # resolved against whatever host the user happened to be on, so a feed
  # copied from a chat- or meet-prefixed host would die under a fence — and
  # would die silently, months later, in a calendar client nobody is looking
  # at. No `:require_app_surface`.
  scope "/", PlatformWeb do
    pipe_through(:calendar_feed)

    get("/meetings/:id/invite.ics", MeetingCalendarController, :show)
    get("/calendar/feed/:token", CalendarFeedController, :show, log: false)
  end

  # HOST-AGNOSTIC (deliberate — task 019fcf22 stage 3), and the most
  # dangerous entry on the list:
  #
  #   * `/auth/oidc/callback` — THE ONE THAT MUST NOT BE FENCED. External
  #     sign-in BEGINS on the chat host, and the redirect URI registered at
  #     the IdP is a fixed absolute URL. Fencing this route breaks production
  #     login with an error that reads like an IdP misconfiguration, which is
  #     the most expensive possible way to be wrong here.
  #   * `/health` — uptime probes hit whatever host the load balancer aims
  #     them at.
  #   * `/auth/login`, `/auth/logout` — same flow as the callback.
  #   * `/org-context[/*file_key]` — 301s for retired bookmarks; the new path
  #     applies its own gate, so redirecting is safe on any host.
  #
  # Also note this scope is UNAUTHENTICATED. Adding `:require_app_surface`
  # here is the mutation stage 3 ran to prove the fence bites; it must stay
  # off. No `:require_app_surface`.
  scope "/", PlatformWeb do
    pipe_through(:browser)

    get("/health", HealthController, :index)
    get("/auth/login", AuthController, :login)
    get("/auth/oidc/callback", AuthController, :callback)
    get("/auth/logout", AuthController, :logout)

    # Native app (task 01a10882): redeems a one-time handoff code minted by
    # `POST /api/app/session` and writes the same session key the callback
    # writes, signing the app's web view in without sharing cookies across
    # processes. Unfenced for the same reason as the rest of `/auth/*`.
    #
    # The code rides the QUERY STRING, not a path segment: Phoenix logs every
    # request path at :info, while params are logged only through
    # `:filter_parameters`, which filters "code". A path segment would put a
    # live login code in the production log.
    get("/auth/app/handoff", AuthController, :app_handoff)

    # One-click install hand-over (task 01a10315 stage 6): the new install's
    # sign-in link. Starts OIDC here and hands pocket-id's one-time code to
    # pocket-id, so the owner lands back in Burrow at /setup/connect-ai.
    # The code rides the query string for the same log-filter reason.
    get("/auth/handover", AuthController, :handover)

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

    # HOST-AGNOSTIC (deliberate). Dev-only — the `Mix.env() == :dev` guard
    # prevents route registration in prod entirely, so there is no surface to
    # fence. No `:require_app_surface`.
    scope "/dev", PlatformWeb do
      pipe_through(:dev_session_json)

      post("/meeting_evidence/join", DevMeetingEvidenceController, :join)
      post("/meeting_evidence/leave", DevMeetingEvidenceController, :leave)

      # Dev stand-in agent host (task 01a10315 stage 4, BURROW_FAKE_AGENT_HOST=1):
      # POST /dev/fake-agent-host/<agent_id>/complete finishes a fake Codex login.
      forward("/fake-agent-host", Dev.FakeAgentHost)
    end
  end

  # ── External-chat host scope (rbac-external-users M4, task 019f8837) ──
  #
  # INERT / DARK scaffold. Mirrors the `meet.` guest scope structurally
  # (see the `meet.` scope near the bottom of this file) but for the
  # authenticated external-chat surface. Phoenix matches on `conn.host`
  # starting with `chat.`, so the chat host (prod),
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
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.ModuleGate, :default}
      ],
      layout: {PlatformWeb.Layouts, :external},
      session: %{"chat_mode" => "external"} do
      live("/access/view-as/role/:id/:key", AccessViewAsLive, :show)
      live("/access/view-as/:type/:id", AccessViewAsLive, :show)
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
    end

    # ROOT LANDING for the chat host. An external user handed the bare
    # hostname types it with no path, and without this route `/` fell
    # through to the match-any-host default `scope "/"` below — whose
    # pipeline ends in `:require_app_surface`, so `HostSurface` saw a
    # non-`:app` surface and rendered the uniform 404. Signing in first
    # made no difference: the fence runs after auth. Declared HERE, inside
    # the host scope, so it inherits this scope's pipeline (no
    # `:require_app_surface`) rather than widening the app fence.
    #
    # `PageController.home/2` is the SAME action the default host's root
    # uses and is already exactly `redirect(to: ~p"/chat")`, which is the
    # wanted destination on this host too — hence reused, not reimplemented.
    # Outside the live_session on purpose: it is a controller redirect.
    #
    # NOTE: the sibling `meet.` scope below HAD the identical gap and now
    # closes it the same way — `get("/", PageController, :meet_home)`,
    # redirecting to `/meetings`. The justification once recorded here for
    # deferring it ("its routes all require a slug, so there is no obvious
    # landing target") DIED when task 019ffbb3 added the slugless
    # `live("/meetings", MeetingLive, :index)`: a landing target exists.
    # Nobody re-examined the deferral when the fact under it changed.
    get("/", PageController, :home)
  end

  # Invited-member meeting surface on the `meet.` host (task 019fb955-f8b1
  # stage 5). An account-holding external user who holds a live invite row
  # opens the meeting room here; the token-bearing GUEST surface stays at
  # the `/:slug/:token` scope near the bottom of this file.
  #
  # ── (a) PLACEMENT, characterized before the change, not assumed.
  # `Phoenix.Router.route_info(Router, "GET", "/meetings/some-slug", <host>)`
  # on the unmodified router answered `MeetingLive` in the `:authenticated`
  # live_session for EVERY host tried — `localhost`, `meet.localhost` and
  # `meet.example.com` alike. Phoenix emits one `__match_route__/3` clause
  # per route in definition order and the first match wins; the default
  # `scope "/"` below declares `/meetings/:slug` with a match-any-host
  # pattern, so a `meet.`-hosted copy appended NEXT TO the guest scope at
  # the bottom of this file would be unreachable dead code. Hence this
  # scope sits above the default scope, exactly like the `chat.` scope and
  # for exactly the reason its own note gives.
  #
  # ── (b) PIPELINE: `[:browser, :require_auth, :enforce_external_scope]`,
  # NOT `:guest_browser`. An external member is an authenticated OIDC
  # account, not an anonymous guest, so it needs the real session and
  # `:require_auth`; and `:enforce_external_scope` is the plug that carries
  # the invite-row gate (`ExternalUserScope` -> `Meetings.invited_to_slug?/2`).
  # Routing here without that pipeline would put the room behind no gate.
  #
  # ── (c) TWO DIFFERENT HOST MECHANISMS NOW EXIST AND MUST NOT BE
  # CONFLATED. This scope matches Phoenix's `"meet."` PREFIX and decides
  # WHICH LIVE_SESSION RENDERS. `PlatformWeb.ExternalSurface` matches the
  # CONFIGURED `:meet_host` EXACTLY and decides WHETHER AN EXTERNAL USER IS
  # ADMITTED. They are not the same test and they do not answer the same
  # question. A `meet.`-prefixed host that is not the configured meet host
  # routes HERE and is then denied by the plug — fail-closed, and the
  # pairing `router_meet_member_host_test.exs` pins.
  #
  # ── (d) CONSEQUENCE FOR INTERNAL USERS: on a `meet.`-prefixed host an
  # internal user now gets the chrome-less member surface instead of the
  # shell. Intended under the sponsor's "chat is chat only, meet is meet
  # only" — it is a RENDERING change, not an authorization one. Internal
  # users remain a complete no-op through `ExternalUserScope` on every
  # host, and `/meetings/:slug` on the default host is untouched.
  #
  # ── (e) THE GUEST ROUTE AND THIS ROUTE COLLIDE ON A SHARED HOST.
  # The deployment that motivated this stage points the guest host and the
  # meet host at the SAME hostname, so both scopes are live on one host and
  # both patterns are two segments: `/meetings/:slug` here and
  # `/:slug/:token` in the guest scope. First-declared wins, so on that
  # shared host `/meetings/<x>` resolves HERE. The edge case that buys:
  # a meeting whose slug is literally "meetings" has guest links of the
  # form `/meetings/<token>`, and those do not reach the guest scope.
  # NOTE this is NOT a regression introduced here — the default scope's
  # `/meetings/:slug` already shadowed them from above, as the
  # characterization above shows. Placing this scope higher keeps the
  # status quo for that slug rather than changing it. If that slug ever
  # needs to work, the fix is a guest-route prefix, not a reordering:
  # reordering would make every member URL resolve to the guest route with
  # `slug: "meetings"`, silently deleting this whole surface. The
  # shared-host case is pinned by a test that gives BOTH routes the same
  # host string, because a test using two different fixture hosts cannot
  # detect that class of bug.
  scope "/", PlatformWeb, host: "meet." do
    pipe_through([:browser, :require_auth, :enforce_external_scope])

    live_session :meet_member,
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :guest},
      session: %{"chrome_mode" => "none"} do
      # The INDEX (019f9cb7). `ExternalUserScope` admits an external user to
      # `["meetings"]` on the `:meet` surface, but until this line existed
      # `/meetings` was declared ONLY in the app-host scope below, and
      # `HostSurface` 404s an app-scope route reached on a `meet.` host. So
      # the admission clause was unreachable over HTTP: 403 on the app host,
      # 404 here. Route omission is not surface limitation. One segment, so
      # it does not compete with the two-segment guest route.
      #
      # The meet-host ROOT is now declared too — see the `get("/", ...)`
      # below, OUTSIDE this live_session.
      #
      # Declared INSIDE `:meet_member` rather than in a live_session of its
      # own so index → room is a LIVE PATCH instead of a full page reload,
      # and so it inherits the `:guest` layout and `chrome_mode: "none"` —
      # an external user gets no app-shell nav. A second live_session using
      # the `:external` layout was considered and rejected: it forces a
      # reload on every index→room click and duplicates the on_mount list.
      #
      # ONE route covers index, calendar week AND archive: the archive is
      # `?view=archive`, a query param on this same path, so `path_info`
      # stays `["meetings"]`. Do not add a second route for it.
      #
      # Paired with the `{:meet, ["meetings"]} -> conn` admission clause in
      # `ExternalUserScope`; without the route that clause 404s here, which
      # is the bug this closes.
      live("/meetings", MeetingLive, :index)
      live("/meetings/:slug", MeetingLive, :show)
    end

    # ROOT LANDING for the meet host (task 019ffe8a stage 2). A member
    # handed the bare hostname types it with no path; before this route `/`
    # fell through to the match-any-host default `scope "/"` below — whose
    # pipeline ends in `:require_app_surface`, so `HostSurface` saw a
    # non-`:app` surface and rendered the uniform 404. Declared HERE, inside
    # the host scope, so it inherits THIS scope's pipeline rather than
    # widening the app fence. Mirrors the `chat.` root above exactly.
    #
    # A REDIRECT to `/meetings`, not a second render of the index at `/`.
    # Rendering here would put two routes for one view inside
    # `:meet_member` that must be kept identical forever, and would leave
    # `MeetingLive`'s `:index` action bound to two paths — making
    # `handle_params/3`, the `?view=archive` branch and every `~p"/meetings"`
    # patch target ambiguous. Cost is one round trip per bare-domain visit.
    #
    # Outside the live_session on purpose: it is a controller redirect.
    #
    # DEPENDS ON `{:meet, []} -> conn` in `PlatformWeb.Plugs.ExternalUserScope`
    # (stage 1). A root request has `path_info == []`, which without that
    # clause hits the terminal `{:meet, _}` deny — so this route alone would
    # convert the 404 into a 403, the same dead end with a different number.
    # If this root ever starts 403ing, that clause is what to look at; a 404
    # means this route went missing instead.
    #
    # KNOWN GAP, named deliberately and NOT fixed here (task 019ffe8a stage
    # 3). This root serves an ALREADY-SIGNED-IN member. An ANONYMOUS visitor
    # is bounced by `:require_auth` to the host-relative `/auth/login`, which
    # is reachable on this host (it lives in the unauthenticated match-any-
    # host scope, deliberately without `:require_app_surface`) — so the
    # redirect is not a dead end. But `PlatformWeb.AuthController.callback/2`
    # sends an external full user to `ExternalRedirect.chat_url("/chat")`, an
    # ABSOLUTE chat-host URL, whenever `CHAT_HOST` is configured (task
    # 019f9257) — the OIDC redirect URI is a fixed absolute value registered
    # with the IdP and cannot round-trip the originating host. CONSEQUENCE: a
    # member who signs in FROM this host completes login on the CHAT host,
    # not back at `/meetings`. Carrying an origin host through OIDC state has
    # its own security surface (open redirect via an attacker-supplied return
    # host) and deserves its own ticket.
    get("/", PageController, :meet_home)
  end

  # Guest meeting ingress (task 019f2483 stage 3, consolidated onto
  # MeetingLive in task 019f498d stage 5). Bound to the dedicated
  # `meet.` host prefix — Phoenix matches on `conn.host` starting with
  # this string, so the prod meet host, `meet.localhost` (dev with
  # `/etc/hosts`), and `meet.<any>.<tld>` all route here while
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
  #
  # ── PLACEMENT IS LOAD-BEARING AND HAS EXACTLY ONE CORRECT SLOT.
  # Phoenix emits one `__match_route__/3` clause per route in DEFINITION
  # order and the first match wins. `host:` narrows a clause, it does not
  # reorder anything — so a two-segment match-any-host route declared
  # EARLIER beats this one even on a `meet.` host.
  #
  # This block previously sat at the very bottom of the router, below the
  # default `scope "/"`. Measured with
  # `Phoenix.Router.route_info(PlatformWeb.Router, "GET", path,
  # "meet.example.com")` on that arrangement, every one of these swallowed
  # a guest link whose meeting slug matched the first segment:
  # `/chat/:space_slug`, `/tasks/:task_id`, `/files/:project_id`,
  # `/skills/:slug`, `/meetings/:slug`, `/control/:agent_slug`,
  # `/canvases/:id`, `/admin/{recovery,users,prompts,federation}`,
  # `/memory/proposals` (now also `/memory/insights`), `/org_memory/*file_key`. Guest invite URLs are
  # minted ABSOLUTE, stored, and emailed (`Platform.Meetings`), so those
  # were dead links against invites already in people's inboxes — not a
  # hypothetical. Hence: above the default scope.
  #
  # But NOT above the `meet.` MEMBER scope directly overhead. That scope
  # declares `/meetings/:slug`, which is also two segments; hoisting this
  # block over it would make every member URL match `/:slug/:token` with
  # `slug: "meetings"` and silently delete the member surface. The trade
  # is spelled out in (e) above and is unchanged by this move: a meeting
  # slugged literally "meetings" still cannot be reached by guest link,
  # and the fix for that would be a guest-route prefix, never a reorder.
  # Both directions are pinned in
  # `test/platform_web/router_meet_guest_placement_test.exs`.
  scope "/", PlatformWeb, host: "meet." do
    pipe_through(:guest_browser)

    live_session :guest_meeting,
      layout: {PlatformWeb.Layouts, :guest},
      session: %{"chrome_mode" => "none"} do
      live("/:slug/:token", MeetingLive, :show)
    end
  end

  # ADR-0042 stage 5: inline preview for FilesLive (images / PDFs / text).
  # Same `:require_auth` gate as the /files LV routes — the controller does
  # the per-file org-membership check.
  #
  # DECISION OF RECORD (task 01a09415): this route sits in its own scope
  # solely so it can pipe through `:blob_browser` instead of `:browser`,
  # making Accept-based API-client classification reachable by
  # `PlatformWeb.Plugs.RequireAuth` on this route and no other. It stays
  # app-fenced: `:require_app_surface` LAST, `:enforce_external_scope`
  # after `:require_auth`, exactly as in the fenced scope below. This is a
  # content-negotiation change only.
  scope "/", PlatformWeb do
    pipe_through([:blob_browser, :require_auth, :enforce_external_scope, :require_app_surface])

    get("/files/blob/:id", FileBlobController, :show)
  end

  # Prototype bundles (task 01a1316b-4e46 stage 1, ADR 0057 Decision 1). Two
  # app-fenced scopes, both `:require_app_surface` LAST.
  #
  # The GRANT route carries no session by construction (requests from an
  # opaque-origin frame are cross-site for SameSite=Lax), so it does NOT pipe
  # through `:require_auth`: the controller verifies the grant in the path and
  # re-checks org membership for the grant's user on every request. It is
  # declared ABOVE the entry route, which would otherwise match it as a path.
  scope "/", PlatformWeb do
    pipe_through([:proto_browser, :require_app_surface])

    get("/proto/:id/:version/g/:grant/*path", PrototypeController, :serve)
  end

  # Entry and latest: navigations a Burrow page starts, so the session is sent.
  # `latest` is declared above `:version` so it is not parsed as a number.
  scope "/", PlatformWeb do
    pipe_through([:proto_browser, :require_auth, :enforce_external_scope, :require_app_surface])

    get("/proto/:id/latest/*path", PrototypeController, :latest)
    get("/proto/:id/:version/*path", PrototypeController, :entry)
  end

  # THE FENCED SCOPE. `:require_app_surface` is LAST in the pipeline on
  # purpose: an unauthenticated request must still redirect to login (via
  # `:require_auth`) rather than 404, which keeps existing auth behaviour on
  # the app host exactly as it was.
  #
  # Every route in the router is now one of three things — app-fenced (this
  # scope), host-scoped (`chat.` / `meet.`), or on the documented
  # host-agnostic list. Adding a route means picking one.
  pipeline :booking_rate_limit do
    plug(PlatformWeb.BookingRateLimitPlug)
  end

  # Public booking is intentionally app-host fenced, without account authentication.
  # The opaque token reveals available slots only; no owner event details.
  scope "/", PlatformWeb do
    pipe_through([:browser, :require_app_surface, :booking_rate_limit])

    live_session :public_booking, layout: false do
      live("/book/:token", PublicBookingLive, :show, metadata: %{log: false})
    end
  end

  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth, :enforce_external_scope, :require_app_surface])

    # Root redirects to /chat
    get("/", PageController, :home)
    get("/access-denied", AccessDeniedController, :show)
    get("/admin/pipeline", LegacyPipelineController, :show)

    get("/artifacts/preview", ArtifactPreviewController, :show)
    get("/api/transcripts/:id/download", TranscriptController, :show)

    live_session :authenticated,
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.ModuleGate, :default}
      ],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/access/view-as/role/:id/:key", AccessViewAsLive, :show)
      live("/access/view-as/:type/:id", AccessViewAsLive, :show)
      live("/access", AccessLive, :index)
      live("/access/:type/:id", AccessLive, :show)
      live("/chat", ChatLive, :index)
      live("/chat/:space_slug", ChatLive, :show)
      live("/inbox", InboxLive, :index)
      # The day's briefing, opened from its Inbox row (task 01a15ee1 stage 4).
      live("/inbox/briefing/:date", InboxLive, :briefing)
      live("/inbox/meeting/:meeting_id", InboxLive, :meeting_briefing)
      live("/tasks", TasksLive, :index)
      # Keep the static module-admin route above the task-id catch-all.
      live("/tasks/pipeline", PipelineLive, :index)
      live("/tasks/:task_id", TasksLive, :show)
      # ADR-0042 stage 5: project-scoped document store
      live("/files", FilesLive, :index)
      live("/files/:project_id", FilesLive, :show)
      live("/meetings", MeetingLive, :index)
      live("/meetings/:slug", MeetingLive, :show)
      # The Voice tab (task 01a1557a-eab7 stage 2).
      live("/voice", VoiceLive, :index)
      # Task 01a0cf21 stage 4: the Email module. Routes are compile-time, so
      # `EmailLive.mount/3` 404s when `Platform.Mail.Config.enabled?/0` is
      # false or the viewer has no non-external membership. `/email/accounts/new`
      # must stay above `/email/accounts/:id`.
      live("/email", EmailLive, :index)
      live("/email/messages/:id", EmailLive, :message)
      # `/email/drafts/new` must stay above `/email/drafts/:id`.
      live("/email/drafts/new", EmailLive, :new_draft)
      live("/email/drafts/:id", EmailLive, :draft)
      live("/email/accounts", EmailLive, :accounts)
      live("/email/accounts/new", EmailLive, :new_account)
      live("/email/accounts/:id", EmailLive, :account)
      live("/calendar", CalendarLive, :index)
      live("/calendar/booking", BookingSettingsLive, :index)
      live("/skills", SkillsLive, :index)
      live("/skills/:slug", SkillsLive, :show)
      live("/changelog", ChangelogLive, :index)
      # Task 01a1557a-807f stage 1: the viewer's own account (profile, theme,
      # links to Usage / Admin / Prompts, sign out). Ungated in ModuleGate;
      # each row checks its own destination.
      live("/settings", SettingsLive, :index)
      # Prompts is a module-admin view. It retains its stable URL and rail
      # destination, but belongs to this module-gated session instead of the
      # install-admin session.
      live("/admin/prompts", AdminPromptsLive, :index)
      live("/admin/prompts/:slug", AdminPromptsLive, :edit)
      live("/control", ControlCenterLive, :index)
      live("/control/usage", UsageLive, :index)
      # Task 019fe6ba, ADR-0048. `/control/:agent_slug` below is a catch-all:
      # these MUST stay above it or `/control/experiments` resolves as an
      # agent slug and 404s on a missing agent. `experiments_live_test.exs`
      # covers the ordering.
      #
      # These sit in `:authenticated`, not `:admin`: reads are
      # member-visible on purpose. Writes are gated inside every
      # `handle_event` in `ExperimentsLive` instead, because neither
      # live_session expresses "anyone may read, admins may write".
      live("/control/experiments", ExperimentsLive, :index)
      live("/control/experiments/:slug", ExperimentsLive, :show)
      live("/control/:agent_slug", ControlCenterLive, :show)
      # Task 01a17b1c stage 5: the agent's configuration files and session strip.
      live("/control/:agent_slug/config", AgentConfigLive, :show)
      # Task 01a17b17 stage 3: the owner's remote terminal. Keyed by runtime id
      # so a direct URL for someone else's runtime reaches the same refusal
      # core's channel gives.
      live("/terminal/:runtime_id", TerminalLive, :show)
      live("/org_memory", OrgMemoryLive, :index)
      # Task 01a13867 stage 5 — direct entry to the Insights tab (renamed
      # from Proposals). `live_action == :insights` mounts the same
      # OrgMemoryLive and `handle_params/3` loads the tab before first render.
      live("/memory/insights", OrgMemoryLive, :insights)
      # The retired Proposals tab's address (task 019f70e9 stage 4). Old
      # journals and notifications link here, so `handle_params/3`
      # redirects it to `/memory/insights` rather than 404ing.
      live("/memory/proposals", OrgMemoryLive, :proposals)
      # Glob route: path-style file_keys (`org/identity.md`) span multiple
      # segments, so `:show` must match `/org_memory/*file_key`.
      live("/org_memory/*file_key", OrgMemoryLive, :show)
      # A build-time module's LiveView page (`Platform.Extension.live_pages/0`),
      # looked up per request: an unclaimed prefix or an external user is a 404.
      live("/m/:prefix", ExtensionPageLive, :show)
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
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.ModuleGate, :default}
      ],
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

    # ModuleGate runs after LiveAuth on every admin mount. The holding session
    # above deliberately has no module gate: its zero-membership users have
    # a dedicated landing. The meet sessions and unauthenticated guest meeting
    # session keep their invite admission and query fences instead.
    live_session :admin,
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.ModuleGate, :default}
      ],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/admin", AdminLive, :index)
      live("/admin/recovery", RecoveryLive, :index)
      # rbac-external-users M3 stage 4 (task 019f8837): the root-admin
      # recovery queue for external logins awaiting setup. Inherits the
      # `:ensure_admin` gate + `:shell` chrome from this live_session.
      live("/admin/external-logins", ExternalRecoveryLive, :index)
      live("/admin/users", UserAccessLive, :index)
      # Task 019ffe9d stage 4: the human-reachable caller for
      # `Tenancy.create_org/2`. It is an admin list-plus-write surface of
      # exactly the same shape as `/admin/users`, so it takes the same gate
      # from this live_session rather than inventing a second one — and the
      # context function re-checks the actor itself
      # (`Lifecycle.with_root_admin_authz/2`) so neither half is load-bearing
      # alone.
      live("/admin/orgs", AdminOrgsLive, :index)
      # Task 01a0879a stage 4: this install's PWA identity (name, colours,
      # icon source). Install-wide, NOT per-org — an org is a client, and
      # one deployment serves them all the same home-screen icon. Takes the
      # `:ensure_admin` gate from this live_session for the same reason
      # `/admin/orgs` does, and `Platform.Branding` re-checks the actor on
      # both writes.
      live("/admin/branding", AdminBrandingLive, :index)
      # Task 01a1557a-fe9b stage 2: the org theme editor. Full-bleed: the view
      # mounts with the chrome-less `:holding` layout, overriding `:shell`.
      # `Platform.Theming` re-checks root admin on every write.
      live("/admin/themes", AdminThemesLive, :index)
      # Task 01a1316b-4e46 stage 2: prototype publishing switch and caps,
      # install-wide for the same reason as branding. `Settings.update/2`
      # re-checks root admin on the write.
      live("/admin/prototypes", AdminPrototypesLive, :index)
      # Task 01a13867 stage 5: whether dreaming insights leave the Insights
      # tab (dissemination), install-wide for the same reason as prototypes.
      # `Platform.Memory.Insights.Settings.update/2` re-checks root admin.
      live("/admin/insights", AdminInsightsLive, :index)
      # Task 01a131c5 stage 2: shared secrets an admin grants to agents.
      # `Platform.Vault.Shared` re-checks the actor on every call, so this
      # live_session's gate is not load-bearing alone.
      live("/admin/vault", AdminVaultLive, :index)
      live("/admin/vault/:slug", AdminVaultLive, :show)
      # Task 01a10315 stage 5: "Connect your AI", where a new install's
      # hand-over lands ("Open Burrow"). The view re-checks root admin.
      live("/setup/connect-ai", ConnectAiLive, :index)
      live("/admin/federation", AdminFederationLive, :index)
    end
  end

  # Task 01a113ea stage 3: the native sign-in users page, which manages the
  # install's bundled pocket-id users. Its own scope because the gate plug
  # runs BEFORE `:require_auth`: with `POCKET_ID_ADMIN_ENABLED` off, every
  # caller (admin, non-admin, signed out) gets 404, never a login redirect
  # that would reveal the page exists. The rest of the pipeline is the fenced
  # scope's, in the same order. Its own `live_session` too, because a
  # `live_session` belongs to one scope; the `on_mount` list and layout are
  # the `:admin` session's, so `:ensure_admin` still refuses a non-admin.
  # `/admin/users` stays `UserAccessLive`, unchanged.
  pipeline :require_sign_in_admin do
    plug(PlatformWeb.Plugs.RequireSignInAdmin)
  end

  scope "/", PlatformWeb do
    pipe_through([
      :browser,
      :require_sign_in_admin,
      :require_auth,
      :enforce_external_scope,
      :require_app_surface
    ])

    live_session :admin_sign_in,
      on_mount: [
        PlatformWeb.ShellLive,
        {PlatformWeb.LiveAuth, :default},
        {PlatformWeb.ModuleGate, :default}
      ],
      layout: {PlatformWeb.Layouts, :shell} do
      live("/admin/sign-in-users", AdminSignInUsersLive, :index)
    end
  end

  # ── HOST-AGNOSTIC MACHINE-CALLER SCOPES (deliberate — task 019fcf22
  # stage 3). Everything from here to the end of the file is called by
  # software, not a browser, and authenticates on a bearer token, a session
  # cookie, or a request signature — never on a host. Two of them cannot be
  # re-pointed by us at all: LiveKit and GitHub each POST to a URL configured
  # in THEIR console, verified by `VerifyLivekitSignature` /
  # `VerifyGithubSignature`. Fencing those would drop webhooks with no
  # client-side error anyone here would see. None get `:require_app_surface`.
  # Install-to-install federation descriptor (task 01a0d90f stage 2, ADR
  # 0054). HOST-AGNOSTIC and UNAUTHENTICATED, both deliberate: it is fetched
  # by PEER INSTALLS, from arbitrary hosts, against whatever base URL an admin
  # typed, and a peer carries no session. `:require_app_surface` would 404 it
  # on a chat- or meet-prefixed base URL. The body is public keys only, and
  # the controller answers 404 while `PEER_FEDERATION_ENABLED` is off.
  scope "/.well-known", PlatformWeb do
    pipe_through(:api)
    get("/suite-federation", FederationWellKnownController, :show)
    # Same descriptor under the renamed protocol (task 01a14ba9 stage 1). The
    # suite path stays: peers running older core fetch only that one.
    get("/burrow-federation", FederationWellKnownController, :show)
  end

  # Install-to-install federation inbox (task 01a0d90f stage 3, ADR 0054).
  # HOST-AGNOSTIC and SESSIONLESS for the same reason as the descriptor
  # above: peer installs POST here from arbitrary hosts, against the base URL
  # an admin typed, and carry no session. Every request authenticates on its
  # own Ed25519 envelope signature (`:peer_envelope`), and answers 404 while
  # `PEER_FEDERATION_ENABLED` is off.
  scope "/federation/v1", PlatformWeb do
    pipe_through(:peer_envelope)
    post("/inbox", FederationInboxController, :create)
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

  # Native app API (task 01a10882). HOST-AGNOSTIC like every other `/api/*`
  # machine caller. `POST /session` is the one unauthenticated route: it
  # redeems a PKCE-bound exchange code for a bearer token.
  scope "/api/push-relay/v1", PlatformWeb do
    pipe_through(:push_relay)

    # `log: false`: Phoenix's request log prints parameters, and nothing an
    # install sends may reach the relay's log.
    post("/notifications", PushRelayController, :create, log: false)
  end

  scope "/api/app", PlatformWeb do
    pipe_through(:api)

    post("/session", AppApiController, :create_session)
    # Unauthenticated install descriptor for the Burrow desktop app (task 01a14d12).
    get("/install", AppApiController, :install)
  end

  scope "/api/app", PlatformWeb do
    pipe_through(:app_api)

    delete("/session", AppApiController, :delete_session)
    post("/handoff", AppApiController, :create_handoff)
    post("/devices", AppApiController, :register_device)
    delete("/devices/:app_install_id", AppApiController, :unregister_device)
    get("/spaces", AppApiController, :spaces)
    post("/spaces/:space_id/messages", AppApiController, :create_message)
    # Large-file chunked uploads (task 01a120be stage 2).
    post("/spaces/:space_id/uploads", AppApiController, :create_upload)
    get("/upload_config", AppApiController, :upload_config)
    get("/counts", AppApiController, :counts)
    # Today's briefing counts for the Android widget (task 01a161f9).
    get("/briefing", AppApiController, :briefing)

    # App Intents (task 01a10db6): Siri, Shortcuts, widgets, controls.
    get("/approvals", AppIntentsController, :approvals)
    post("/approvals/:id/approve", AppIntentsController, :approve)
    post("/approvals/:id/reject", AppIntentsController, :reject)
    get("/tasks", AppIntentsController, :tasks)
    get("/meetings", AppIntentsController, :meetings)
    post("/meetings", AppIntentsController, :create_meeting)
    # Native meetings (task 01a10db7): LiveKit join/leave and VoIP ringing.
    post("/meetings/:id/join", AppMeetingsController, :join)
    post("/meetings/:id/leave", AppMeetingsController, :leave)
    post("/voip_devices", AppMeetingsController, :register_voip_device)
    get("/rings/:id", AppMeetingsController, :ring)
    post("/rings/:id/answer", AppMeetingsController, :answer_ring)
    post("/rings/:id/decline", AppMeetingsController, :decline_ring)
    post("/rings/:id/missed", AppMeetingsController, :missed_ring)
    get("/agents", AppIntentsController, :agents)
    post("/agents/:agent_id/dm", AppIntentsController, :agent_dm)
    get("/spaces/:space_id/messages", AppIntentsController, :messages)
    # Siri AI (task 01a111bb): people directory, projects, Create Task.
    get("/people", AppIntentsController, :people)
    post("/people/:user_id/dm", AppIntentsController, :person_dm)
    get("/projects", AppIntentsController, :projects)
    post("/tasks", AppIntentsController, :create_task)
    # Siri AI messages domain (task 01a111bb stage 2): edit, unsend, read.
    patch("/messages/:id", AppMessagesController, :update)
    delete("/messages/:id", AppMessagesController, :delete)
    post("/spaces/:space_id/read", AppMessagesController, :read)
  end

  scope "/api/meetings", PlatformWeb do
    pipe_through(:api)
    post("/segments", MeetingAgentController, :segments)
  end

  scope "/api/webhooks", PlatformWeb do
    pipe_through(:github_webhook)
    # `log: false` (task 01a11ec3 stage 3): Phoenix's route-dispatch log line
    # prints the full `Parameters:` map, and an `issues` delivery's params ARE
    # the external issue's title and body — untrusted text that must never
    # reach a log. The endpoint's request line (method + path) still logs.
    post("/github", GithubWebhookController, :handle, log: false)
  end

  scope "/api/webhooks", PlatformWeb do
    pipe_through(:livekit_webhook)
    post("/livekit", LivekitWebhookController, :handle)
  end

  scope "/api/ext" do
    pipe_through(:extension_api)
    # `log: false`: an extension's params (a vendor webhook body) are
    # untrusted and must never reach a log, as with GitHub's above.
    forward("/", PlatformWeb.Plugs.ExtensionRoutes, [], log: false)
  end

  scope "/mcp", PlatformWeb do
    pipe_through(:mcp)
    post("/", MCPController, :handle)
    get("/", MCPController, :stream)
  end
end
