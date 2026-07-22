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

# Scheduled channel deletion (task 019e95ea stage 3): days a
# deletion-flagged channel is retained (still cancellable) before
# Platform.Chat.SpacePurger hard-deletes it. Read at sweep time via
# `Platform.Chat.space_retention_days/0`.
config :platform, :space_retention_days, 30

# Historian windowed dispatch (task 019f4f55, ADR-0041 T6 follow-up):
# per-window token budget the slicer uses to bound each dispatched
# digest, and the hard cap on windows per threshold sweep tick so the
# local-model Higgins doesn't get a 24M-token queue all at once.
# `Platform.Agents.HistorianDispatcher.slice_windows/1` reads
# `:historian_window_token_budget`; stage-3 sweep loop caps at
# `:historian_max_windows_per_pass` and lets subsequent ticks drain the
# tail. Overrides at runtime via `Application.put_env/3`.
config :platform, :historian_window_token_budget, 30_000
config :platform, :historian_max_windows_per_pass, 20

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
    Platform.Responsibilities.Handlers.TaskWeeklyReview,
    Platform.Responsibilities.Handlers.SecurityCveScan,
    Platform.Responsibilities.Handlers.SecurityCodeAudit,
    Platform.Responsibilities.Handlers.SecurityDeployAudit,
    Platform.Responsibilities.Handlers.SecuritySecretLeak,
    Platform.Responsibilities.Handlers.ArchitectureReviewPlan,
    Platform.Responsibilities.Handlers.ArchitectureAuditDiff,
    Platform.Responsibilities.Handlers.ArchitectureCronSweep
  ]

# Meeting-triage guardrails (task 019f5e2b-8d29). Two independent caps:
#
#   * `:meetings_triage_backlog_cap` — per-project count of
#     `metadata["source"] == "meetings.triage"` tasks that should carry
#     `needs_promotion: true` (stage 2). Above this, filed tasks land
#     with the flag cleared so the review UI does not surface an
#     unbounded backlog burst.
#   * `:meetings_triage_per_canvas_cap` — per-source-meeting-canvas hard
#     stop (stage 4). `Platform.Meetings.Triage.file_tasks_from_canvas/2`
#     refuses to file more than N tasks whose
#     `metadata["source_canvas_id"]` matches the current canvas, across
#     ALL invocations for that canvas. Above this, action items are
#     dropped, a `:triage_cap_hit` telemetry event fires, and a note is
#     appended to the source canvas.
#   * `:meetings_triage_dedup_threshold` — Jaro-Winkler similarity
#     threshold `Platform.Tasks.similar_open_titles/3` uses (stage 1).
#     Overridable per-call via the `:threshold` opt.
config :platform, :meetings_triage_backlog_cap, 10
config :platform, :meetings_triage_per_canvas_cap, 20
config :platform, :meetings_triage_dedup_threshold, 0.85

# Meeting Producer runtime (task 019f2452). Supervisor gate: when
# `true`, the boot sequence adds `Platform.Meetings.IntentClassifier`
# to the child list so it subscribes to `meeting:transcript_chunk` at
# startup. Disabled in `config/test.exs` — tests own per-case
# instances. Per-chunk firing is gated on
# `Platform.Roles.assignee_for("meetings.intent_classify")` returning
# a non-nil agent — assignment IS the enable signal.
config :platform, :start_meeting_intent_classifier, true

# IntentClassifier prior-context window size (task 019f474d): how many
# prior transcript chunks the classifier keeps buffered per room to
# thread into the LLM prompt as understand-only context. Tunes HOW the
# classifier builds prompt context; does NOT gate responsibility
# firing (integer default keeps it clear of the boolean-env-flag sweep
# in `no_env_flag_gates_test.exs`). Cleared on `meeting_finished` so
# per-room state doesn't leak on long-running nodes.
config :platform, :intent_classifier_context_window_size, 3

# IntentDispatcher (task 019f2452 stage 4): supervisor gate for the
# global GenServer that drains the IntentQueue. Boots in the child
# pipeline immediately after IntentClassifier so the conceptual
# `intent_queue -> classifier -> dispatcher` order matches runtime
# flow. Disabled in `config/test.exs` — tests own per-case instances
# for DataCase sandbox ownership.
config :platform, :start_meeting_intent_dispatcher, true

