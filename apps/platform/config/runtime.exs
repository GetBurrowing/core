import Config

# An empty string counts as unset, because systemd `Environment=X=` and
# compose `X: ""` both produce "". Only BURROW_ names are read (task 01a18dab
# removed the SUITE_ fallback).
env_or = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> default
  end
end

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

# ── Boot role (task 01a155a6) ─────────────────────────────────────────────────
# PLATFORM_ROLE picks the supervision tree `Platform.Role` selects: unset or
# "full" is today's node, "web" serves HTTP/LiveView only (a preview instance
# against prod's database). Any other value raises naming it, and the web role
# raises outside MIX_ENV=prod, because a dev build compiles /dev/login.
#
# Signing secrets under the web role (stage 2): a web node shares prod's
# session cookie domain and verifies links prod minted, so it must read
# SECRET_KEY_BASE, ATTACHMENT_SIGNING_KEY, MEETING_GUEST_SIGNING_KEY and
# MEETING_CALENDAR_SIGNING_KEY from the environment, never dev.exs's
# constants. Because validate!/2 admits :web only under :prod, the prod
# blocks below already read and require all four for it; a web-specific read
# would be a branch no boot can reach. test/platform/role_test.exs pins that
# a web+prod config with any one of them missing raises naming it.
platform_role = Platform.Role.parse!(System.get_env("PLATFORM_ROLE"))
Platform.Role.validate!(platform_role, config_env())
config :platform, :role, platform_role

# PLATFORM_CLUSTER_PEER (stage 3): the full node a web node joins over
# distributed Erlang, e.g. platform@core-platform. Read by
# Platform.Role.PeerLink. Unset means no peer; set under the full role raises.
config :platform,
       :cluster_peer,
       Platform.Role.parse_peer!(System.get_env("PLATFORM_CLUSTER_PEER"), platform_role)

# ── Native agents: experiment surfaces (task 01a10322 stages 1 and 7) ─────────
# All are read PER CALL from application env, so an install changes them with
# an env var and a restart, never a code change.
#
#   FIRST_AGENT_BUNDLES  bundles the first agent on an install receives
#                        (Platform.Federation.first_agent_bundles/0): "all"
#                        (default, every grantable bundle) or a comma list.
#   REPLY_FAILURE_NOTICE_DEDUPE_S  seconds within which an agent gets at most
#                        one reply-failure notice (Platform.Chat.ReplyFailure),
#                        default 300.
#   NATIVE_REPLY_WATCHDOG_S  seconds a native agent has to reply, or show turn
#                        activity, before its message gets a reply-failure
#                        notice (Platform.Chat.ReplyFailure.Watchdog), default
#                        45; 0 turns the watchdog off.
#   NATIVE_REPLY_WATCHDOG_MAX_S  the longest turn activity can hold that notice
#                        off, from delivery, default 600.
case System.get_env("NATIVE_REPLY_WATCHDOG_S") do
  nil ->
    :ok

  value ->
    case Integer.parse(String.trim(value)) do
      {0, ""} ->
        config :platform, :native_reply_watchdog_ms, false

      {seconds, ""} when seconds > 0 ->
        config :platform, :native_reply_watchdog_ms, seconds * 1000

      _ ->
        :ok
    end
end

case System.get_env("NATIVE_REPLY_WATCHDOG_MAX_S") do
  nil ->
    :ok

  value ->
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 ->
        config :platform, :native_reply_watchdog_max_ms, seconds * 1000

      _ ->
        :ok
    end
end

case System.get_env("FIRST_AGENT_BUNDLES") do
  nil -> :ok
  value -> config :platform, :first_agent_bundles, String.trim(value)
end

case System.get_env("REPLY_FAILURE_NOTICE_DEDUPE_S") do
  nil ->
    :ok

  value ->
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 ->
        config :platform, :reply_failure_notice_dedupe_s, seconds

      _ ->
        :ok
    end
end

# ── Native agents: the agent host (task 01a10322 stage 2) ────────────────────
#   AGENT_HOST_TOKEN     the shared secret the install's agent host presents on
#                        /agent-host/websocket. Unset means NO host can connect.
#   AGENT_HOST_CORE_URL  the URL native agents reach core at (sent in every
#                        agent.start); defaults to the endpoint URL.
case System.get_env("AGENT_HOST_TOKEN") do
  nil -> :ok
  "" -> :ok
  value -> config :platform, :agent_host_token, String.trim(value)
