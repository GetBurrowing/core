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

# Email module (task 01a0cf21 stage 2): the only adapter in use is SMTP, which
# needs no HTTP client, so Swoosh must not look for one.
config :swoosh, :api_client, false

# Email module IMAP read path (task 01a0cf21 stage 3). Polling interval per
# account; IDLE is deferred. `client` is the Platform.Mail.Imap.Client impl.
config :platform, Platform.Mail.Inbound,
  poll_ms: 60_000,
  initial_delay_ms: 1_000,
  client: Platform.Mail.Imap.WireClient

# Responsibilities Registry boot flag (ADR-0041 M1 stage 4) — default
# on. Disabled in config/test.exs so DataCase-sandboxed tests own their
# own per-case instance.
config :platform, :start_responsibilities_registry, true

# Scheduled channel deletion (task 019e95ea stage 3): days a
# deletion-flagged channel is retained (still cancellable) before
# Platform.Chat.SpacePurger hard-deletes it. Read at sweep time via
# `Platform.Chat.space_retention_days/0`.
config :platform, :space_retention_days, 30

# Extra hostnames this install is served on; see OWN_HOST_ALIASES in
# runtime.exs. Empty by default: real hosts belong in deploy config.
config :platform, :own_host_aliases, []

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
    Platform.Responsibilities.Handlers.MeetingBriefSynthesis,
    Platform.Responsibilities.Handlers.IntentClassify,
    Platform.Responsibilities.Handlers.MeetingActionItems,
    Platform.Responsibilities.Handlers.MeetingAttendanceFollowup,
    # Mid-meeting intent responsibilities (2026-07-31). These MUST be
    # here and not only in `BuiltIns.providers/0`: the boot-time Registry
    # reads THIS key, and the Router subscribes at boot to the topic
    # strings its registered rows declare. A handler present only in
    # BuiltIns registers no row, so the Router never subscribes, and
    # every dispatch for that intent is marked `:dispatched`, holds the
    # meeting's serial cursor, and times out 90s later against nobody.
    # `built_ins_test.exs` pins the two lists equal for exactly this
    # reason — it caught this omission.
    Platform.Responsibilities.Handlers.MeetingVisualAdjust,
    Platform.Responsibilities.Handlers.MeetingInteractionDesign,
    Platform.Responsibilities.Handlers.MeetingBriefWorthy,
    Platform.Responsibilities.Handlers.MeetingDecisionRecorded,
    Platform.Responsibilities.Handlers.MeetingOpenQuestion,
    Platform.Responsibilities.Handlers.DesignCritique,
    Platform.Responsibilities.Handlers.DesignSpecWriter,
    Platform.Responsibilities.Handlers.DesignBrandCheck,
    Platform.Responsibilities.Handlers.DesignTaskDirection,
    Platform.Responsibilities.Handlers.TaskTriage,
    Platform.Responsibilities.Handlers.TaskUnblock,
    Platform.Responsibilities.Handlers.TaskWeeklyReview,
    Platform.Responsibilities.Handlers.SecurityCveScan,
    Platform.Responsibilities.Handlers.SecurityCodeAudit,
    Platform.Responsibilities.Handlers.SecurityDeployAudit,
    Platform.Responsibilities.Handlers.SecuritySecretLeak,
    Platform.Responsibilities.Handlers.ArchitectureReviewPlan,
    Platform.Responsibilities.Handlers.ArchitectureAuditDiff,
    Platform.Responsibilities.Handlers.ArchitectureCronSweep,
    Platform.Responsibilities.Handlers.AgentsGoalHeartbeat,
    Platform.Responsibilities.Handlers.ExperimentsLabelSignal,
    Platform.Responsibilities.Handlers.ExperimentsScientist,
    # Task 01a11ec3 stage 3: external-feedback intake (never the janitor).
    Platform.Responsibilities.Handlers.FeedbackIntake,
    # Task 019fa1ac-6685 stage 1: the janitor's weekly chore drain.
    Platform.Responsibilities.Handlers.JanitorCronDrain
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

