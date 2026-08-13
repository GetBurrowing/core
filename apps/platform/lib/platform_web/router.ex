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
       feed, and the `/api/*` + `/mcp` machine callers.

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
      on_mount: [PlatformWeb.ShellLive, {PlatformWeb.LiveAuth, :default}],
      layout: {PlatformWeb.Layouts, :external},
      session: %{"chat_mode" => "external"} do
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
    # NOTE: the sibling `meet.` scope below has the identical gap and is
    # deliberately NOT fixed here — its routes all require a slug, so
    # there is no obvious landing target to redirect to.
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
      # Deliberately NOT added: a `"/"` route on this scope. The meet-host
      # ROOT is a separate follow-up.
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
  # `/memory/proposals`, `/org_memory/*file_key`. Guest invite URLs are
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

  # THE FENCED SCOPE. `:require_app_surface` is LAST in the pipeline on
  # purpose: an unauthenticated request must still redirect to login (via
  # `:require_auth`) rather than 404, which keeps existing auth behaviour on
  # the app host exactly as it was.
  #
  # Every route in the router is now one of three things — app-fenced (this
  # scope), host-scoped (`chat.` / `meet.`), or on the documented
  # host-agnostic list. Adding a route means picking one.
  scope "/", PlatformWeb do
    pipe_through([:browser, :require_auth, :enforce_external_scope, :require_app_surface])

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
      # Task 019fed1e: pipeline health MOVED here from `/control/pipeline`.
      # It is a read-only whole-page admin surface with no write handlers,
      # so `:ensure_admin` on this live_session is the right gate — a
      # page-local check under `/control` would invent a second pattern for
      # a case this one already covers. Reached from the Tasks header cog;
      # no redirect from the old path, which now falls to the
      # `/control/:agent_slug` catch-all as a URL that should not be typed.
      live("/admin/pipeline", PipelineLive, :index)
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
end