end

case System.get_env("AGENT_HOST_CORE_URL") do
  nil -> :ok
  "" -> :ok
  value -> config :platform, :agent_host_core_url, String.trim(value)
end

# NATIVE_AGENT_LOGIN  how native agents log in to Claude (task 01a17b10):
#                     `api_key` (default; unset means this) or `operator` (no
#                     API key; a human attaches to the agent's pane and logs
#                     in to Claude Code there). See Platform.Agents.NativeLogin.
case System.get_env("NATIVE_AGENT_LOGIN") do
  nil -> :ok
  "" -> :ok
  value -> config :platform, :native_agent_login, value |> String.trim() |> String.downcase()
end

# ── Session cookie domain (cross-subdomain OIDC login fix) ────────────────────
# The `_platform_session` cookie is host-only by default (no `Domain`), so a
# login started on `chat.example.com` loses its OIDC `state` cookie when
# Pocket-ID redirects the callback to `app.example.com` → "Invalid
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
# sets no default; when the key is unset the accessor falls back to the slug
# of the structural root org (`parent_org_id IS NULL`). An install sets
# ROOT_ORG_SLUG to pin the slug explicitly.
#
# Written only when the var is present and non-blank, so an unset or blank
# var leaves the structural fallback in charge and per-test
# `Application.put_env/3` overrides are the only other thing that moves it.
case System.get_env("ROOT_ORG_SLUG") do
  slug when is_binary(slug) and slug != "" ->
    config :platform, :root_org_slug, slug

  _ ->
    :ok
end

# ── Tenant display priority (per-install) ─────────────────────────────────────
# `Platform.Tenancy.tenant_priority/0` reads this key at runtime (task
# 01a14dd9). config.exs sets no default; when the key is unset every tenant
# sorts slug-alphabetically after the root. An install sets
# TENANT_ORG_PRIORITY to a comma-separated list of tenant slugs in display
# order; entries are trimmed, blanks dropped, order kept.
#
# Written only when the parsed list is non-empty, so an unset or blank var
# leaves the alphabetical fallback in charge and per-test
# `Application.put_env/3` overrides are the only other thing that moves it.
# The parser is only reached when the var is set.
case System.get_env("TENANT_ORG_PRIORITY") do
  value when is_binary(value) and value != "" ->
    case Platform.Tenancy.parse_tenant_priority(value) do
      [] -> :ok
      slugs -> config :platform, :tenant_priority, slugs
    end

  _ ->
    :ok
end

# ── Auto-admin email domain (per-install) ────────────────────────────────────
# `Platform.Tenancy.root_org_admin_email_domain/0` reads this key at runtime
# and `derive_role_from_email/1` uses it on every user INSERT and every
# email-change UPDATE. Renamed from ADMIN_EMAIL_DOMAIN / :admin_email_domain
# (task 01a068f6 stage 1): config.exs no longer defaults this key at all —
# only `config/test.exs` pins a value now, as an environment convenience
# rather than a shared production default.
#
# The branch shape here deliberately differs from SESSION_COOKIE_DOMAIN and
# ROOT_ORG_SLUG above, which both skip a blank value. Here a blank value is
# MEANINGFUL: ROOT_ORG_ADMIN_EMAIL_DOMAIN="" disables auto-admin entirely,
# and must NOT fall back to whatever the environment config pinned (e.g.
# test's fixture domain). An install that does not want any address
# auto-promoted on its database has to be able to say so by setting the var
# empty, without inventing a sentinel string.
#
# Unset (nil) means "keep whatever config.exs + the env-specific config file
# already set" — nothing on a production release or in dev (no default
# anywhere), and the fixture domain in test — so per-test
# `Application.put_env/3` overrides remain the only thing that moves the key
# there.
case System.get_env("ROOT_ORG_ADMIN_EMAIL_DOMAIN") do
  nil -> :ok
  domain -> config :platform, :root_org_admin_email_domain, String.trim(domain)
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

  # OIDC_EXTERNAL_GROUP has no default (task 01a14dd9): unset or blank is nil.
  oidc_external_group =
    case System.get_env("OIDC_EXTERNAL_GROUP") do
      group when is_binary(group) ->
        if String.trim(group) == "", do: nil, else: group

      _ ->
        nil
    end

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
    # a login as external. Static token-claim config, not a provider API
    # call (ADR-0004). OIDC_EXTERNAL_GROUP has NO default (task 01a14dd9):
    # unset or blank means nil, and a nil group flags nobody as external.
    # An install with external users MUST set it.
    external_group: oidc_external_group,
    external_claim: System.get_env("OIDC_EXTERNAL_CLAIM") || "groups",
    # OIDC authorization scope. Must include `groups` so Pocket-ID releases the
    # external-user group claim and login-time IdP role mappings. Nil when
    # unset, falling back to the groups-inclusive @default_scope in Platform.OIDC.
    scope: System.get_env("OIDC_SCOPE")

  config :platform, PlatformWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

