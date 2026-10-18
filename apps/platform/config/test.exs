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
  # Sized to ExUnit's concurrency, not a fixed 10 (task 01a0d265,
  # 2026-09-24 seed-A run: 19 failures — 14 setup `start_owner!` MatchErrors
  # and 5 in-test linked-preload crashes, every one a `:queue_timeout`
  # / "dropped from queue").
  #
  # ExUnit's default `max_cases` is `System.schedulers_online() * 2`
  # (elixir `lib/ex_unit/lib/ex_unit.ex:348` docs — "defaults to
  # `System.schedulers_online * 2`" — and the `defp put_max_cases/1`
  # fallback) and this repo does not override it (test/test_helper.exs), so
  # the moon rig (16 schedulers) runs 32 tests in parallel. EVERY test holds
  # ONE pool connection for its whole lifetime (`Sandbox.start_owner!` in
  # test/support/data_case.ex:42 and test/support/conn_case.ex:61), so a
  # pool below max_cases starves the surplus owners and DBConnection's
  # adaptive queue drops their checkouts. `schedulers_online() * 2 + 8`
  # covers max_cases PLUS 8 spare connections that absorb the Class-3
  # leak-pinned connections (background tasks — Ecto parallel preloads,
  # fire-and-forget lifecycle edges — still using a connection when their
  # owner exits) during teardown; max(..., 24) keeps that floor on any rig.
  # ExUnit max_cases itself is NOT overridden here — suite concurrency and
  # wall time stay as they are.
  # queue_target/queue_interval deliberately UNTOUCHED — capacity, not
  # checkout patience, is the fix of record here (a documented queue bump
  # is the fallback only if evidence later demands it).
  # test/platform/test_env_pool_config_test.exs fails the suite if this is
  # reverted (asserts pool_size >= max_cases + 8, read from the live
  # runtime).
  pool_size: max(System.schedulers_online() * 2 + 8, 24)

# Auto-admin email domain (task 01a068f6 stage 1): `config/config.exs`
# deliberately carries no default for `:root_org_admin_email_domain` (a
# fresh production install must not implicitly inherit any one install's
# domain). This is a test-only pin so the suite's `@acme.test` fixtures
# (`tenancy_test.exs` et al.) derive `:admin` from the email domain. The
# `.test` TLD is reserved (RFC 2606), so it can never name a real install.
config :platform, :root_org_admin_email_domain, "acme.test"

# Root org identity (task 01a068f6 stage 2; renamed to a neutral fixture in
# task 01a116de stage 4): `20260519143620_seed_root_orgs` reads
# `ROOT_ORG_SLUG`/`ROOT_ORG_NAME` from the OS environment directly (a
# migration can't assume `config/runtime.exs` ran, see that file's
# moduledoc) and defaults to "root"/"Root Org" when neither is set. The test
# suite asserts against a fixed root slug in a few hundred places
# (`Tenancy.get_org_by_slug!("acme")`, `TenancyFixtures.acme_org_id/0` and
# friends). CI's Postgres service container is empty on every job, so
# without this pin `mix test`'s own `ecto.create`/`ecto.migrate` would seed
# "root" and every one of those lookups would raise `Ecto.NoResultsError`.
# `System.put_env/2` here runs in the SAME OS process that later executes
# the migration's `System.get_env/2` read (Mix loads config before running
# `ecto.migrate`), so a fresh test database seeds "Acme"/"acme".
# `test/platform/test_root_org_identity_test.exs` asserts the seeded row, so
# a database migrated under an older pin fails loudly instead of passing on
# a stale root.
#
# Migrations that pin values by a literal historical slug (the shipped org
# colours in `20260911220000_add_color_to_orgs` and
# `20260921190000_add_color_lightness_to_orgs`) do not touch this root;
# their tests insert the slug they exercise.
System.put_env("ROOT_ORG_SLUG", "acme")
System.put_env("ROOT_ORG_NAME", "Acme")

config :platform, :oidc,
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  issuer: "https://issuer.example.com",
  app_url: "http://www.example.com",
  strategy: Platform.TestOIDCStrategy,
  http_adapter: {Assent.HTTPAdapter.Mint, []}