# Canvas rooms (task 01a1316b-84fa stage 1) — an experiment surface, read at
# call time by `Platform.Chat.CanvasRoom`:
#   * `:persist_debounce_ms` — how long accepted ops wait before ONE
#     transaction flushes them. Larger = fewer transactions per 100 ops, and
#     more ops lost to a brutal kill (at most one window).
#   * `:idle_stop_ms` — how long a room with no viewers lives before it
#     flushes and stops.
config :platform, Platform.Chat.CanvasRoom,
  persist_debounce_ms: 500,
  idle_stop_ms: 60_000

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

# IntentDispatcher runtime config: read at `init/1`. `tick_interval_ms`
# is the belt-and-braces periodic re-drive; the hot path is the
# `meeting:intent_enqueued` PubSub notify.
#
# `stall_window_ms` was removed in task 019f70b8 stage 3 — stall
# detection is no longer a periodic scan for wedged rows. Each
# per-meeting queue arms its own ack timer when a row is dispatched
# (`queue_ack_timeout_ms` below), so a row that goes out and never
# comes back is resolved by its own owner.
config :platform, Platform.Meetings.IntentDispatcher, tick_interval_ms: :timer.seconds(30)

# Per-meeting intent queue (task 019f70b8 stage 3). `queue_ack_timeout_ms`
# is the ack window: how long a dispatched intent may sit with a runtime
# before the queue gives up on it, marks it `:timed_out` (or
# `:no_ack_spawn_failed` if the runtime tried to ack and was rejected)
# and lets the meeting's next intent through. Overridable per meeting
# via the queue server's `:ack_timeout_ms` opt, which is how tests drive
# it down to hundreds of ms.
#
# Task 019ff292 stage 2 split that into TWO bounds. `queue_ack_timeout_ms`
# is now specifically the RESPONDER's window, and it is anchored at first
# contact — the `"intent_delivered"` receipt a runtime sends when it
# surfaces the intent to the agent's loop, or the first successful
# `intent_ack`. It is deliberately NOT widened: an answer that arrives
# after the meeting has moved on is not an answer, so a wider window
# would hide the latency rather than remove it.
#
# `queue_delivery_timeout_ms` is the outer bound, still anchored at
# transmission, and it is what stops an intent that reached nobody from
# holding the meeting's serial cursor forever. Left unset it derives as
# `Server.default_delivery_multiplier() * queue_ack_timeout_ms`, so
# lowering the ack window (as tests do) lowers both. Setting it equal to
# the ack window would collapse the two bounds back into one and undo
# the fix — see the queue server's moduledoc.
config :platform, Platform.Meetings.IntentQueue, queue_ack_timeout_ms: :timer.seconds(90)

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
# ADR-0043). `project_id` is the Burrow project the scanners file
# their findings under — leave `nil` in dev and set an explicit
# project UUID at deploy time. `cve_scan_stale_days` gates the
# medium/low-severity long-tail rule from the task description.
# The `deploy_audit_*_root` keys let DeployAudit's four probes point
# at tmp fixtures under test. `deploy_audit_core_ops_root` has NO
# default: it names an install's private ops checkout, so it is read
# from DEPLOY_AUDIT_CORE_OPS_ROOT in runtime.exs, and while it is
# unset the env-diff probe reports `{:not_configured, ...}`.
config :platform, Platform.Security,
  project_id: nil,
  cve_scan_stale_days: 30,
  deploy_audit_traefik_root: "~/docker/traefik3/rules",
  deploy_audit_containers_root: "~/.config/containers/systemd",
  deploy_audit_core_ops_root: nil,
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