proof_repo_path = System.get_env("PROOF_OF_LIFE_REPO_PATH", "/repos/core")
proof_run_root = System.get_env("PROOF_OF_LIFE_RUN_ROOT", "/data/platform/execution-runs")
proof_author_name = System.get_env("GIT_AUTHOR_NAME", "Burrow Runner")
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

# Per-install ceiling for one chat file sent through the resumable chunked
# upload path (task 01a120be), and the size of each PATCH chunk. Read only via
# Platform.Chat.UploadLimits. Default 1_000_000_000 bytes ("1 GB"); lower it
# on an install to roll back without a deploy. The chunk default (32 MiB) stays well under any edge
# (Cloudflare) request-body cap. Distinct from :upload_max_bytes (agents' single
# POST, 500 MB) and ChatLive's 15 MB inline LiveView cap, both unchanged.
config :platform,
  chat_max_upload_bytes: String.to_integer(System.get_env("CHAT_MAX_UPLOAD_BYTES", "1000000000")),
  upload_chunk_bytes: String.to_integer(System.get_env("UPLOAD_CHUNK_BYTES", "33554432"))

# The attachment storage root. This file loads AFTER config/test.exs, so an
# unguarded write here would replace the per-run tmp root test.exs sets with
# the deploy-host path, and every file test on a box without a writable
# /data/platform would fail with {:error, :erofs} / :eacces. Tests own their
# root; dev and prod keep reading this key exactly as before.
if config_env() != :test do
  config :platform,
    chat_attachments_root: System.get_env("CHAT_ATTACHMENTS_ROOT", "/data/platform/chat_uploads")
end

# Email module (task 01a0cf21 stage 2): Platform.Mail.Mailer sends over SMTP.
# Relay, port, TLS mode, username and password are NOT configured here — each
# send passes them as deliver/2 overrides built from the resolved mail account
# and its Vault secret. :test keeps the recording adapter from test.exs.
if config_env() != :test do
  config :platform, Platform.Mail.Mailer, adapter: Swoosh.Adapters.SMTP
end