# IntentDispatcher runtime config: read at `init/1` and by the
# zero-arity `sweep_stalled/0` StallRegistry callback. `tick_interval_ms`
# is the belt-and-braces periodic poll (the hot path is PubSub-notify);
# `stall_window_ms` sets the threshold past which a `:dispatching` row
# is considered wedged and gets re-driven through `mark_retry/3`.
config :platform, Platform.Meetings.IntentDispatcher,
  tick_interval_ms: :timer.seconds(30),
  stall_window_ms: :timer.minutes(2)

# Security Sweeper (task 019f3e8e-4406 stage 2, ADR-0043): default
# tick cadence for the periodic scan sweep. One hour is a bounding
# ceiling — each scanner row's own `metadata["cadence"]` cron
# expression gates whether the tick actually invokes a scanner. The
# progressive-enhancement gate (`Roles.assignee_for/1 == nil`) keeps
# the tick a no-op until an agent is pinned to `security_guard`
# anyway, so this cadence is quiet-by-default in prod today.
config :platform, Platform.Security.Sweeper,
  check_interval_ms: :timer.hours(1),
  scanner_timeout_ms: :timer.seconds(60)

# Security scanner runtime knobs (task 019f3e8e-4406 stages 3-4,
# ADR-0043). `project_id` is the Suite project the scanners file
# their findings under — leave `nil` in dev and set an explicit
# project UUID at deploy time. `cve_scan_stale_days` gates the
# medium/low-severity long-tail rule from the task description.
# The `deploy_audit_*_root` keys let DeployAudit's four probes point
# at tmp fixtures under test — the shipped defaults point at the
# real prod-adjacent paths on `moon`.
config :platform, Platform.Security,
  project_id: nil,
  cve_scan_stale_days: 30,
  deploy_audit_traefik_root: "~/docker/traefik3/rules",
  deploy_audit_containers_root: "~/.config/containers/systemd",
  deploy_audit_core_ops_root: "/srv/dev/core-ops",
  deploy_audit_tls_root: "/etc/letsencrypt/live",
  deploy_audit_tls_expiry_warning_days: 30,
  # SecretLeak (task 019f3e8e-4406 stage 5). Full git-history scans
  # take minutes on real-sized repos; off by default. Enable per-env
  # in `config/runtime.exs` once operators have a baseline for how
  # long the current repo's history takes.
  secret_leak_scan_git_history: false,
  secret_leak_max_bytes_per_file: 1_048_576,
  secret_leak_max_git_log_bytes: 20_971_520,
  # FindingFiler batch consolidation threshold (task 019f3e8e-4406
  # stage 5). When one scanner run emits more than this many findings,
  # they collapse into a single weekly-digest task instead of N per-
  # finding rows. Prevents a broad-brush scanner from burying the
  # backlog.
  finding_digest_threshold: 10

# Repo-root the security scanners walk for lockfiles + source-tree
# patterns. Defaults to the platform app's own cwd — override per-env
# to point at whatever tree the security_guard bundle should scan.
config :platform, :security_scanner_repo_root, nil

# OSV.dev client module for the CVE scanner (task 019f3e8e-4406
# stage 3). Tests inject a mock module here so
# `Platform.Security.Scanners.CveScan` never hits the real API.
config :platform,
       :cve_scan_osv_client,
       Platform.Security.Scanners.CveScan.OsvClient

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

# Timezone database — Tzdata (IANA rules) backs `DateTime.shift_zone!/2`
# for timezone-aware cron triggers (task 019f70e9 stage 6). Without this
# only `Etc/UTC` shifts work; named zones like `America/Chicago` fail.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# `external_group`/`external_claim` (rbac-external-users M2 stage 1): the
# STATIC id-token claim NAME + value that marks a login as an SXI-external
# user. Read-only token consumption — ADR-0004 (no outbound IdP call).
# runtime.exs threads the prod value via OIDC_EXTERNAL_GROUP.
config :platform, :oidc,
  http_adapter: Assent.HTTPAdapter.Httpc,
  external_group: "sxi-external",
  external_claim: "groups"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