# Vault workspace-scope rollback switch (task 019f9b13-1fe8 stage 3).
#
# TEMPORARY. `Platform.Vault` refuses every permission on a `"workspace"`-scoped
# credential unless the accessor holds an explicit AccessGrant, because there is
# nothing to check membership against: no `workspaces` table was ever created
# (`priv/repo/migrations/20260314060001_create_vault_tables.exs` still carries
# `# TODO: add foreign key to workspaces once the workspaces table exists`),
# `workspace_id` has no foreign key anywhere in the schema, and org membership
# (ADR-0042) relates users to orgs while vault accessors are agents and
# integrations.
#
# Setting this to `true` restores the old permissive behaviour verbatim — every
# accessor, including a nil one, and every permission — and logs a warning per
# allowed access. It is a roll-forward valve for an undiscovered dependent, NOT
# an operational knob: there is no correct production reason to turn it on, and
# no production code creates a workspace-scoped credential today.
#
# The agreed direction is to delete the `workspace_id` column outright in
# follow-up work. This flag is expected to be removed in the same change. If the
# column is gone and this key is still here, delete it.
config :platform, Platform.Vault, allow_unscoped_workspace_access: false

# The "Connect your AI" first-run screen (task 01a10315 stage 5): the order its
# three options are offered in. The experiment surface; ChatGPT (Codex) first,
# because its device login is the only subscription path that needs no shell.
config :platform, PlatformWeb.ConnectAiLive,
  provider_order: [:codex, :api_key, :claude_subscription]

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

# GitHub webhook HMAC signature enforcement (task 019f9b11). When `true`
# (the default everywhere, including tests), every request to
# `/api/webhooks/github` MUST carry an `X-Hub-Signature-256: sha256=<hex>`
# header that verifies under the project's `deploy_config["webhook_secret"]`
# OR the app-level `GITHUB_WEBHOOK_SECRET`; failures return 401.
# When `false`, verification failures are logged as warnings but the request
# passes through — the rollback safety valve, flippable at runtime without a
# redeploy. See `docs/runbooks/github_webhook_secret.md` for the cutover and
# rollback procedure.
config :platform, :github_webhook_signature_required, true

