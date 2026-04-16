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
    pkce_enabled: System.get_env("OIDC_PKCE_ENABLED") in ["true", "1"]

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
  chat_attachments_root: System.get_env("CHAT_ATTACHMENTS_ROOT", "/data/platform/chat_uploads")

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

  config :platform, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :platform, PlatformWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: [
      "https://#{host}",
      "https://www.#{host}",
      "//*.#{host}"
    ],
    secret_key_base: secret_key_base
end

# ── Web Push (VAPID) ──────────────────────────────────────────────────────────
# Configure the web_push_encryption library with VAPID keys at runtime.
# Keys are read from env vars, falling back to Vault lookup in Platform.Push.
vapid_public = System.get_env("VAPID_PUBLIC_KEY")
vapid_private = System.get_env("VAPID_PRIVATE_KEY")

if vapid_public && vapid_private do
  config :web_push_encryption, :vapid_details,
    subject: "mailto:push@#{System.get_env("PHX_HOST", "suite.app")}",
    public_key: vapid_public,
    private_key: vapid_private
end

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

# ── Memory Service (ADR 0033) ────────────────────────────────────────────────
# Feature-gated: external memory indexing is inert unless MEMORY_SERVICE_URL
# is set. The Null provider is used by default (no-op).
memory_service_url = System.get_env("MEMORY_SERVICE_URL")

if memory_service_url do
  config :platform,
    memory_provider: Platform.Memory.Providers.StartupSuite,
    memory_service_url: memory_service_url
end