# ── External feedback (task 01a11ec3 stage 2) ─────────────────────────────────
# FEEDBACK_POLICY is the ONE capability value: disabled | quarantined | trusted.
# `Platform.Feedback.Policy.normalize/1` treats unset, blank and every other
# value as disabled, so a typo turns the capability off, never on.
#
# Publisher settings carry NO credential. FEEDBACK_PUBLISHER selects the
# adapter: `broker` (default; every Burrow installation) posts to
# FEEDBACK_BROKER_URL and holds no GitHub secret at all; `github_app` is for
# the Burrow-hosted broker side only and reads FEEDBACK_GITHUB_APP_ID,
# FEEDBACK_GITHUB_APP_INSTALLATION_ID and FEEDBACK_GITHUB_APP_PRIVATE_KEY from
# the process environment at call time — they are deliberately NOT copied
# into application config here.
#
# Skipped under :test, which pins the policy to disabled and routes both
# adapters to Req.Test stubs; tests flip keys per-test and restore them.
if config_env() != :test do
  config :platform, :feedback_policy, System.get_env("FEEDBACK_POLICY", "disabled")

  feedback_adapter =
    case System.get_env("FEEDBACK_PUBLISHER", "broker") |> String.trim() |> String.downcase() do
      "github_app" -> Platform.Feedback.GithubPublisher.GithubApp
      _ -> Platform.Feedback.GithubPublisher.Broker
    end

  config :platform, Platform.Feedback.GithubPublisher,
    adapter: feedback_adapter,
    repository: System.get_env("FEEDBACK_REPOSITORY", "Startup-Suite/core"),
    broker_url: System.get_env("FEEDBACK_BROKER_URL"),
    github_api_url: System.get_env("FEEDBACK_GITHUB_API_URL"),
    installation_label: System.get_env("FEEDBACK_INSTALLATION_LABEL")

  feedback_int = fn name ->
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  config :platform, :feedback_rate_limits,
    per_actor: feedback_int.("FEEDBACK_RATE_LIMIT_PER_AGENT"),
    per_installation: feedback_int.("FEEDBACK_RATE_LIMIT_PER_INSTALLATION"),
    window_seconds: feedback_int.("FEEDBACK_RATE_LIMIT_WINDOW_SECONDS")

  # Intake (task 01a11ec3 stage 3). FEEDBACK_INTAKE_PROJECT_ID names the
  # project accepted reports on the feedback repository are filed into (when
  # unset, the oldest non-archived project connected to that repository).
  # FEEDBACK_INTAKE_DISPOSITION is comment | comment_and_close | none; any
  # other value is comment. Dispositions go through the broker, so this
  # carries no credential either.
  config :platform, Platform.Feedback.Intake,
    project_id: System.get_env("FEEDBACK_INTAKE_PROJECT_ID"),
    disposition_mode: System.get_env("FEEDBACK_INTAKE_DISPOSITION", "comment")
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

# OWN_HOST_ALIASES: comma-separated extra hostnames this same install is
# reached on (a second apex, a renamed host). `Platform.Chat.LinkTargets`
# treats a canvas/prototype link on one of them as in-app (exact host match,
# case-insensitive, endpoint or scheme-default port) and the renderer makes
# it path-relative. Top level, not prod-only, so dev/CI exercise the real
# path. Unset leaves whatever compile-time config set (`[]` by default; the
# test env sets an example.com alias). No default hostnames here: the real
# values live in deploy config.
#
# The same list also feeds prod's `check_origin` below (task 01a18dab stage
# 3): one knob makes an alias both link-recognised and socket-accepted, so a
# renamed primary host (PHX_HOST) keeps its old name working as an alias.
own_host_aliases =
  case System.get_env("OWN_HOST_ALIASES") do
    nil ->
      nil

    aliases ->
      aliases
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
  end

if own_host_aliases do
  config :platform, :own_host_aliases, own_host_aliases
end