# Chat first-frame knobs (task 01a17bf4). Read at call time by
# `PlatformWeb.ChatLive.FirstFrame`, so a running dev node can flip them.
# `initial_message_count`: newest top-level messages a default space entry
# puts in the join reply; the connected mount backfills the rest of the
# 50-message window right after it. 10 is measured, not guessed: stage 1's
# before-run (docs/perf/tab-switch-first-frame.data.json) saw at most 3
# message rows in view (1280x800; 2 at 390x844), so ceil(3) + 3 = 6,
# clamped to the 10..25 floor. `deferred_side_state`: enter_space segments
# loaded after the join reply instead of in it. EMPTY BY MEASUREMENT, not by
# omission: the rule is "defer every segment over 3 ms median that the first
# paint does not need", and in both stage 1 (N = 50) and the stage 3
# re-measure (N = 10) the only segment over 3 ms was message_window (24.0 ms,
# then 10.2 ms), which the first paint needs. The next largest was
# chat_list_data at 2.0 ms. See docs/perf/tab-switch-first-frame.data.json.
config :platform, PlatformWeb.ChatLive,
  initial_message_count: 10,
  deferred_side_state: []

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
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --alias:@extensions=./js/extensions/none.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Second entry point: the Excalidraw whiteboard island, built SEPARATELY from
  # js/app.js and fetched on demand by js/lib/load_excalidraw.js.
  #
  # Why a second profile rather than `await import()` inside app.js: the
  # `platform` profile above runs without `--splitting` and without
  # `--format=esm`, and in that configuration esbuild INLINES a dynamic
  # import() into the single output file. `await import("@excalidraw/excalidraw")`
  # from app.js would therefore add the whole island to app.js while looking
  # lazy. Turning on `--splitting --format=esm` would force app.js to become
  # type="module" (layouts.ex) and change load semantics for every existing
  # hook. A second entry point is the smaller, verifiable change.
  #
  # The three --alias flags drop `mermaid`, `cytoscape` and `katex`, which
  # Excalidraw depends on statically only for its mermaid-import feature that
  # Burrow does not surface. They cut the island from ~8.0 MB to ~4.7 MB.
  #
  # --legal-comments=linked emits excalidraw_island.js.LEGAL.txt next to the
  # bundle, preserving the upstream MIT notices. See assets/THIRD_PARTY_NOTICES.md.
  excalidraw: [
    args: ~w(
      js/excalidraw_island.js
      --bundle
      --target=es2022
      --outdir=../priv/static/assets/js
      --conditions=production
      --define:process.env.NODE_ENV="production"
      --alias:mermaid=./js/stubs/excalidraw_mermaid_stub.js
      --alias:cytoscape=./js/stubs/excalidraw_mermaid_stub.js
      --alias:katex=./js/stubs/excalidraw_mermaid_stub.js
      --legal-comments=linked
      --loader:.woff2=file
      --loader:.woff=file
      --loader:.ttf=file
      --loader:.otf=file
      --loader:.png=file
      --loader:.svg=file
    ),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Third entry point: the reaction picker's emoji inventory (~1,850 emoji plus
  # their CLDR search keywords), built SEPARATELY from js/app.js and fetched on
  # demand by js/lib/load_emoji.js.
  #
  # Same reasoning as the `excalidraw` profile above, and it is not a smaller
  # concern than it looks: app.js loads on EVERY page in the product, including
  # /tasks and /inbox, and none of them can open a reaction picker. Because the
  # `platform` profile runs without --splitting and without --format=esm,
  # `await import("../emoji/data.js")` from a hook would be INLINED into app.js
  # — shipping the whole inventory everywhere while reading as lazy in the
  # source. test/no_emoji_data_in_app_bundle_test.mjs asserts on the built
  # bytes, not on the import graph as written.
  #
  # No --loader or --alias flags: the entry point imports one plain .js module
  # and nothing else. No --legal-comments either — the dataset is generated by
  # assets/scripts/generate_emoji_data.mjs from Unicode emoji-test.txt and CLDR
  # annotations, whose terms are recorded in that generator's header, and no
  # third-party code is bundled.
  emoji: [
    args: ~w(js/emoji_island.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Fourth entry point: the remote terminal (task 01a17b17 stage 3). xterm.js and
# its fit addon, plus the WebCrypto session, built SEPARATELY from js/app.js and
# fetched on demand by js/lib/load_terminal.js when the terminal page mounts.
#
# Same reasoning as `excalidraw` and `emoji` above: the `platform` profile runs
# without --splitting, so a dynamic import() from a hook would be INLINED into
# app.js, which loads on every page. test/no_xterm_in_app_bundle_test.mjs asserts
# on the built bytes. xterm's stylesheet is imported by the island and esbuild
# emits it as terminal_island.css next to the bundle.
config :esbuild,
  terminal: [
    args: ~w(
      js/terminal_island.js
      --bundle
      --target=es2022
      --outdir=../priv/static/assets/js
      --legal-comments=linked
    ),
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

# Log-output filter for Phoenix's own request/socket logging (task 01a0d8ba).
# `Phoenix.Logger` prints socket connect params at :info (`REFUSED CONNECTION
# TO ... Parameters:`), which leaked RuntimeSocket `token` values in cleartext.
# Keys are matched as substrings, so this also covers `_csrf_token`,
# `id_token`, `auth_token`, and string values containing `token=`.
# Setting this key REPLACES Phoenix's default `["password"]`, so keep it here.
# "code" (task 01a10882): app login exchange and handoff codes, and the
# PKCE `code_verifier`, arrive as request params. Phoenix matches by
# substring, so this also filters the OIDC callback's authorization code.
# "sealed" (task 01a1261e): the push relay's sealed preview blobs.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "secret",
  "api_key",
  "code",
  "sealed"
]

# Timezone database — Tzdata (IANA rules) backs `DateTime.shift_zone!/2`
# for timezone-aware cron triggers (task 019f70e9 stage 6). Without this
# only `Etc/UTC` shifts work; named zones like `America/Chicago` fail.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# `external_group`/`external_claim` (rbac-external-users M2 stage 1): the
# STATIC id-token claim NAME + value that marks a login as an external
# user. Read-only token consumption — ADR-0004 (no outbound IdP call).
# `external_group` is deliberately UNSET here (task 01a14dd9): runtime.exs
# threads OIDC_EXTERNAL_GROUP, which has no default. A nil group flags nobody
# (`Platform.OIDC.external_claim?/1`), so an install with external users MUST
# set it.
config :platform, :oidc,
  http_adapter: Assent.HTTPAdapter.Httpc,
  external_claim: "groups"

# App-surface host fence (task 019fcf22 stage 4). `:on` makes
# `PlatformWeb.Plugs.HostSurface` halt with 404 when a request for a route in
# the default (app) scope arrives on a `chat.` or `meet.` prefixed host.
#
# STATED CONSEQUENCE: this breaks an internal-user habit. Before the flip an
# internal user who landed on a `chat.` URL could navigate the entire app from
# there without noticing; after it, every non-chat path on that host is a 404.
# That is the intent of the task.
#
# ROLLBACK is this one line — set it back to `:off`. Nothing else in stages
# 1-3 has to be touched, which is why enforcement is a flag at all.
config :platform, :host_surface_enforcement, :on

# Tenant display priority: deliberately UNSET here (task 01a14dd9).
# `Platform.Tenancy.tenant_priority/0` reads `:tenant_priority` at runtime;
# runtime.exs threads TENANT_ORG_PRIORITY when an install sets it, and
# otherwise every tenant sorts slug-alphabetically after the root. A literal
# default here named one install's tenants in every install's config.

# Root org slug: deliberately UNSET here (task 01a116de). Every code path that
# needs "the org a write lands in when the caller named none" resolves it
# through `Platform.Tenancy.root_org_slug/0`, which reads this key when an
# install sets it (runtime.exs threads ROOT_ORG_SLUG) and otherwise falls back
# to the slug of the structural root org (`parent_org_id IS NULL`). A literal
# default here named an org that a fresh install does not have.

# Auto-admin email domain (task 01a081c2 stage 2, renamed + de-defaulted in
# task 01a068f6 stage 1). `derive_role_from_email/1` reads this through
# `Platform.Tenancy.root_org_admin_email_domain/0` on every user INSERT and
# every email-change UPDATE. An address whose host equals this domain is
# auto-promoted to admin on the root org.
#
# Deliberately UNSET here: this file is the shared base every environment
# (including a stranger's fresh production install) imports from, and
# task 01a068f6 exists precisely because install-specific defaults living
# here make every fresh Burrow install come up implicitly owned by one
# client's org — an install that never sets ROOT_ORG_ADMIN_EMAIL_DOMAIN must
# get `nil` (nobody auto-admined), not a silently inherited domain. The test
# environment pins this key in `config/test.exs` as a per-environment
# convenience override, not a shared default.
#
# Until task 01a081c2 the domain was a literal regex compiled into
# tenancy.ex, which made one install's email addresses automatic admins on
# somebody else's Burrow install. runtime.exs threads the per-install value
# via ROOT_ORG_ADMIN_EMAIL_DOMAIN, and a BLANK value there disables
# auto-admin entirely even when dev/test pins a default above. See the
# accessor's @doc for why blank must not fall back to an environment
# default.

# Build-time modules (ADR 0055, task 01a0ee08). Core never sets
# `config :platform, :extensions`: an unset key means no modules, which is
# this project's own build (the without-modules build). A with-modules
# release host, or a module's own config for its tests, sets it. Core reads
# the list only through `Platform.Extensions`, per call.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
