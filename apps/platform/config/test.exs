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
       "e5074d4cf86bd52a9a517af9c2a247d841cb1f2bdf324b0033111d6cc25f9298"

# Stack v2 (task 019f487d, ADR 0045) — Platform.Tasks.Stacks.DepInference
# resolves its LLM adapter from application env at call time. Tests
# swap in a process-dictionary-driven stub so no HTTP round trip is
# made and each case controls the "LLM" response deterministically.
config :platform, :dep_inference_adapter, Platform.Tasks.Stacks.DepInference.StubAdapter
