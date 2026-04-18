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
  skip_attachment_storage_check: true

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
config :platform, :memory_provider, Platform.Memory.Providers.Null