# Per-OS-process so two `mix test` runs on one host never share (and never
# delete) each other's blobs. config/runtime.exs leaves this key alone in
# the test env, so this value is the one every LocalDisk read resolves to
# unless a test claims its own root via Platform.Chat.AttachmentStorage.Root.
config :platform,
  chat_attachments_root:
    Path.join(System.tmp_dir!(), "platform_test_chat_uploads-#{System.pid()}"),
  skip_attachment_storage_check: true,
  attachment_signing_key: "test-attachment-signing-key-0123456789abcdef",
  meeting_guest_signing_key: "test-meeting-guest-signing-key-0123456789abcdef",
  meeting_calendar_signing_key: "test-meeting-calendar-signing-key-0123456789abcdef",
  meeting_guest_host: "meet.test.local"

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

# Meetings summary config — injected, NOT read from priv/meetings.yml.
#
# `priv/meetings.yml` is gitignored (.gitignore:33), so it is absent in CI
# and present-with-arbitrary-contents on developer machines. When a dev has
# a local provider configured (e.g. `provider: ollama` pointing at a LAN
# box), `Meetings.Config.summary/0` resolves to that provider and the
# summarizer's legacy path makes a REAL HTTP call instead of short-circuiting
# on `{:error, :no_summary_provider_configured}`. That made four tests fail
# locally and pass in CI — the suite became a function of the host.
#
# Pinning the config here means the test run never touches the filesystem
# for meetings config. A test that needs a different provider must set this
# key explicitly (and restore it), not rely on what happens to be on disk.
config :platform, :meetings_summary, %{
  provider: :none,
  model: nil,
  base_url: nil,
  api_key_env: nil,
  max_tokens: 2048,
  temperature: 0.3
}

# File catalog cards (task 01a0008c) — same reasoning as the block above,
# one step earlier. `Platform.Files.Cataloger` already defaults to
# `provider: :none`, so this is not load-bearing today; it is pinned
# explicitly so that the day somebody adds a YAML or env fallback to
# `llm_config/0`, the test suite does not quietly start making real HTTP
# calls on whichever machine has a provider configured. A test that needs
# a provider wires a stubbed one per-test and restores it.
config :platform, :file_cards, %{
  provider: :none,
  model: nil,
  base_url: nil,
  api_key_env: nil,
  max_tokens: 700,
  temperature: 0.2
}

# TaskRouterWatcher — do NOT boot the global singleton in test.
#
# Task 019fb978 stage 1 measured a full-suite run and found 212 sandbox
# ownership violations, 145 of them (68%) raised by this one process. The
# violations do not fail the test that causes them: each force-disconnects a
# pooled connection, and whichever unrelated test happens to be holding that
# connection dies instead. That is the "1 failure per run, green on --failed"
# signature this flake has always had.
#
# More guarding cannot fix it. `SandboxGuard`'s own preconditions are Repo
# calls (`connection_owned?/0` checks a connection out; `*_row_visible?/1`
# runs a SELECT EXISTS), so `guarded/3` rescues AFTER Postgrex has already
# killed the connection — it appears in 289 of the violation stacks. The
# hazard is the process existing at all during tests that are not about it.
#
# So it is gated off here, mirroring the other Repo-touching singletons
# (:start_meeting_notifier, :start_attention_router, the sweepers and
# purgers). It is removed from `supervised_with_repo` in
# test/support/data_case.ex, and the three files that need a LIVE watcher
# start their own per-case instance with `start_supervised!/1` and allow it
# onto their own connection. That is strictly more correct than the global:
# per-test lifecycle, no cross-test leakage.
#
# Note for task 019fb977: watcher teardown/respawn behaviour is no longer
# observable through the global singleton in test — its tests must
# `start_supervised!` a watcher too.
config :platform, :start_task_router_watcher, false

