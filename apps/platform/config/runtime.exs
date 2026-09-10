import Config

# Ensure Erlang's :ssl uses CAStore for outbound HTTPS (web push, etc.)
# hackney (used by WebPushEncryption/HTTPoison) needs cacertfile explicitly
Application.ensure_all_started(:castore)
:public_key.cacerts_load(CAStore.file_path())

config :ssl, [
  {:verify, :verify_peer},
  {:cacertfile, CAStore.file_path() |> to_charlist()},
  {:depth, 3}
]

if System.get_env("PHX_SERVER") do
  config :platform, PlatformWeb.Endpoint, server: true
end

# ── Session cookie domain (cross-subdomain OIDC login fix) ────────────────────
# The `_platform_session` cookie is host-only by default (no `Domain`), so a
# login started on `chat.example.com` loses its OIDC `state` cookie when
# Pocket-ID redirects the callback to `suite.example.com` → "Invalid
# OIDC state". Setting SESSION_COOKIE_DOMAIN=.example.com shares the
# cookie across every `*.example.com` host so the state survives the
# cross-host redirect. `SameSite=Lax` is intentionally retained — it is correct
# for the top-level GET navigation redirect back from Pocket-ID.
#
# Only the prod container sets this var; dev, test, CI, and localhost leave it
# unset, so no key is written and the cookie stays host-only (unchanged).
# Tradeoff: a domain-wide cookie reaches every `*.example.com` subdomain
# — already the accepted pattern here (oauth2-proxy runs
# OAUTH2_PROXY_COOKIE_DOMAINS=.example.com).
case System.get_env("SESSION_COOKIE_DOMAIN") do
  domain when is_binary(domain) and domain != "" ->
    config :platform, :session_cookie_domain, domain

  _ ->
    :ok
end

# ── Root org slug (per-install root/default org) ──────────────────────────────
# `Platform.Tenancy.root_org_slug/0` reads this key at runtime. config.exs
# defaults it to "fabrikam"; an install whose root org carries a different slug
# sets ROOT_ORG_SLUG so org_id-less writes, the derived-role hook, and the
# admin promote/revoke helpers all resolve the org that actually exists there.
#
# Written only when the var is present and non-blank, so dev, test and CI keep
# the config.exs default and per-test `Application.put_env/3` overrides are the
# only thing that moves it.
case System.get_env("ROOT_ORG_SLUG") do
  slug when is_binary(slug) and slug != "" ->
    config :platform, :root_org_slug, slug

  _ ->
    :ok
end

# ── Auto-admin email domain (per-install) ────────────────────────────────────
# `Platform.Tenancy.admin_email_domain/0` reads this key at runtime and
# `derive_role_from_email/1` uses it on every user INSERT and every
# email-change UPDATE. config.exs defaults it to "example.com".
#
# The branch shape here deliberately differs from SESSION_COOKIE_DOMAIN and
# ROOT_ORG_SLUG above, which both skip a blank value. Here a blank value is
# MEANINGFUL: ADMIN_EMAIL_DOMAIN="" disables auto-admin entirely, and must NOT
# fall back to the config.exs default. An install that does not want Fabrikam
# addresses auto-promoted on its database has to be able to say so by setting
# the var empty, without inventing a sentinel string.
#
# Unset (nil) still means "keep the config.exs default", so dev, test and CI
# are unchanged and per-test `Application.put_env/3` overrides remain the only
# thing that moves the key there.
case System.get_env("ADMIN_EMAIL_DOMAIN") do
  nil -> :ok
  domain -> config :platform, :admin_email_domain, String.trim(domain)
end

