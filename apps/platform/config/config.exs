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
    Platform.Responsibilities.Handlers.ProposeLongTerm,
    Platform.Responsibilities.Handlers.MeetingSummarize,
    Platform.Responsibilities.Handlers.IntentClassify,
    Platform.Responsibilities.Handlers.MeetingActionItems,
    Platform.Responsibilities.Handlers.MeetingAttendanceFollowup,
    Platform.Responsibilities.Handlers.DesignCritique,
    Platform.Responsibilities.Handlers.DesignSpecWriter,
    Platform.Responsibilities.Handlers.DesignBrandCheck,
    Platform.Responsibilities.Handlers.TaskTriage,
    Platform.Responsibilities.Handlers.TaskUnblock,
    Platform.Responsibilities.Handlers.TaskWeeklyReview
  ]

# M8 stage 2: dual-write shim gate. When `false` (default), the legacy
# `Platform.Agents.SystemEventScheduler` dispatch runs alone. When
# `true`, the scheduler ALSO calls `Platform.Responsibilities.Router.fire/2`
# for `:memory_daily_summary` + `:memory_dreaming` so a cutover monitor
# can compare the two paths' outputs. Flip permanently in `config/prod.exs`
# after `Platform.Responsibilities.CutoverMonitor` reports zero divergence.
config :platform, :responsibility_router_enabled, false

# Meeting Producer runtime (task 019f2452). Two flags with distinct roles:
#
#   * `:start_meeting_intent_classifier` — supervisor gate. When `true`,
#     the boot sequence adds `Platform.Meetings.IntentClassifier` to the
#     child list so it subscribes to `meeting:transcript_chunk` at
#     startup. Disabled in `config/test.exs` — tests own per-case
#     instances.
#
#   * `:meeting_producer_runtime_enabled` — runtime kill-switch. When
#     `false` (v1 default) the classifier drops every chunk at guard 1
#     WITHOUT touching the LLM or the IntentQueue. Flip to `true` in a
#     follow-up config change once the seeds land and the pipeline is
#     ready to fire on live traffic.
config :platform, :start_meeting_intent_classifier, true
config :platform, :meeting_producer_runtime_enabled, false

# LiveKit webhook HMAC-JWT signature enforcement (task 019f3312 stage 2 —
# phantom-fix v4). When `true` (prod default), every request to
# `/api/webhooks/livekit` MUST carry a valid `Authorization: <jwt>` header
# whose HS256 signature verifies under `LIVEKIT_API_SECRET` AND whose
# `sha256` claim matches the raw body's SHA256; failures return 401.
# When `false`, verification failures are logged as warnings but the
# request passes through — rollback safety valve for runtime config.
# Overridden to `false` in `config/test.exs` so existing controller tests
# keep exercising handlers without minting a JWT per payload.
config :platform, :livekit_webhook_signature_required, true

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