# TaskRouterWatcher autonomous reconcile tick.
# Still set for the per-case instances the watcher's own tests start: a tick
# firing after the owning test exits would crash that instance. Its 5-minute
# self-firing `:reconcile` tick does Repo work that
# isn't fully rescued in `handle_info(:reconcile)`, so a tick that fires
# after the owning test has exited crashes the watcher. That crash is only
# catastrophic because of the restart loop in `init/1` — now guarded by
# `TaskRouterWatcher.boot_reconcile/0`, the real fix. Disabling the
# self-timer here removes the trigger too (it otherwise fires only during a
# slow full run, e.g. CI), mirroring how the other Repo-touching singletons
# (SummarizerSweeper, SecuritySweeper, the purgers) are disabled in test and
# driven directly from their test files. Reconcile logic stays covered — the
# watcher's tests send `:reconcile` synchronously inside their own sandbox.
# Production defaults to `true` (see TaskRouterWatcher.schedule_reconcile/0).
config :platform, :task_router_watcher_reconcile, false

# SpacePurger (task 019e95ea stage 3): tests call `sweep/0` directly
# inside the DataCase sandbox instead of racing a global daily ticker.
config :platform, :start_space_purger, false

# Experiments MailSubscriber (task 01a0d415 stage 3): tests start it with
# start_supervised/1 inside their own sandbox. Left on at boot it would label
# every mail test's inbound row from outside every sandbox.
config :platform, :start_experiments_mail_subscriber, false

# Canvas body search backfill (task 01a07402 stage 3): tests call `run/1`
# directly inside the DataCase sandbox. Left on at boot it would run against
# the real test database from outside every sandbox, indexing rows the suite
# is about to roll back and racing the tests that assert on absent index rows.
config :platform, :start_canvas_search_backfill, false

# Burrow Docs seed (task 01a10a44 stage 1): tests call `sync/0` directly
# inside the DataCase sandbox. Left on at boot it would write burrow/page rows
# into the real test database from outside every sandbox.
config :platform, :start_burrow_docs_seed, false
# Task 01a10322 stage 6: tests call Platform.Chat.DefaultSpace.ensure/0 directly.
config :platform, :start_default_space_seed, false

# ContainerPurger (task 019f4eaa stage 4): tests call `sweep/0` directly
# inside the DataCase sandbox instead of racing a global daily ticker.
config :platform, :start_container_purger, false

# DeployMergeReconciler (task 019fa63a stage 6): tests call `sweep/1`
# directly with a stub runner. Left running it would shell out to `gh`
# every five minutes from a process outside the Ecto sandbox.
config :platform, :start_deploy_merge_reconciler, false

# FilePurger (task 019f7cb0 stage 3): tests call `sweep/1` directly
# inside the DataCase sandbox instead of racing a global daily ticker.
config :platform, :start_file_purger, false

# PrototypePurger (task 01a1316b-4e46 stage 1): tests call `sweep/1` directly
# inside the DataCase sandbox instead of racing a global daily ticker.
config :platform, :start_prototype_purger, false

# InsightPurger (task 01a13867 stage 1): tests call `sweep/1` directly
# inside the DataCase sandbox instead of racing a global hourly ticker.
config :platform, :start_insight_purger, false

# InsightDisseminator (task 01a13867 stage 3): tests call `run/1` directly
# inside the DataCase sandbox instead of racing a global daily ticker.
config :platform, :start_insight_disseminator, false

# CatalogEmitter (task 01a0008c stage 3): a globally-booted instance would
# subscribe to `[:platform, :files, :ingested, :stop]` for the whole suite
# and then run Repo queries from a process that owns no sandbox
# connection — every existing ingest test would start force-disconnecting
# pooled connections. `Platform.Files.CatalogEmitterTest` starts its own
# instance under `start_supervised/1`, which attaches its own handler and
# detaches it on exit.
config :platform, :start_catalog_emitter, false

# M1 stage 4 (ADR-0041): Platform.Responsibilities.Registry runs
# `register_all/1` on init, which writes to the DB. Tests use the
# DataCase sandbox and start their own per-case Registry instance with
# a unique :name so each test owns its own connection + scope.
config :platform, :start_responsibilities_registry, false

# M6 stage 1 (ADR-0041): Platform.Responsibilities.Router walks the
# registry on init (DB read). Tests start per-case instances under the
# DataCase sandbox; see `Platform.Responsibilities.RouterTest`.
config :platform, :start_responsibility_router, false

# M8 stage 6 (ADR-0041): Platform.Responsibilities.CutoverMonitor
# attaches telemetry handlers on init. Tests start per-case instances
# with their own :name so the production singleton isn't claimed.
config :platform, :start_cutover_monitor, false