# ── ADR corpus location (release images have no `docs/decisions/`) ────────────
# ContextProviders.adr_dir/0 resolves by walking ancestors for a literal
# `docs/decisions` directory. A release image has no such ancestor, so the
# architect's ADR index resolves `:adr_dir_unreachable` and the drift check
# reports "no architectural decisions" instead of failing. The Dockerfile
# copies the corpus to the app's `priv/`; this points the provider at it.
#
# The existence check is load-bearing, not defensive. `adr_dir/0` deliberately
# does NOT fall back when the key is set — a configured-but-missing path is an
# error, which is what makes the key provable. So an unconditional key would
# break every dev and test run, where nothing was ever copied into `priv/` and
# the ancestor walk is the correct resolution. When nothing resolves we write
# NO key at all and leave that walk (and the suite's own put_env overrides)
# exactly as they were.
packaged_adr_dir =
  try do
    if Code.ensure_loaded?(Platform.Responsibilities.ContextProviders) do
      subdir = Platform.Responsibilities.ContextProviders.adr_priv_subdir()
      Application.app_dir(:platform, Path.join("priv", subdir))
    end
  rescue
    # app_dir/2 raises when :platform is not loaded (plain `iex` reading this
    # file, tooling that evaluates config outside a release).
    ArgumentError -> nil
  end

resolved_adr_dir =
  case System.get_env("ADR_DIR") do
    dir when is_binary(dir) and dir != "" -> dir
    _ -> packaged_adr_dir
  end

if is_binary(resolved_adr_dir) and File.dir?(resolved_adr_dir) do
  config :platform, :adr_dir, resolved_adr_dir
end

vault_key =
  case {config_env(), System.get_env("VAULT_MASTER_KEY")} do
    {:prod, nil} ->
      raise "environment variable VAULT_MASTER_KEY is missing"

    {_, nil} ->
      Base.encode64(:crypto.strong_rand_bytes(32))

    {_, key} ->
      key
  end

config :platform, Platform.Vault.Encryption,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: Base.decode64!(vault_key), iv_length: 12
    }
  ]

if config_env() != :test do
  pool_size = String.to_integer(System.get_env("POOL_SIZE", "10"))

  socket_options =
    case System.get_env("ECTO_IPV6") do
      value when value in ["true", "1"] -> [:inet6]
      _ -> []
    end

  database_url =
    if config_env() == :prod do
      System.get_env("DATABASE_URL") ||
        raise "environment variable DATABASE_URL is missing"
    else
      System.get_env("DATABASE_URL")
    end

  if database_url do
    config :platform, Platform.Repo,
      url: database_url,
      pool_size: pool_size,
      socket_options: socket_options
  end

  app_url = System.get_env("APP_URL") || "http://localhost:4000"

  # Only enable when behind a trusted reverse proxy (Traefik, nginx, etc.).
  # See PlatformWeb.Plugs.RewriteRemoteIp for security notes.
  config :platform, :trust_proxy_headers, System.get_env("TRUST_PROXY_HEADERS") in ["true", "1"]

  config :platform, :oidc,
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET"),
    issuer: System.get_env("OIDC_ISSUER"),
    app_url: app_url,
    # PKCE (RFC 7636): set OIDC_PKCE_ENABLED=true when the provider enforces it.
    # Defaults to false for compatibility with providers that don't support PKCE.
    pkce_enabled: System.get_env("OIDC_PKCE_ENABLED") in ["true", "1"],
    # rbac-external-users M2 stage 1: the id-token claim NAME/value that marks
    # a login as SXI-external. Static token-claim config, not a provider API
    # call (ADR-0004). Falls back to the config.exs defaults.
    external_group: System.get_env("OIDC_EXTERNAL_GROUP") || "sxi-external",
    external_claim: System.get_env("OIDC_EXTERNAL_CLAIM") || "groups",
    # OIDC authorization scope. Must include `groups` so Pocket-ID releases the
    # external-user group claim that external_claim?/1 inspects. Nil when unset,
    # falling back to the groups-inclusive @default_scope in Platform.OIDC.
    scope: System.get_env("OIDC_SCOPE")

  config :platform, PlatformWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

proof_repo_path = System.get_env("PROOF_OF_LIFE_REPO_PATH", "/repos/core")
proof_run_root = System.get_env("PROOF_OF_LIFE_RUN_ROOT", "/data/platform/execution-runs")
proof_author_name = System.get_env("GIT_AUTHOR_NAME", "Suite Runner")
proof_author_email = System.get_env("GIT_AUTHOR_EMAIL", "runner@suite.local")
proof_runner_image = System.get_env("PROOF_OF_LIFE_RUNNER_IMAGE", "suite-runner:dev")
proof_host_run_root = System.get_env("PROOF_OF_LIFE_HOST_RUN_ROOT")
proof_host_repo_git_path = System.get_env("PROOF_OF_LIFE_HOST_REPO_GIT_PATH")
proof_host_codex_auth_path = System.get_env("PROOF_OF_LIFE_HOST_CODEX_AUTH_PATH")
proof_runner_user = System.get_env("PROOF_OF_LIFE_RUNNER_USER")

