import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :platform, PlatformWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wDzkIE+XxH39V2UNNOc1XIoqNslG2NDHj2MH2kHjx1obx7fvxcWMq8nL+v7wp/fo",
  server: false

config :platform, Platform.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PLATFORM_TEST_DATABASE", "platform_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :platform, :oidc,
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  issuer: "https://issuer.example.com",
  app_url: "http://www.example.com",
  strategy: Platform.TestOIDCStrategy,
  http_adapter: {Assent.HTTPAdapter.Mint, []}

config :platform,
  chat_attachments_root: Path.join(System.tmp_dir!(), "platform_test_chat_uploads"),
  skip_attachment_storage_check: true,
  attachment_signing_key: "test-attachment-signing-key-0123456789abcdef"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :platform, :start_attention_router, false
config :platform, :start_system_event_scheduler, false

# T3 (ADR-0041): tests start their own Platform.Org.Wiki.Indexer per case
# (so DataCase sandbox owns the Repo connection and tests don't fight a
# real subscriber). Production defaults to true via Application.start/2.
config :platform, :start_wiki_indexer, false

# T6 (ADR-0041): MeetingHistorianHandler subscribes to meeting PubSub at
# init; tests start their own per case for sandbox ownership.
config :platform, :start_meeting_historian_handler, false

# StackDeployer (T5) — tests run synchronously and use a no-op git
# runner by default so existing Stacks tests don't shell out. Tests that
# care about deployer behavior swap in their own runner via
# Application.put_env in their setup block.
config :platform, :stack_deployer,
  git_runner: Platform.Tasks.StackDeployer.NoopRunner,
  async: false

# Canvas server persists synchronously in tests so the SQL sandbox owns the
# write and teardown doesn't race with background Task.Supervisor children.
config :platform, :canvas_persist_sync, true

# T2 (ADR-0041, task 019e41d9-8b50-7f11-bfd0-b667b453c8f2) ships a
# scope-creep guard that asserts Platform.Org.Context has not changed
# since T1 HEAD (commit 4d6d332). The constant below is the sha256 of
# the file at that commit (`git show 4d6d332:apps/platform/lib/platform/org/context.ex`).
# Regenerate this only when a future task (e.g. T5 retirement of
# Org.Context) legitimately modifies the file — in the same commit.
#
# T5 stage 5 re-pinned this to absorb the one-line doc-comment fix
# (`org_memory_search` → `memory_search` on the
# `search_memory_with_scores/2` doc-string). The module body otherwise
# remains untouched; T7 retires the module.
#
# Rollup re-pin (Sloane-authorized, 2026-06-11): @default_templates keys
# moved from the flat form (`org/identity.md`) to the T5 routing page
# grammar (`org/page/identity.md`) alongside the 20260611120000 key
# migration — flat keys classify :unknown and are dropped by
# memory_search's read-gate hydration. Only the template keys (and the
# comment introducing them) changed; the module body is otherwise
# untouched.
config :platform,
       :t2_context_sha256_t1_head,
       # bumped by ADR 0042
       "278db635b7de680685ea8254b4ae51f0edb365a55b9f50e1c604ca6d3c246428"