# T3 (ADR-0041): tests start their own Platform.Org.Wiki.Indexer per case
# (so DataCase sandbox owns the Repo connection and tests don't fight a
# real subscriber). Production defaults to true via Application.start/2.
config :platform, :start_wiki_indexer, false

# T6 (ADR-0041): MeetingHistorianHandler subscribes to meeting PubSub at
# init; tests start their own per case for sandbox ownership.
config :platform, :start_meeting_historian_handler, false

# Meeting notifications (task 019edbc1): MeetingNotifier subscribes to
# meeting PubSub at init and fans out push payloads on :meeting_started.
# Tests start their own instance and inject a recorder via
# `:notifications_module` (see meeting_notifier_test.exs).
config :platform, :start_meeting_notifier, false

# Meeting Producer runtime (task 019f2452 stage 3): tests start their own
# IntentClassifier per case for DataCase sandbox ownership.
config :platform, :start_meeting_intent_classifier, false

# Same-speaker utterance debounce. `0` = deliver every chunk
# synchronously inside `handle_info/2`, which is what keeps the
# broadcast-then-`assert_receive` tests deterministic. The merge itself
# is covered by cases that pass an explicit `debounce_ms:` to
# `start_link/1`.
config :platform, :intent_classifier_debounce_ms, 0

# IntentDispatcher (task 019f2452 stage 4): tests start their own
# per-case instance for DataCase sandbox ownership. The
# `sweep_stalled/0` callback is safe to call even without a running
# dispatcher — it only reads the queue Registry and re-broadcasts — so
# tests exercising it don't need to boot the GenServer.
config :platform, :start_meeting_intent_dispatcher, false

# Meetings master switch (task 019fb955 stage 2). `Meetings.Config.enabled?/0`
# otherwise falls through to reading the `MEETINGS_ENABLED` OS environment
# variable, which would make the suite a function of the host — the same
# hazard the injected `:meetings_summary` key above exists to close. Off for
# the same reason `:start_meeting_notifier` is off: the boot-time sender seed
# would otherwise insert outside any test's sandbox ownership. Tests that need
# it on flip it per-test with `Application.put_env` + `on_exit` restore.
config :platform, :meetings_enabled, false

# Email module master switch (task 01a0cf21 stage 1). Same reasoning as
# :meetings_enabled above: without the injected key `Mail.Config.enabled?/0`
# reads `MAIL_ENABLED` from the host. Tests that need the module on flip it
# with `Application.put_env` + `on_exit` restore in async: false modules.
config :platform, :mail_enabled, false

# External feedback (task 01a11ec3 stage 2). Pinned off so the suite is not a
# function of the host's FEEDBACK_POLICY (config/runtime.exs skips the key
# under :test). Both publisher adapters go to `Req.Test` stubs named after
# their modules, so no test can reach a broker or GitHub. Tests that need the
# capability flip `:feedback_policy` per-test and restore it on exit.
config :platform, :feedback_policy, "disabled"

config :platform, Platform.Feedback.GithubPublisher,
  adapter: Platform.Feedback.GithubPublisher.Broker,
  repository: "Startup-Suite/core",
  broker_url: "https://feedback-broker.test",
  github_api_url: "https://github-api.test"

config :platform, :feedback_broker_req_options,
  plug: {Req.Test, Platform.Feedback.GithubPublisher.Broker}

config :platform, :feedback_github_req_options,
  plug: {Req.Test, Platform.Feedback.GithubPublisher.GithubApp}

# Intake (task 01a11ec3 stage 3): dispositions off by default so no test
# reaches the broker stub unless it opts in with a fake adapter.
config :platform, Platform.Feedback.Intake, disposition_mode: "none"

# Install-to-install federation master switch (task 01a0d90f stage 2, ADR
# 0054). Same reasoning as :mail_enabled above: without the injected key
# `Federation.Peers.Config.enabled?/0` reads `PEER_FEDERATION_ENABLED` from
# the host. Tests that need it on flip it per-test and restore it on exit.
config :platform, :peer_federation_enabled, false

