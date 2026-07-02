# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :platform,
  ecto_repos: [Platform.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: config_env()

config :platform, Platform.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id]

# Responsibilities Registry boot flag (ADR-0041 M1 stage 4) — default
# on. Disabled in config/test.exs so DataCase-sandboxed tests own their
# own per-case instance.
config :platform, :start_responsibilities_registry, true

# Responsibilities provider list (ADR-0041 M8 stage 2). Registry reads
# this on init and upserts every declared row. Mirror this list with
# `Platform.Responsibilities.BuiltIns.providers/0` — feature teams add
# their modules to BOTH places (BuiltIns is the canonical list used in
# tests; this key is what the boot-time Registry actually reads). Kept
# as a literal here because module-function calls aren't allowed at
# compile-config time.
config :platform, Platform.Responsibilities,
  providers: [
    Platform.Responsibilities.Handlers.DailySummary,
    Platform.Responsibilities.Handlers.Dreaming,
    Platform.Responsibilities.Handlers.MeetingSummarize,
    Platform.Responsibilities.Handlers.IntentClassify
  ]

# M8 stage 2: dual-write shim gate. When `false` (default), the legacy
# `Platform.Agents.SystemEventScheduler` dispatch runs alone. When
# `true`, the scheduler ALSO calls `Platform.Responsibilities.Router.fire/2`
# for `:memory_daily_summary` + `:memory_dreaming` so a cutover monitor
# can compare the two paths' outputs. Flip permanently in `config/prod.exs`
# after `Platform.Responsibilities.CutoverMonitor` reports zero divergence.
config :platform, :responsibility_router_enabled, false

# Configure the endpoint
config :platform, PlatformWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PlatformWeb.ErrorHTML, json: PlatformWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Platform.PubSub,
  live_view: [signing_salt: "LVkhtRt/"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  platform: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  platform: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :platform, :oidc, http_adapter: Assent.HTTPAdapter.Httpc

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