config :platform, :execution,
  proof_repo_path: proof_repo_path,
  local_run_root: proof_run_root,
  github_credentials: [
    token: System.get_env("GITHUB_TOKEN"),
    author_name: proof_author_name,
    author_email: proof_author_email
  ],
  suite_runnerd: [
    base_url: env_or.("BURROW_RUNNERD_BASE_URL", "http://127.0.0.1:4101"),
    token: env_or.("BURROW_RUNNERD_TOKEN", nil)
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
  # guests never see the primary Burrow chrome, but LiveView WebSocket upgrades
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
  # domains (e.g. "example.org") that resolve to this same Phoenix endpoint.
  # Burrow is being served on a second apex in parallel with the PHX_HOST apex
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

  base_origins =
    [
      "https://#{host}",
      "https://www.#{host}",
      "//*.#{host}"
    ] ++
      if(meet_host, do: ["https://#{meet_host}"], else: []) ++
      if(chat_host, do: ["https://#{chat_host}"], else: []) ++
      Enum.flat_map(extra_origin_apexes, fn apex ->
        ["https://#{apex}", "https://www.#{apex}", "//*.#{apex}"]
      end)

  # OWN_HOST_ALIASES entries are exact hosts, so each admits exactly
  # `https://<alias>`: no www. and no wildcard, unlike an EXTRA_ORIGIN_APEXES
  # apex. Appended after, and only when not already present, so with the var
  # unset `check_origin` is exactly `base_origins`, element for element.
  alias_origins =
    (own_host_aliases || [])
    |> Enum.map(&"https://#{&1}")
    |> Enum.uniq()
    |> Enum.reject(&(&1 in base_origins))

  check_origin = base_origins ++ alias_origins

  config :platform, PlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: check_origin,
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

# No `:subject` here: `Platform.Push.vapid_subject/1` derives it from the
# endpoint's host at call time, so the subject follows PHX_HOST through
# `PlatformWeb.Endpoint` instead of a second reader with its own default.
if vapid_public && vapid_private do
  config :web_push_encryption, :vapid_details,
    public_key: vapid_public,
    private_key: vapid_private
end

# ── Push relay server mode (task 01a1261e stage 2) ───────────────────────────
# PUSH_RELAY_SERVER=true turns this install into a Burrow push relay: it accepts
# `POST /api/push-relay/v1/notifications` from registered installs and forwards
# sealed items to APNs/FCM with its own credentials. Unset (every normal
# install), every relay route is a 404. PUSH_RELAY_RATE_PER_MINUTE overrides
# the per-install item budget (default 1,200/min). The INSTALL side
# (PUSH_RELAY_URL / PUSH_RELAY_CREDENTIAL) is resolved at call time by
# `Platform.Push.Relay.relay_config/0`, like the APNs credentials.
if System.get_env("PUSH_RELAY_SERVER") in ["true", "1"] do
  relay_rate =
    case Integer.parse(System.get_env("PUSH_RELAY_RATE_PER_MINUTE") || "") do
      {n, ""} when n > 0 -> n
      _ -> nil
    end

  config :platform, :push_relay_server,
    enabled: true,
    rate_per_minute: relay_rate
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

# ── Reconnect escalation thresholds (task 01a12b10) ──────────────────────────
# A dropped LiveView connection shows a quiet "Reconnecting…" state; the red
# toast waits for RECONNECT_ESCALATE_ATTEMPTS failed attempts or
# RECONNECT_ESCALATE_SECONDS seconds, whichever comes first. Garbage, zero or
# negative values fall back to the defaults (11/10);
# PlatformWeb.ReconnectEscalation.config/0 clamps and renders them into the
# root layout's <meta name="reconnect-escalation">. Runs in dev too, so the
# dev rig's EXTRA_ENV can set it.
reconnect_escalate = fn var, default ->
  case Integer.parse(String.trim(System.get_env(var) || "")) do
    {n, ""} when n > 0 -> n
    _ -> default
  end
end

config :platform, :reconnect_escalation,
  attempts: reconnect_escalate.("RECONNECT_ESCALATE_ATTEMPTS", 11),
  seconds: reconnect_escalate.("RECONNECT_ESCALATE_SECONDS", 10)

# ── Agents goal surface (task 01a0b491) ──────────────────────────────────────
# Gates the WHOLE agents surface: the rail block above Pinned and the space
# header's goal line. OFF BY DEFAULT IN EVERY ENVIRONMENT, dev included —
# unlike WEBMCP_ENABLED above, which defaults on in dev. The stage-1 columns
# (`chat_spaces.goal`, `chat_spaces.leader_agent_id`) stay inert while it is
# unset: they may hold values and nothing renders. Set AGENTS_GOAL_SURFACE=true
# to turn it on.
config :platform,
       :agents_goal_surface,
       System.get_env("AGENTS_GOAL_SURFACE") in ["true", "1"]

# Build-time modules read their own runtime settings in their own
# Application.start/2 (ADR 0055, task 01a0ee08 stage 3); nothing here names
# one. See 0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module

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

# LiveKit agent name core dispatches the meeting transcriber as, on both the
# JWT `roomConfig.agents` path and the CreateRoom body. The LiveKit server can
# be shared by several Burrow installs; each install needs its OWN transcriber
# worker (registered under its own agent name, posting segments to its own
# `PERSIST_URL`), or one install's meetings are transcribed into another's.
# Unset or blank keeps the default `"meeting-transcriber"`.
case System.get_env("MEETING_TRANSCRIBER_AGENT_NAME") do
  name when is_binary(name) and name != "" ->
    config :platform, :meeting_transcriber_agent_name, String.trim(name)

  _ ->
    :ok
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

# ── Deploy audit: core-ops checkout (task 01a14b9e stage 2) ─────────────────
# `Platform.Security.Scanners.DeployAudit`'s env-diff probe reads the install's
# private ops checkout (targets/*/env/*.env.example vs secrets/<target>/). The
# path is install-specific, so there is no default anywhere in code: unset or
# blank leaves `deploy_audit_core_ops_root: nil` (config.exs) and the probe
# returns `{:not_configured, "DEPLOY_AUDIT_CORE_OPS_ROOT"}`. Guarded on
# presence, like the secret above, so tests can configure it with
# Application.put_env.
case String.trim(System.get_env("DEPLOY_AUDIT_CORE_OPS_ROOT") || "") do
  "" -> :ok
  root -> config :platform, Platform.Security, deploy_audit_core_ops_root: root
end

# ── Deploy skip notice (task 01a0feff) ────────────────────────────────────────
# `Platform.Deploy.SkipNotice` posts one message to DEPLOY_SKIP_NOTICE_SPACE_ID
# when a `workflow_run` for DEPLOY_SKIP_NOTICE_REPO (an `owner/name` string) on
# DEPLOY_SKIP_NOTICE_BRANCH (default "main") from workflow
# DEPLOY_SKIP_NOTICE_WORKFLOW (default "CI") completes with any conclusion other
# than "success" — the runs the prod deploy hook skips. Both the space and the
# repo are required; with either unset the notice is off. Guarded on presence,
# like the secret above, so tests can configure it with Application.put_env.
deploy_skip_notice_space_id = System.get_env("DEPLOY_SKIP_NOTICE_SPACE_ID")
deploy_skip_notice_repo = System.get_env("DEPLOY_SKIP_NOTICE_REPO")

if deploy_skip_notice_space_id && deploy_skip_notice_repo do
  config :platform, :deploy_skip_notice,
    space_id: deploy_skip_notice_space_id,
    repo: deploy_skip_notice_repo,
    branch: System.get_env("DEPLOY_SKIP_NOTICE_BRANCH", "main"),
    workflow: System.get_env("DEPLOY_SKIP_NOTICE_WORKFLOW", "CI")
end

# ── Memory service ────────────────────────────────────────────────────────────
# Wires Platform.Memory to an external vector-search service (the Burrow
# memory-service by default). When MEMORY_SERVICE_URL is not set, the Noop
# provider is used — append_memory_entry still writes to Postgres and
# search_memory_entries falls back to substring match. See ADR 0033.
memory_service_url = System.get_env("MEMORY_SERVICE_URL")

#
# Two timeouts (task 01a0d8c9):
#   MEMORY_SERVICE_TIMEOUT_MS         -> :timeout, bounds /search, DELETE
#                                        /entries and /health ONLY (default 5000).
#   MEMORY_SERVICE_INGEST_TIMEOUT_MS  -> :ingest_timeout, bounds POST /ingest
#                                        ONLY (default 120000). Ingest never
#                                        falls back to MEMORY_SERVICE_TIMEOUT_MS.
#
# Stopgap to revert: before this split, MEMORY_SERVICE_TIMEOUT_MS=120000 was
# set in production to stop the wiki indexer resending page ingests every 5s.
# Once this ships that setting is no longer needed and must be reverted to
# unset (or 5000): left at 120000 it lengthens every /search bound to 120s,
# and the journal telemetry handler's blocking ingest bound with it (it
# reuses :timeout on purpose; see Platform.Memory.TelemetryHandler).
memory_service_timeout =
  case System.get_env("MEMORY_SERVICE_TIMEOUT_MS") do
    nil -> 5_000
    value -> String.to_integer(value)
  end

memory_service_ingest_timeout =
  case System.get_env("MEMORY_SERVICE_INGEST_TIMEOUT_MS") do
    nil -> 120_000
    value -> String.to_integer(value)
  end

if memory_service_url do
  config :platform, :memory_service,
    provider: Platform.Memory.Providers.MemoryService,
    base_url: memory_service_url,
    api_key: System.get_env("MEMORY_SERVICE_API_KEY"),
    timeout: memory_service_timeout,
    ingest_timeout: memory_service_ingest_timeout
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

# ── One-click installs (task 01a10315 stage 2) ───────────────────────────────
# BURROW_INSTALLS_DNS_ZONE: the DigitalOcean-managed zone an install on a
# subdomain of ours lives under (<slug>.<zone> and auth.<slug>.<zone>). Unset:
# only customer-domain installs can be created.
case System.get_env("BURROW_INSTALLS_DNS_ZONE") do
  zone when is_binary(zone) and zone != "" -> config :platform, Platform.Installs, dns_zone: zone
  _ -> :ok
end

# Install requests (task 01a18f0c stage 2). BURROW_INSTALL_INTAKE_TOKEN is the
# bearer the getburrow.ing Pages Function sends to POST /api/install-requests
# (unset: the route answers 404). BURROW_INSTALLS_MAIL_ORG_ID / _ACCOUNT_ID /
# _SENDER_KEY name the mail account and sender the hand-over email uses
# (stage 4; unset: no email is sent).
config :platform, Platform.Installs,
  intake_token: System.get_env("BURROW_INSTALL_INTAKE_TOKEN"),
  mail_sender: %{
    org_id: System.get_env("BURROW_INSTALLS_MAIL_ORG_ID"),
    account_id: System.get_env("BURROW_INSTALLS_MAIL_ACCOUNT_ID"),
    sender_key: System.get_env("BURROW_INSTALLS_MAIL_SENDER_KEY")
  }

# The install images are public, so no pull credential is used by default.
# BURROW_INSTALLS_REGISTRY_AUTH_SLUG names a vault slug holding a docker
# config.json to pass as --registry-auth instead (a private registry).
case System.get_env("BURROW_INSTALLS_REGISTRY_AUTH_SLUG") do
  slug when is_binary(slug) and slug != "" ->
    config :platform, Platform.Installs, registry_auth_slug: slug

  _ ->
    :ok
end

# BURROW_INSTALLS_CORE_IMAGE (stage 6 round 2): a dev/staging test seam that
# makes installs pull a pinned core build (e.g. ghcr.io/getburrowing/core:
# core-<sha>) instead of core:core. Recorded with the release env and the
# explicit opt-in BURROW_INSTALLS_CORE_IMAGE_OPT_IN=1; Platform.Installs.
# core_image_override/0 ignores it, with a logged warning, in a :prod release,
# without the opt-in, or for a moving tag (core, play, latest).
case System.get_env("BURROW_INSTALLS_CORE_IMAGE") do
  ref when is_binary(ref) and ref != "" ->
    config :platform, Platform.Installs,
      core_image_override: %{
        ref: ref,
        env: config_env(),
        opt_in: System.get_env("BURROW_INSTALLS_CORE_IMAGE_OPT_IN") == "1"
      }

  _ ->
    :ok
end

# Dev stand-in agent host: BURROW_FAKE_AGENT_HOST=1, dev only (task 01a10315
# stage 4). Platform.AgentHost.FakeHost joins the reconciler as the install's
# host; a codex agent waits at a fake device login (code FAKE-1234) until
# POST /dev/fake-agent-host/<agent_id>/complete.
if config_env() == :dev and System.get_env("BURROW_FAKE_AGENT_HOST") == "1" do
  config :platform, :fake_agent_host, true
end

# The release image copies the installer package here (apps/platform/Dockerfile);
# dev and test run it from the repo's deployment/installer.
if config_env() == :prod do
  config :platform, Platform.Installs, installer_path: "/app/installer"
end

# Dev stub mode: BURROW_INSTALLS_FAKE=1, dev only. DigitalOcean is the
# in-process PlatformWeb.Dev.FakeDigitalOcean (also at /dev/fake-digitalocean),
# and render, probes and bootstrap are Platform.Installs.Fake. Never reads the
# real token.
if config_env() == :dev and System.get_env("BURROW_INSTALLS_FAKE") == "1" do
  config :platform, Platform.Installs,
    fake: true,
    render: Platform.Installs.Fake,
    probe: Platform.Installs.Fake,
    bootstrap: Platform.Installs.Fake,
    dns_zone: "fake.invalid",
    poll_interval_ms: 1_000,
    # Three consecutive fake memory polls a second apart, not a minute.
    memory_poll_interval_ms: 1_000

  config :platform, Platform.Installs.DigitalOcean,
    base_url: "http://fake-digitalocean.invalid",
    token_source: {:static, "dop_v1_fake_dev_only"},
    req_options: [plug: PlatformWeb.Dev.FakeDigitalOcean]
end