# Peer federation HTTP never reaches the network in tests (task 01a0d90f
# stage 3): every `Federation.Peers.Client` request goes to the `Req.Test`
# stub of that name, and the SSRF guard's DNS lookups go to a static map that
# is empty here, so a test that forgets to stub one fails as
# `:unresolvable` instead of querying real DNS. Tests that need an address
# put their own resolver and restore this one on exit.
config :platform, :peer_federation_req_options, plug: {Req.Test, Platform.Federation.Peers.Client}

config :platform, :peer_federation_resolver, %{}

# Member avatar fetches for the app route (`Platform.Accounts.UserAvatarCache`):
# every request goes to the `Req.Test` stub of that name, and no host resolves
# unless a test stubs it, so nothing reaches the network.
config :platform, :user_avatar_req_options, plug: {Req.Test, Platform.Accounts.UserAvatarCache}
config :platform, :user_avatar_resolver, %{}

# APNs never reaches Apple in tests (task 01a10882 stage 2): every
# `Platform.Push.APNs` request goes to the `Req.Test` stub of that name.
config :platform, :apns_req_options, plug: {Req.Test, Platform.Push.APNs}

# The APNs transport-error backoff (default ~150/500/1500 ms) never sleeps for
# real in tests: same number of retries, zero delay.
config :platform, :apns_retry_backoff_ms, [0, 0, 0]

# FCM never reaches Google in tests (task 01a10d8e stage 1): both the OAuth
# token exchange and `messages:send` go to the `Req.Test` stub named
# `Platform.Push.FCM`, and the transport-error retry schedule does not sleep.
config :platform, :fcm_req_options, plug: {Req.Test, Platform.Push.FCM}
config :platform, :fcm_retry_backoff_ms, [0, 0, 0]

# Push relay (task 01a1261e stage 2): every install-side relay request goes to
# the `Req.Test` stub named `Platform.Push.Relay`, and its transport-error
# retry schedule does not sleep.
config :platform, :push_relay_req_options, plug: {Req.Test, Platform.Push.Relay}
config :platform, :push_relay_retry_backoff_ms, [0, 0, 0]

# Sign-in users page (task 01a113ea stage 1). Same reasoning as :mail_enabled
# above: without the injected key `SignInAdmin.Config.enabled?/0` reads
# `POCKET_ID_ADMIN_ENABLED` from the host. And pocket-id is never reached in
# tests: every `SignInAdmin.PocketId` request goes to the `Req.Test` stub of
# that name. Tests that need the page on flip the switch (and inject
# :sign_in_admin_url / :sign_in_admin_api_key) and restore them on exit.
config :platform, :sign_in_admin_enabled, false
config :platform, :pocket_id_req_options, plug: {Req.Test, Platform.SignInAdmin.PocketId}

# Email send path (task 01a0cf21 stage 2): tests never reach SMTP. The
# recording adapter sends `{:mail_test_adapter, email, config}` to the calling
# process so a test can assert WHICH relay and username a send used;
# `config/runtime.exs` skips the SMTP adapter under :test.
config :platform, Platform.Mail.Mailer, adapter: Platform.Mail.TestAdapter

# Email read path (task 01a0cf21 stage 3): tests never reach an IMAP server.
# The in-memory fake lives in test/support/fake_imap_client.ex. A poller that
# a test starts waits an hour before its first tick unless the test says
# otherwise, so lifecycle tests do not race a poll.
config :platform, Platform.Mail.Inbound,
  poll_ms: 3_600_000,
  initial_delay_ms: 3_600_000,
  client: Platform.Mail.Imap.FakeClient

# LiveKit webhook signature enforcement (task 019f3312 stage 2): tests
# keep this off so the ~28 existing controller tests don't need to mint
# a JWT per payload. The signature-verification plug's own test file
# flips this per-test with `Application.put_env` + `on_exit` restore.
config :platform, :livekit_webhook_signature_required, false

# GitHub webhook secret (task 019f9b11): the app-level fallback candidate the
# test suite signs with.
config :platform, :github_webhook_secret, "test-github-webhook-secret"

# SummarizerSweeper (task 019f2566 stage 2): tests start their own
# per-case instance with shortened intervals so the sweep runs inside
# an ExUnit case's DataCase sandbox and doesn't share state across
# tests.
config :platform, :start_summarizer_sweeper, false