proof_mode =
  case System.get_env("PROOF_OF_LIFE_MODE", "scripted") do
    "claude_cli" -> :claude_cli
    "claude-cli" -> :claude_cli
    "codex_exec" -> :codex_exec
    "codex-exec" -> :codex_exec
    "docker_scripted" -> :docker_scripted
    "docker-scripted" -> :docker_scripted
    "docker_claude_cli" -> :docker_claude_cli
    "docker-claude-cli" -> :docker_claude_cli
    "docker_codex_exec" -> :docker_codex_exec
    "docker-codex-exec" -> :docker_codex_exec
    _ -> :scripted
  end

# Agent workspace (sign-of-life — will be replaced by full agent runtime)
config :platform,
  agent_workspace_path: System.get_env("AGENT_WORKSPACE_PATH", "/data/agents/zip"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  inline_upload_max_bytes:
    String.to_integer(System.get_env("INLINE_UPLOAD_MAX_BYTES", "26214400")),
  upload_max_bytes: String.to_integer(System.get_env("UPLOAD_MAX_BYTES", "524288000")),
  pending_ttl_seconds: String.to_integer(System.get_env("PENDING_TTL_SECONDS", "900"))

# The attachment storage root. This file loads AFTER config/test.exs, so an
# unguarded write here would replace the per-run tmp root test.exs sets with
# the deploy-host path, and every file test on a box without a writable
# /data/platform would fail with {:error, :erofs} / :eacces. Tests own their
# root; dev and prod keep reading this key exactly as before.
if config_env() != :test do
  config :platform,
    chat_attachments_root: System.get_env("CHAT_ATTACHMENTS_ROOT", "/data/platform/chat_uploads")
end

# :attachment_signing_key is set by dev.exs/test.exs for local envs; prod
# must read it from an env var and fail fast if unset.
if config_env() == :prod do
  config :platform,
    attachment_signing_key:
      System.get_env("ATTACHMENT_SIGNING_KEY") ||
        raise("ATTACHMENT_SIGNING_KEY must be set (ADR 0039 phase 4+5)")
end

# :meeting_guest_signing_key is used by Platform.Meetings.GuestInvite to
# sign guest ingress tokens. Dev/test set stable local values; prod must
# read it from an env var and fail fast if unset.
if config_env() == :prod do
  config :platform,
    meeting_guest_signing_key:
      System.get_env("MEETING_GUEST_SIGNING_KEY") ||
        raise("MEETING_GUEST_SIGNING_KEY must be set for guest meeting invites")
end

# :meeting_calendar_signing_key is used by Platform.Meetings.CalendarLink
# to sign the per-meeting calendar link token. It is deliberately a
# SEPARATE key from :meeting_guest_signing_key: a calendar link never
# expires and rotating this key is its only revocation lever, so it must
# be rotatable without invalidating guest invites. Dev/test set stable
# local values; prod must read it from an env var and fail fast if unset.
if config_env() == :prod do
  config :platform,
    meeting_calendar_signing_key:
      System.get_env("MEETING_CALENDAR_SIGNING_KEY") ||
        raise("MEETING_CALENDAR_SIGNING_KEY must be set for meeting calendar links")
end

# :meeting_guest_host is the public hostname where guest meeting links
# resolve — read by the copy-guest-link surface to build the outbound
# URL. Deliberately NO `||` default, for the same reason `:meet_host`
# below has none: a guessed hostname mints links pointing at somebody
# else's environment. UNSET OR BLANK DISABLES guest-link generation
# (see `Platform.Meetings.GuestInvite.guest_host_configured?/0`) rather
# than falling back to anything. Background: `docs/features/guest-meetings.md`.
#
# Only WRITTEN when the env var is present: an unconditional write of `nil`
# here would clobber the dev/test values set in `config/dev.exs` and
# `config/test.exs`, since runtime config is applied last. Absent key and
# `nil` value mean the same thing to `guest_host_configured?/0`, so not
# writing loses nothing.
if guest_host = System.get_env("MEETING_GUEST_HOST") do
  config :platform, meeting_guest_host: guest_host
end

# :public_site_host is the public web address this deployment offers to
# EXTERNAL GUESTS who land on a guest meeting card that cannot let them in
# (expired invite, invalid invite, meetings temporarily unavailable). It is
# the only outbound link on those cards.
#
# Deliberately NO `||` default, for a reason the other host keys share and
# this one sharpens: `core` is a PUBLIC, open-source repository, and a
# default here would send every OTHER deployment's guests — a client's staff,
# people with no relationship to us — to one particular company's website.
# A per-deployment value belongs in per-deployment configuration.
#
# UNSET OR BLANK REMOVES THE ACTION from the card entirely (see
# `PlatformWeb.PublicSite.configured?/0`); it never falls back to a host.
# The cards read sensibly without it — each one already tells the guest to
# ask whoever invited them, which is the action that actually helps.
#
# Only WRITTEN when the env var is present, matching MEETING_GUEST_HOST
# above: an unconditional write of `nil` would clobber any value set in
# `config/dev.exs` / `config/test.exs`, since runtime config applies last.
if public_site_host = System.get_env("PUBLIC_SITE_HOST") do
  config :platform, :public_site_host, public_site_host
end

# Request-time meet host. Read here rather than only inside the prod
# block so a dev/CI process can set it; unset means the meet surface
# does not exist and every external request on any host is denied the
# meeting route. Deliberately NO `||` default — a guessed host is an
# authorization decision made from missing information.
config :platform, :meet_host, System.get_env("MEET_HOST")

# Request-time chat host, read here for the SAME reason `:meet_host` is, and
# moved out of the `config_env() == :prod` block by task 019fb955-f8b1 rework.
# Inside that block, exporting CHAT_HOST in dev or CI had NO effect on
# `PlatformWeb.ExternalRedirect.chat_host_configured?/0`, so the external-chat
# fence was silently inert everywhere but prod — and any dev/CI exercise of it
# was VACUOUS: it passed an unarmed fence. A reviewer following the setup
# instructions literally hit exactly that and had to inject the value as an OTP
# app env to arm it.
#
# `check_origin` still reads its own `chat_host` binding inside the prod block;
# that is deliberately untouched.
#
# Deliberately NO `||` default, matching `:meet_host` — a guessed host is an
# authorization decision made from missing information. Unset means the fence
# does not fire and `chat_url/1` stays host-relative.
config :platform, :chat_host, System.get_env("CHAT_HOST")

config :platform, :execution,
  proof_repo_path: proof_repo_path,
  local_run_root: proof_run_root,
  github_credentials: [
    token: System.get_env("GITHUB_TOKEN"),
    author_name: proof_author_name,
    author_email: proof_author_email
  ],
  suite_runnerd: [
    base_url: System.get_env("SUITE_RUNNERD_BASE_URL", "http://127.0.0.1:4101"),
    token: System.get_env("SUITE_RUNNERD_TOKEN")
  ]

config :platform, :proof_of_life,
  repo_path: proof_repo_path,
  repo_slug: System.get_env("PROOF_OF_LIFE_REPO_SLUG"),
  remote: System.get_env("PROOF_OF_LIFE_REMOTE", "origin"),
  base_ref: System.get_env("PROOF_OF_LIFE_BASE_REF", "origin/main"),
  run_root: proof_run_root,
  host_run_root: proof_host_run_root,
  host_repo_git_path: proof_host_repo_git_path,
  host_codex_auth_path: proof_host_codex_auth_path,
  proof_file: System.get_env("PROOF_OF_LIFE_FILE", "docs/proof-of-life.md"),
  mode: proof_mode,
  claude_command: System.get_env("PROOF_OF_LIFE_CLAUDE_COMMAND", "claude"),
  codex_command: System.get_env("PROOF_OF_LIFE_CODEX_COMMAND", "codex"),
  runner_user: proof_runner_user,
  runner_image: proof_runner_image,
  ssh_auth_path: System.get_env("PROOF_OF_LIFE_SSH_AUTH_PATH"),
  push_remote_url: System.get_env("PROOF_OF_LIFE_PUSH_REMOTE_URL"),
  runner_auth_env: [
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY"
  ],
  author_name: proof_author_name,
  author_email: proof_author_email

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # MEET_HOST is a sibling domain (e.g. "meet.example.com") that serves the
  # guest-meeting entry surface. It's a distinct hostname from PHX_HOST so
  # guests never see the primary Suite chrome, but LiveView WebSocket upgrades
  # still terminate against the same Phoenix endpoint. Add it to check_origin
  # so the socket handshake accepts requests originating from that hostname.
  # Unset → no guest-meeting origin allowlisted; guest LiveView sockets from
  # meet.<host> get rejected by Phoenix.Socket.Transport.check_origin/2.
  meet_host = System.get_env("MEET_HOST")

  # CHAT_HOST is a sibling domain (e.g. "chat.example.com") that serves the
  # external-chat surface (rbac-external-users M4, PR #584). Same rationale
  # as MEET_HOST: distinct hostname from PHX_HOST, but LiveView WebSocket
  # upgrades still terminate against the same Phoenix endpoint. Add to
  # check_origin so socket handshakes from chat.<host> aren't rejected by
  # Phoenix.Socket.Transport.check_origin/2. Unset → no chat-host origin
  # allowlisted; external ChatLive socket connects fail 403.
  chat_host = System.get_env("CHAT_HOST")

  # EXTRA_ORIGIN_APEXES is an optional comma-separated list of ADDITIONAL apex
  # domains (e.g. "example.com") that resolve to this same Phoenix endpoint.
  # Suite is being served on a second apex in parallel with the PHX_HOST apex
  # ahead of a later cutover: Traefik already routes suite./chat./meet.<apex>
  # there with a valid wildcard cert, but check_origin only allowlists the
  # PHX_HOST apex, so LiveView WebSocket handshakes from the second apex are
  # rejected — static pages render while LiveView never connects. Each entry
  # gets the same three-entry treatment as the primary apex; the "//*.<apex>"
  # wildcard is what covers the suite./chat./meet. subdomains there, so no
  # per-subdomain vars are needed. Unset or empty → nothing extra is
  # allowlisted and check_origin is identical to the single-apex behaviour.
  extra_origin_apexes =
    System.get_env("EXTRA_ORIGIN_APEXES", "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  # NOTE: `config :platform, :chat_host` used to be set here, inside the prod
  # block. It now lives at the top level (see the `:chat_host` config above)
  # because reading it only in prod left the external-chat fence inert in
  # dev/CI — any test of it was vacuous. The `chat_host` binding above is
  # still used by `check_origin`, which is prod-only by nature.
  config :platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :platform, PlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin:
      [
        "https://#{host}",
        "https://www.#{host}",
        "//*.#{host}"
      ] ++
        if(meet_host, do: ["https://#{meet_host}"], else: []) ++
        if(chat_host, do: ["https://#{chat_host}"], else: []) ++
        Enum.flat_map(extra_origin_apexes, fn apex ->
          ["https://#{apex}", "https://www.#{apex}", "//*.#{apex}"]
        end),
    secret_key_base: secret_key_base
end

# ── Web Push (VAPID) ──────────────────────────────────────────────────────────
# This block is ONE INPUT to `Platform.Push.vapid_details/0` — an explicit
# override for deployments that supply both halves as env vars — and NOT the send
# path's source of truth. Every VAPID reader (the `vapid-public-key` meta tag and
# `do_send_push/2` alike) goes through that resolver, which is all-or-nothing, so
# the two surfaces cannot disagree about whether push is configured.
#
# Vault resolution deliberately happens at CALL TIME rather than here, because
# `runtime.exs` evaluates before the Repo is started and before Vault decryption
# is available — so a Vault-held key cannot be lifted into app env at boot. Do
# not "fix" that by moving the Vault lookup up here; it will read as nil.
vapid_public = System.get_env("VAPID_PUBLIC_KEY")
vapid_private = System.get_env("VAPID_PRIVATE_KEY")

if vapid_public && vapid_private do
  config :web_push_encryption, :vapid_details,
    subject: "mailto:push@#{System.get_env("PHX_HOST", "suite.app")}",
    public_key: vapid_public,
    private_key: vapid_private
end

# ── WebMCP tool surface (BACKLOG #14) ─────────────────────────────────────────
# Gates registration of `navigator.modelContext` tools in app.js. Off by default
# in prod; on by default in dev. Override with WEBMCP_ENABLED=true|false.
# Tools drive the UI as the authenticated user and have no per-invocation
# confirmation yet — keep off in prod until Option C ships.
webmcp_enabled =
  case System.get_env("WEBMCP_ENABLED") do
    value when value in ["true", "1"] -> true
    value when value in ["false", "0"] -> false
    _ -> config_env() == :dev
  end

config :platform, :webmcp_enabled, webmcp_enabled

# ── LiveKit (Meetings) ────────────────────────────────────────────────────────
# Feature-gated: meetings are inert unless LIVEKIT_API_KEY + LIVEKIT_API_SECRET
# are set. See ADR 0030.
livekit_api_key = System.get_env("LIVEKIT_API_KEY")
livekit_api_secret = System.get_env("LIVEKIT_API_SECRET")
livekit_url = System.get_env("LIVEKIT_URL")

if livekit_api_key && livekit_api_secret do
  config :platform, :livekit,
    api_key: livekit_api_key,
    api_secret: livekit_api_secret,
    url: livekit_url || "wss://localhost:7880"
end

# ── GitHub webhooks ───────────────────────────────────────────────────────────
# App-level fallback secret for `/api/webhooks/github` HMAC verification. A
# project may carry its own value at `deploy_config["webhook_secret"]`; either
# candidate is accepted, which is what makes secret rotation possible without
# rejected deliveries. See `docs/runbooks/github_webhook_secret.md`.
#
# Guarded on presence (same shape as the LiveKit block above) rather than set
# unconditionally: runtime.exs is evaluated after `config/test.exs` in every
# env, so an unconditional `System.get_env/1` would write `nil` over the test
# fixture secret and leave the whole suite with no app-level candidate.
if github_webhook_secret = System.get_env("GITHUB_WEBHOOK_SECRET") do
  config :platform, :github_webhook_secret, github_webhook_secret
end

# ── Memory service ────────────────────────────────────────────────────────────
# Wires Platform.Memory to an external vector-search service (the Startup Suite
# memory-service by default). When MEMORY_SERVICE_URL is not set, the Noop
# provider is used — append_memory_entry still writes to Postgres and
# search_memory_entries falls back to substring match. See ADR 0033.
memory_service_url = System.get_env("MEMORY_SERVICE_URL")

memory_service_timeout =
  case System.get_env("MEMORY_SERVICE_TIMEOUT_MS") do
    nil -> 5_000
    value -> String.to_integer(value)
  end

if memory_service_url do
  config :platform, :memory_service,
    provider: Platform.Memory.Providers.StartupSuite,
    base_url: memory_service_url,
    api_key: System.get_env("MEMORY_SERVICE_API_KEY"),
    timeout: memory_service_timeout
end

# ── Files service ─────────────────────────────────────────────────────────────
# Wires Platform.Files.ServiceClient to the external files-service for
# binary-format text extraction (PDF / DOCX / image OCR). When
# FILES_SERVICE_URL is not set, no :files_service config key is written and
# ServiceClient.extract/2 short-circuits with {:error, :service_disabled}.
# See Platform.Files.ServiceClient and the files-service repo.
files_service_url = System.get_env("FILES_SERVICE_URL")

files_service_timeout =
  case System.get_env("FILES_SERVICE_TIMEOUT_MS") do
    nil -> 30_000
    value -> String.to_integer(value)
  end

if files_service_url do
  config :platform, :files_service,
    base_url: files_service_url,
    token: System.get_env("FILES_SERVICE_TOKEN"),
    timeout: files_service_timeout
end