# CandidateSweeper (task 01a03fba stage 3). Off in test: it is a
# one-second tick that mints tasks and canvases, so an ambient instance
# would fire other suites' candidates from outside their DataCase
# sandbox. Countdown tests either call `CandidateSweeper.sweep/1`
# directly — the timing assertions need an injectable `now`, not a real
# 30-second wait — or start their own named instance.
config :platform, :start_candidate_sweeper, false

# StallRegistry (task 019f2566 stage 6): tests start their own per-case
# instance so registry state is isolated per test — otherwise a callback
# registered by one test leaks into a sibling case's sweep tick.
config :platform, :start_stall_registry, false

# Lifecycle StepRegistry (task 019fe1b6 stage 1): tests start their own
# per-case instance so a step registered by one test cannot leak into a
# sibling case's lookups.
#
# The BOOT gate stays false — every `:start_*` gate must, and the start-flag
# audit enforces it. `test/test_helper.exs` instead starts one registry under
# the default name, outside the supervision tree, seeded with the shipped
# allowlist and nothing else. Needed since task 019fe1b7 stage 3: a shipped
# default step now exists on every terminal edge, so a case that merely moves
# a task to `done` resolves a step name and asks the registry for it, and a
# `GenServer.call` to an unregistered name EXITS rather than raises — which
# the fire point's `rescue` does not catch.
config :platform, :start_lifecycle_step_registry, false

# Security Sweeper (task 019f3e8e-4406 stage 2, ADR-0043): tests start
# their own per-case instance with `respect_cadence: false` so
# `sweep_now/1` always walks all four scanner keys inside the ExUnit
# DataCase sandbox. Global singleton would race sandbox teardown.
config :platform, :start_security_sweeper, false

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

# The tool-call ledger (task 01a114a8 stage 1) writes inline in tests, under
# the sandbox owner, instead of in a Platform.TaskSupervisor child. The
# body is identical and still rescues everything; see ToolCallLedger.
config :platform, :tool_call_ledger_sync, true

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
#
# Memory-feedback stage 2 re-pin (task 019f6381, 2026-07-16): wired
# `Platform.MemoryFeedback.record_edit/1` and `record_delete/1` calls
# into `upsert_context_file/3` and `delete_file/2` write paths so
# every mutation lands a training-corpus row atomically with the
# mutation itself. `delete_file/1` gained an `opts` arg for
# `:editor_id`/`:reason` (kept back-compat via default `[]`). Legit
# scope for this task; T7 still retires the module.
#
# Memory-feedback stage 6 hotfix (task 019f6381, 2026-07-16): the
# org-memory LiveView delete path was still calling `Wiki.delete_page/2`
# (no capture), so its deletes bypassed the feedback ledger. Fix
# rerouted the LiveView through `Context.delete_file/2` (the tested
# capture path) and added a `Phoenix.PubSub.broadcast/3` on the
# `"org_wiki:index"` topic to preserve the T3 indexer semantics
# `Wiki.delete_page/2` provided. Legit scope; T7 still retires the
# module.
config :platform,
       :t2_context_sha256_t1_head,
       # bumped by memory-feedback stage 6 hotfix (main) + user-archival stage 2
       # (task 019f671f): `resolve_authors/1` now passes `include_archived: true`
       # to `Accounts.get_users_map/2` so historical memory-entry authors still
       # resolve after the author is archived. Rehash absorbs both edits.
       #
       # Bumped again by Historian-dreaming task 019f70e9 stage 2:
       # `Platform.Org.Context.upsert_context_file/3` now calls the
       # `Platform.Memory.Proposals.ingest_from_journal/3` sweep hook on
       # journal writes so `<synthesis-proposal>` blocks emitted by the
       # dreaming loop persist as `memory_proposals` rows. Sweep hook runs
       # outside the write transaction; journal remains source of truth.
       # T5 still retires this module — the hook moves with it.
       #
       # Bumped again by task 019fa129 stage 4 (Repo-lookup boundary sweep):
       # `Platform.Org.Context.get_file_by_id/1` was a bare
       # `Repo.get(WikiPage, id)` reachable from the memory MCP tools with a
       # caller-supplied page id, so a non-UUID id raised
       # `Ecto.Query.CastError` instead of returning nil. It is now guarded by
       # `Platform.UUID.valid?/1`. One line, no behaviour change on the happy
       # path, and it is exactly the class the three sha256 guards above were
       # NOT written to catch. Bumping the constant is the protocol those
       # guards document ("update this constant in the same commit"); T5 still
       # retires the module.
       #
       # Bumped again by the viewer-scope choke-point task, stage 2: the
       # private `filter_org/2` in this module was byte-identical to a
       # second copy in `Platform.Org.Wiki.Search`, and both defaulted an
       # empty org allow-list to the UNFILTERED queryable. Both copies are
       # deleted; the module now maps the `:org_id` opt onto the shared
       # `Platform.Tenancy.scope/3`, where `[]` fails closed. `nil` is
       # unchanged on purpose — it is the absence of a question, not a
       # resolved "no orgs" answer. Net deletion; T5 still retires this
       # module.
       #
       # Bumped again by task 01a10a44 stage 2 (Burrow Docs): the domain
       # backstop for the product-owned `burrow/` namespace.
       # `upsert_context_file/3`, `upsert_file/1,2` and `delete_file/2`
       # refuse a `burrow/` key (and a row an alias resolves to one) with
       # `{:error, :product_owned}` unless the caller passes the
       # `:product_docs` opt, which only `Platform.Org.BurrowDocs` does.
       # `upsert_file` gains an optional opts arg so the opt can reach the
       # guard. Every non-burrow write behaves exactly as before.
       #
       # Bumped again by task 01a13867 stage 1 (Insights): the journal sweep
       # hook now calls `Platform.Memory.Insights.ingest_from_journal/3`
       # instead of `Proposals.ingest_from_journal/3`, so `<synthesis-insight>`
       # blocks are ingested and `<synthesis-proposal>` blocks no longer are.
       # Alias, two calls, one renamed private fn and their comments; the
       # hook still runs outside the write transaction. T5 still retires
       # this module.
       "efb597fd9b981c7c36fa163ed360dc9fee2d8b2ba8b92ca7fe464e83df41aba1"

# Stack v2 (task 019f487d, ADR 0045) — Platform.Tasks.Stacks.DepInference
# resolves its LLM adapter from application env at call time. Tests
# swap in a process-dictionary-driven stub so no HTTP round trip is
# made and each case controls the "LLM" response deterministically.
config :platform, :dep_inference_adapter, Platform.Tasks.Stacks.DepInference.StubAdapter

# Branch provisioning (task 01a001ac). `TaskRouter` pre-creates
# `task/<uuid>` on every execution-phase dispatch, and the default runner
# shells out to `gh`. Left unpinned, the whole suite makes live GitHub
# calls about fixture repositories that do not exist. Tests that mean to
# assert provisioning pin their own stub through the same key.
config :platform, :branch_provisioner, runner: Platform.Tasks.BranchProvisioner.NoopRunner

# The durable candidate mirror is FATAL in test (task 01a04a36).
#
# `Platform.Meetings.IntentQueue.Server` mirrors every queue write into
# `meeting_candidates` through a wrapper that rescues, catches exits and
# logs. In production that is correct — the durable record is worth less
# than the live meeting. In a test run it is the opposite of correct: it
# converts "this suite wrote nothing" into "this suite passed". Two
# suites were found in that state (tasks 01a049f9 and 01a04a36-643d),
# and neither failed a single assertion while doing it.
#
# Armed here, the same failure raises `IntentQueue.MirrorError` instead.
# `intent_queue/mirror_fatality_test.exs` asserts this line is in force
# and that the one case which legitimately needs it off — the
# production-posture case in `server_persistence_test.exs` — is the only
# place that turns it off. That same describe block is also where the
# route the swallow opens is covered: a skeleton the mirror could not
# fill is reaped `:unclassified` by `CandidateSweeper` (task 01a06638).
config :platform, :intent_queue_mirror_fatal, true

# Task 01a10322 stage 7: the native no-reply watchdog is off, so a watch armed
# by one test never fires a verdict into a later one. Its tests turn it on.
config :platform, :native_reply_watchdog_ms, false
