# Slowest-tests baseline (task 01a17ac3, stage 1)

This is the measurement that sets the scope of the suite-cost audit. Later
stages are chosen from it. Treat it as a snapshot, not a contract.

## What was measured

- Commit `08ec6ba56`: main at `709747d4c` (PR #3, hosted runners, 6-way
  `--partitions` sharding, deps/_build cache) plus the reporting formatter
  only. No test was changed in this run.
- Hosted CI run `40432578697` (draft PR #4), `ubuntu-latest`. **Sharded**
  `Test`: 6 partitions of the main `mix test --include slow` pass, plus
  `Test (checks)`.
- First pass green on every shard: no `initial mix test failed` warning, so
  the serial retry did not run. Per-shard results: 4157, 4621, 4137, 4161,
  4439 and 3911 passed (doctests included). Total 25,426 passed, 3 skipped,
  6 excluded. `Test (checks)` ran 3 `isolated_beam` tests and the 6-test
  same-BEAM pair.

### How the lists were collected (not `--slowest`)

ExUnit's `slowest:` and `slowest_modules:` options force `trace: true`, which
forces `max_cases: 1` and an `:infinity` timeout. That happens whether the
options are passed to `mix test` on the command line or set with
`ExUnit.configure/1` in `test_helper.exs`. A later `ExUnit.configure(trace:
false)` does not undo it. This was probed on Elixir 1.19.5. A `--slowest` run
therefore times a serialized suite, and that is not the suite CI runs. One
local run with `--slowest` took 1,035 s (240 s async, 795 s sync), against
906 s for the same suite run normally.

The lists below come from `Platform.SuiteCostFormatter`
(`apps/platform/test/support/suite_cost_formatter.ex`). It is attached from
`test_helper.exs` when `CI` is set. It only listens and leaves `max_cases`
alone. Each shard prints its own top 100 tests and top 50 modules (the
`[suite-cost]` lines in the job log). The tables merge the six shards. The
global top N is always contained in the union of the shards' top N, so the
merge is exact.

## Wall times (before)

| job | job wall | test step |
|---|---|---|
| Test (shard 1) | 5m43s | 3m57s (ExUnit run 233.7 s: 33.7 async / 200.0 sync) |
| Test (shard 2) | 4m50s | 3m12s (189.1 s: 48.1 / 141.0) |
| Test (shard 3) | 5m11s | 3m11s (186.8 s: 76.8 / 110.0) |
| Test (shard 4) | 7m08s | 4m54s (289.8 s: 70.3 / 219.5), the slowest shard |
| Test (shard 5) | 5m10s | 3m21s (197.9 s: 73.0 / 124.9) |
| Test (shard 6) | 6m29s | 4m14s (250.4 s: 38.4 / 211.9) |
| Test (checks) | 7m22s | isolated BEAM 3m30s, same-BEAM pair 9 s |
| **Test (aggregate)** | **7m29s** from run start to the `Test` job's end | |
| Test (with Play), control | 19m01s | module tests 33 s (the rest is compile and the cache save) |
| Test (with Social), control | 3m58s | module tests 1m45s |

Summed over the six shards, the main pass takes 22m49s of test-step time and
1,347.7 s of ExUnit run time. Of the ExUnit time, 1,007.4 s (74.7%) is the
sync phase, meaning `async: false` modules running one at a time, and 340.3 s
is the async phase.

`Test (with Play)` and `Test (with Social)` run `apps/game_stream` and
`apps/social`, not `apps/platform/test`. They are controls only. Nothing in
this task is expected to move them.

## Falsifier verdict

- (a) "hosted Test under 10 min": **TRUE**. The sharded `Test` finishes in
  7m29s on the critical path, and the slowest shard's test step takes 4m54s.
  The unsharded equivalent is the 22m49s summed above. The coordinator
  measured 36–39 min for hosted `Test` unsharded.
- (b) "less than ~25% of test-step time in the categories": **FALSE**.
  Serial `async: false` module time alone is 74.7% of summed ExUnit run time
  (1,007 of 1,348 s). Within the async phase, the longest modules are source
  scans: `extension_boundary_test` 55 s, `repo_lookup_boundary_test` 49 s,
  `install_identity_guard_test` 48 s, `lazy_html_selector_guidance_audit_test`
  37 s and `adr_citation_audit_test` 34 s. 29 of the top 50 modules are
  source scans. Sleep-bearing tests on the top 100 sum to 37.6 s, and almost
  all of that is real-timer waiting that is itself the property under test
  (see below).

Because (a) is true, the ticket's own rule applies: re-scope stages 2–4 to
correctness (dead and brittle tests) rather than speed.

## Sleep-bearing tests on the slow list

There are 8 of them, all `async: false`:

- `adversarial_test.exs:681`, `:601`, `:615`, `:627`: the sleep is the
  measurement window for a rate or budget limit. Removing it removes the
  assertion. `:681` is also a known hosted flake (CPU wall budget). Not
  touched.
- `mask_names_chip_test.exs:184`: waits for a real clock to pass a stored
  expiry. Moving the record into the past instead would no longer catch a
  chip that reads the clock against the mount-time instant. Not touched.
- `meeting_ask_floor_press_test.exs:334`,
  `meeting_ask_transcript_feed_test.exs:209`, `press_card_test.exs:266`:
  each slept `PressWindow.release_grace_ms()` (3 s) plus a margin, then
  asserted. Converted in stage 1 to wait on the event itself, with the same
  deadline. The real 3 s timer still has to fire. The saving is the margin
  only, about 1 s across the three files.

## Top 100 tests (hosted, merged across shards)

`(sleep)` marks a test whose body calls `Process.sleep` or `:timer.sleep` at
`08ec6ba56`. Test names are quoted verbatim, so some of them mention
`LazyHTML.filter/2`. That function matches only the fragment's root nodes, so
use `LazyHTML.query/2` to find an element.
| # | ms | async | file:line | test |
|---|---|---|---|---|
| 1 | 35105 | async | `test/platform/regression/lazy_html_selector_guidance_audit_test.exs:76` | test LazyHTML selector guidance no markdown file shows a LazyHTML.filter/2 call example |
| 2 | 29897 | async | `test/platform/extension_boundary_test.exs:245` | test apps/platform names no module a sibling project defines, in any file it ships or tests |
| 3 | 16052 | async | `test/platform/agents/providers/ollama_test.exs:171` | test receive_timeout (c) a response that takes longer than Req's 15s default still succeeds |
| 4 | 16016 | sync | `test/platform/meetings/summarizer_test.exs:1361` | test end-to-end summarisation against a provider slower than Req's default a completion returned after 16s sti |
| 5 | 14192 | async | `test/platform/design/border_token_direction_test.exs:295` | test (e) call-site residue every allowlist entry still matches a real call site |
| 6 | 12446 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:242` | test concurrency no `async: true` test file detaches a boot-attached handler |
| 7 | 12433 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:681` | test attack 7: pool exhaustion 9 canvases looping: the 9th is busy and the agent pool stays at 0 throughout (sleep) |
| 8 | 11645 | async | `test/platform/regression/board_topic_scope_audit_test.exs:96` | test global board subscriptions in async tests no async: true test module calls the zero-arity Tasks.subscribe |
| 9 | 11522 | async | `test/platform/repo_lookup_boundary_test.exs:2015` | test the scan itself sees Repo.get_by/2 sites whose exposed id is a keyword value |
| 10 | 11117 | async | `test/platform/repo_lookup_boundary_test.exs:1843` | test the Repo lookup boundary inventory no inventory entry names a site that no longer exists |
| 11 | 10273 | async | `test/platform/design/border_token_direction_test.exs:280` | test (e) call-site residue no live border-base-300 call site survives outside the allowlist |
| 12 | 10119 | async | `test/platform/parallel_ui_test.exs:268` | test live tree every ledger entry is marked and every marker is registered |
| 13 | 9436 | sync | `test/platform_web/live/chat/agents_members_sheets_removed_test.exs:90` | test source sweep lib, assets/js, assets/css and test carry no name of the deleted surfaces |
| 14 | 9183 | async | `test/platform/access/grant_writer_guard_test.exs:80` | test no arity-1 grant write outside lib/platform/access/ and nodes.ex |
| 15 | 9149 | async | `test/platform/regression/spawn_primitive_inventory_audit_test.exs:294` | test spawn primitive sites under lib/ every discovered site appears in @inventory |
| 16 | 9114 | async | `test/platform/repo_lookup_boundary_test.exs:1945` | test Repo.one (counted, not classified) per-file Repo.one counts are unchanged |
| 17 | 8690 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:366` | test topic inventory every topic shape in lib is classified, and every classified shape still exists |
| 18 | 8505 | sync | `test/platform/org/wiki/indexer_test.exs:542` | test incident repro over a real socket (task 01a0d8c9) a page ingest slower than 5s is sent exactly once, even |
| 19 | 8442 | async | `test/platform/design/focus_ring_census_test.exs:278` | test (c) the census no raw focus-visible:ring-primary survives in application code |
| 20 | 8327 | async | `test/platform/regression/spawn_primitive_inventory_audit_test.exs:301` | test spawn primitive sites under lib/ every @inventory entry's site still exists (staleness) |
| 21 | 7991 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:377` | test topic inventory the scan sees a plausible number of topics (non-vacuity floor) |
| 22 | 7797 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:284` | test sandbox-owner-chain claims in comments and docs every claim names the sandbox mode it holds under |
| 23 | 7322 | async | `test/platform/extension_boundary_test.exs:271` | test a product-name exemption never hides a full module name |
| 24 | 7151 | async | `test/platform/extension_boundary_test.exs:262` | test POSITIVE CONTROL: the scan hits a sibling project's own lib |
| 25 | 7066 | async | `test/platform/product_name_guard_test.exs:260` | test scan of the repository no scanned line names the old product, outside the allowlist |
| 26 | 6806 | async | `test/platform/meetings/open_question_pilot/imp_scope_guard_test.exs:122` | test Imp is referenced only from the pilot allowlist under apps/platform/lib |
| 27 | 6214 | async | `test/platform/repo_lookup_boundary_test.exs:1970` | test the scan itself reconciles exactly against a plain-text grep of the same tree |
| 28 | 6088 | async | `test/platform/design/focus_ring_census_test.exs:195` | test (a) the scan surface is real the exclusion is load-bearing: this file's own source carries the literal |
| 29 | 6034 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:439` | test responsibility trigger topics every trigger_config topic is classified, and every classified one still ex |
| 30 | 5871 | async | `test/platform/regression/burrow_env_fallback_guard_test.exs:139` | test (B) every SUITE_ token in the tree is a listed fallback or out-of-scope name |
| 31 | 5777 | sync | `test/platform/orchestration/task_router_late_ack_resume_test.exs:322` | test RESUME (the 019f9cb8 incident) a late owner ack resumes the task without re-prompting, and the next stage |
| 32 | 5747 | sync | `test/platform/federation/tool_result_size_measure_test.exs:129` | test review_item_list serialized size for a task holding 258 review items |
| 33 | 5596 | async | `test/platform/regression/board_topic_scope_audit_test.exs:105` | test global board subscriptions in async tests the scan actually sees scoped subscriptions in async files (non |
| 34 | 5502 | async | `test/platform/regression/burrow_env_fallback_guard_test.exs:155` | test (C) no file still names a SUITE_ spelling that was renamed outright |
| 35 | 5337 | async | `test/platform/extension_boundary_test.exs:289` | test POSITIVE CONTROL: every planted shape is caught, built from the derived set |
| 36 | 5313 | async | `test/platform/extension_boundary_test.exs:232` | test the derived name set is not empty and covers more than one namespace |
| 37 | 5196 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:196` | test the carve-out cannot grow the grep that audit uses finds things when they are there |
| 38 | 5186 | async | `test/platform/tasks/status_writer_guard_test.exs:222` | test check C — no bulk or raw status writes against tasks no raw SQL updates the tasks table |
| 39 | 5180 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:326` | test hero-* corpus hero-camera-slash is not used anywhere, so the guard must not fail on it |
| 40 | 5121 | async | `test/platform/design/meeting_reskin_contrast_guard_test.exs:492` | test anti-vacuity: a planted Ask label goes red with the variant and ratio |
| 41 | 5067 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:274` | test hero-* corpus every hero-* class used in lib resolves to a real icon file |
| 42 | 4873 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:230` | test no test module drives the queue without a connection the ExUnit.Case detector fires on a module that real |
| 43 | 4848 | async | `test/platform/regression/task_alias_shadowing_audit_test.exs:99` | test Platform.Tasks.Task alias shadowing no module that aliases the schema unqualified calls a bare Task.<OTP  |
| 44 | 4729 | async | `test/platform/test_temp_test.exs:143` | test uniqueness across OS processes tokens from two freshly started BEAMs never collide |
| 45 | 4654 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:307` | test hero-* corpus the allowlist covers only English prose, not missing icons |
| 46 | 4562 | sync | `test/platform/access/bypass_dispatch_test.exs:90` | test TaskRouter dispatch a deny on the OWNER refuses resolve and dispatch; P on the same runtime still dispatc |
| 47 | 4520 | sync | `test/platform_web/live/mask_names_chip_test.exs:184` | test presence the chip and the page still agree after the key expires mid-session (sleep) |
| 48 | 4520 | sync | `test/platform/orchestration/task_router_redispatch_cap_test.exs:231` | test (iv) with base 1_000, injections every 50ms for 1.5s deliver exactly 2, and nothing retries |
| 49 | 4487 | async | `test/platform_web/live/chat/message_actions_removed_test.exs:94` | test no source under lib, assets/js or assets/css names message-context-trigger |
| 50 | 4458 | async | `test/platform/design/focus_ring_census_test.exs:166` | test (a) the scan surface is real the scanned file set is non-empty and contains known carriers |
| 51 | 4430 | async | `test/platform_web/inline_onclick_guard_test.exs:168` | test template corpus no element pairs phx-click with an inline onclick |
| 52 | 4401 | sync | `test/integration/intent_eval_e2e_scoring_test.exs:160` | test the labelled corpus, driven to a row in `tasks` every routable intent mints a task and every decline does |
| 53 | 4367 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:393` | test topic inventory the scan still sees one shape per anchor kind (non-vacuity anchors) |
| 54 | 4144 | async | `test/platform/memory/memory_service_env_async_guard_test.exs:69` | test no async: true test module writes the global :memory_service env |
| 55 | 4068 | async | `test/platform/mail/single_sender_guard_test.exs:59` | test exactly one file calls Mailer.deliver, and it is the Deliverer |
| 56 | 3934 | async | `test/platform_web/live/chat/message_actions_removed_test.exs:94` | test no source under lib, assets/js or assets/css names "open_thread" |
| 57 | 3809 | async | `test/platform/regression/supervised_task_repo_audit_test.exs:320` | test Task.Supervisor sites under Platform.TaskSupervisor every caller either rescues DBConnection.OwnershipErr |
| 58 | 3804 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:627` | test attack 6: a timer flood a two-handler after(100) ping-pong is held to the same floor (sleep) |
| 59 | 3783 | async | `test/platform/design/focus_ring_census_test.exs:291` | test (c) the census the focus-visible:ring-focus-ring call sites are still present, per file |
| 60 | 3734 | async | `test/platform_web/inline_onclick_guard_test.exs:114` | test the scanner itself positive control — stripping comments does not empty the buffer |
| 61 | 3677 | sync | `test/platform_web/live/meeting_ask_floor_press_test.exs:334` | test a quick release with nothing claimed frees the floor immediately and crumbles the card once the server's  (sleep) |
| 62 | 3643 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:286` | test attack 1: an infinite loop while it loops, the same room, an agent suite_run and another LiveView all ser |
| 63 | 3504 | sync | `test/platform_web/live/meeting_ask_transcript_feed_test.exs:209` | test a real release with ZERO claims resolves crumble ONLY once the server's own empty-press grace closes the  (sleep) |
| 64 | 3426 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:601` | test attack 6: a timer flood a handler that re-schedules itself from every fire runs at most once a second (sleep) |
| 65 | 3355 | async | `test/platform/design/text_exemption_guard_test.exs:294` | test every text-disabled and text-decorative in the tree sits where it is exempt |
| 66 | 3319 | async | `test/platform/accounts/mask_names_test.exs:123` | test one write path only accounts.ex spells the quoted key in code |
| 67 | 3284 | async | `test/platform/memory/memory_service_env_async_guard_test.exs:47` | test the scan finds the :memory_service writers (positive control) |
| 68 | 3274 | async | `test/platform/regression/org_scope_choke_point_audit_test.exs:162` | test private org filters outside the choke point the scan visits a plausible number of files |
| 69 | 3261 | async | `test/platform/design/inactive_tab_contrast_test.exs:212` | test no .tab element carries its own text colour class |
| 70 | 3258 | sync | `test/platform/orchestration/task_router_boot_reengagement_test.exs:257` | test a rebooted router and an unchanged planning prompt an identical restart is withheld, and a restart after  |
| 71 | 3228 | sync | `test/platform/orchestration/task_router_boot_reengagement_test.exs:503` | test each conjunct is load-bearing an engagement whose metadata has no delivered_online key does not suppress |
| 72 | 3224 | async | `test/platform/design/subtle_text_ratchet_test.exs:192` | test the retired faint tier stays retired in lib, assets/css and assets/js |
| 73 | 3207 | sync | `test/platform/meetings/press_card_test.exs:266` | test a press released with nothing said the REAL timer release/3 arms is what delivers the close — no injectio (sleep) |
| 74 | 3172 | async | `test/platform/repo_lookup_boundary_test.exs:1862` | test the Repo lookup boundary inventory recorded call counts match the source tree |
| 75 | 3171 | sync | `test/platform/orchestration/task_router_withheld_dispatch_copy_test.exs:149` | test the withheld-dispatch message and the safety-net lapse the lapse blocks and dispatches nothing, and the m |
| 76 | 3117 | sync | `test/platform/agents/system_event_scheduler_test.exs:1299` | test windowed threshold sweep — resumes after cap-hit second tick past debounce dispatches the next batch |
| 77 | 3102 | sync | `test/platform/orchestration/task_router_late_ack_resume_test.exs:442` | test CONTROL with no ack the alarm still bites: blocked, router stopped |
| 78 | 3093 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:224` | test detach of a boot-attached telemetry handler every @known_safe entry still has an unrestored detach |
| 79 | 3078 | async | `test/platform/meetings/intent_queue/ack_window_margin_test.exs:300` | test where the window goes a burst of five gets a flat margin, not a degrading one — the window is not cascadi |
| 80 | 3037 | sync | `test/platform/access/bypass_dispatch_test.exs:188` | test TaskRouter dispatch after the deny is revoked the next :dispatch sends |
| 81 | 3037 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:660` | test attack 6: a timer flood after CanvasRoom.stop/2, no further script_run arrives in 2 s |
| 82 | 3028 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:615` | test attack 6: a timer flood an after(100) self-chain runs at most once a second over 3 s (sleep) |
| 83 | 3025 | sync | `test/platform/orchestration/task_router_phase_assignee_test.exs:534` | test foreign lease on the running stage a second hydrate emits nothing — the abandon IS the idempotency |
| 84 | 3014 | sync | `test/platform/orchestration/task_router_phase_assignee_test.exs:218` | test phase assignee resolved at dispatch time reassigning the execution phase on a LIVE router redirects the n |
| 85 | 3003 | async | `test/platform/meetings/open_question_pilot/no_production_switch_guard_test.exs:27` | test no migration, seed, config or mix task names the surface |
| 86 | 2976 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:218` | test detach of a boot-attached telemetry handler every detach is either self-healing or preceded by a register |
| 87 | 2928 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:199` | test the scanner itself positive control: a comment is stripped without skipping its file |
| 88 | 2874 | async | `test/platform_web/live/chat/message_actions_removed_test.exs:94` | test no source under lib, assets/js or assets/css names cancel_save_edit |
| 89 | 2789 | sync | `test/platform/canvas/script_engine/js_test.exs:260` | test the canvas slot pool a fifth concurrent handler on one canvas is busy |
| 90 | 2787 | async | `test/platform/design/burrow_palette_guard_test.exs:304` | test the status -dim steps are never painted as text |
| 91 | 2772 | sync | `test/platform/orchestration/task_router_test.exs:5431` | test pre-plan design hold (ADR-0046 member 7) the pipeline's per-step budget expires an open step; a longer bu |
| 92 | 2770 | async | `test/platform/slow_tests_test.exs:82` | test registry / tree agreement every @tag :slow in the suite has a registry entry naming its file |
| 93 | 2733 | async | `test/platform/regression/attention_broadcast_funnel_audit_test.exs:80` | test attention broadcasts the scan actually sees the funnel itself (non-vacuity anchor) |
| 94 | 2725 | async | `test/platform/isolated_beam_tests_test.exs:106` | test registry / tree agreement every @moduletag :isolated_beam in the suite has a registry entry naming its fi |
| 95 | 2683 | async | `test/platform_web/components/scope_pill_test.exs:1076` | test every call site declares its surface (task 01a09333-d374 stage 3) the inventory is exactly this one site, |
| 96 | 2659 | sync | `test/platform/code_mode/sandbox_adversarial_test.exs:155` | test CPU a finite CPU loop of a few seconds is stopped by fuel |
| 97 | 2637 | async | `test/platform_web/components/scope_pill_test.exs:802` | test edge and hover on the var path (task 01a09333-d374 stage 4) base_100, compact: the edge at rest comes fro |
| 98 | 2635 | async | `test/platform/design/dark_token_diff_test.exs:261` | test staleness guard the live recipes are still used in lib/, and the retired ones are gone |
| 99 | 2616 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:312` | test sandbox-owner-chain claims in comments and docs every @known_unqualified_claims entry still carries an un |
| 100 | 2608 | async | `test/platform/tasks/status_writer_guard_test.exs:208` | test check C — no bulk or raw status writes against tasks no update_all/insert_all sets status on the tasks ta |

## Top 50 modules (hosted, merged across shards)

Module wall time runs from `module_started` to `module_finished`, so it
includes `setup_all`. Async module walls overlap in time and do not add up to
run time. "source scan" means the test file reads or globs repository source
(`File.read`, `File.stream!`, `Path.wildcard` or `File.ls` over
lib/assets/docs/test/priv/config). 236 files match that definition.


| # | wall ms | summed test ms | async | tests | file | source scan |
|---|---|---|---|---|---|---|
| 1 | 55022 | 55020 | async | 6 | `test/platform/extension_boundary_test.exs` | yes |
| 2 | 48670 | 48669 | async | 14 | `test/platform/repo_lookup_boundary_test.exs` |  |
| 3 | 48560 | 465 | sync | 20 | `test/platform/tasks/submit_plan_for_review_architect_hook_test.exs` | yes |
| 4 | 48152 | 42 | async | 15 | `test/platform/regression/install_identity_guard_test.exs` | yes |
| 5 | 45376 | 45159 | async | 453 | `test/platform_web/live/meeting_live_test.exs` |  |
| 6 | 36524 | 36524 | async | 3 | `test/platform/regression/lazy_html_selector_guidance_audit_test.exs` | yes |
| 7 | 34100 | 111 | async | 21 | `test/platform/regression/adr_citation_audit_test.exs` | yes |
| 8 | 32996 | 32956 | sync | 21 | `test/platform/canvas/script_engine/adversarial_test.exs` |  |
| 9 | 29070 | 29062 | async | 9 | `test/platform/regression/pubsub_topic_inventory_audit_test.exs` | yes |
| 10 | 28941 | 28939 | async | 7 | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs` | yes |
| 11 | 28607 | 28599 | async | 32 | `test/platform_web/live/chat/message_actions_removed_test.exs` | yes |
| 12 | 26569 | 26298 | sync | 454 | `test/platform_web/live/tasks_live_test.exs` | yes |
| 13 | 26338 | 26331 | async | 12 | `test/platform/design/border_token_direction_test.exs` | yes |
| 14 | 24267 | 241 | sync | 6 | `test/platform/tasks/architecture_gate_open_telemetry_test.exs` | yes |
| 15 | 23842 | 23474 | sync | 99 | `test/platform/orchestration/task_router_test.exs` | yes |
| 16 | 22778 | 22771 | async | 9 | `test/platform/design/focus_ring_census_test.exs` | yes |
| 17 | 20212 | 20163 | async | 87 | `test/platform_web/components/scope_pill_test.exs` | yes |
| 18 | 19952 | 19944 | sync | 21 | `test/platform_web/live/chat/upload_dialog_removed_test.exs` | yes |
| 19 | 19132 | 19116 | sync | 35 | `test/platform/meetings/summarizer_test.exs` |  |
| 20 | 18878 | 17116 | async | 6 | `test/platform/agents/providers/ollama_test.exs` |  |
| 21 | 18728 | 18723 | async | 10 | `test/platform_web/hero_icon_resolution_guard_test.exs` | yes |
| 22 | 18712 | 18646 | async | 24 | `test/platform_web/components/theme_picker_test.exs` | yes |
| 23 | 17695 | 14035 | sync | 17 | `test/platform/org/wiki/indexer_test.exs` |  |
| 24 | 17481 | 17480 | async | 5 | `test/platform/regression/spawn_primitive_inventory_audit_test.exs` | yes |
| 25 | 17283 | 17196 | sync | 128 | `test/platform_web/live/chat_live_test.exs` |  |
| 26 | 17241 | 17241 | async | 2 | `test/platform/regression/board_topic_scope_audit_test.exs` | yes |
| 27 | 16724 | 16684 | sync | 9 | `test/platform/orchestration/task_router_phase_assignee_test.exs` |  |
| 28 | 14646 | 14630 | sync | 65 | `test/platform/meetings/intent_dispatcher_test.exs` |  |
| 29 | 13517 | 11501 | async | 4 | `test/platform/regression/burrow_env_fallback_guard_test.exs` | yes |
| 30 | 13198 | 13191 | sync | 4 | `test/platform/orchestration/task_router_late_ack_resume_test.exs` |  |
| 31 | 12432 | 12416 | async | 10 | `test/platform/meetings/intent_queue/mirror_fatality_test.exs` | yes |
| 32 | 12162 | 12159 | async | 19 | `test/platform/parallel_ui_test.exs` | yes |
| 33 | 11872 | 11846 | sync | 5 | `test/platform/orchestration/task_router_redispatch_cap_test.exs` |  |
| 34 | 11356 | 11314 | sync | 76 | `test/platform_web/live/chat_live_chat_list_test.exs` |  |
| 35 | 11222 | 11161 | sync | 65 | `test/platform_web/live/tasks_write_fence_test.exs` |  |
| 36 | 10761 | 10759 | sync | 5 | `test/platform_web/live/chat/agents_members_sheets_removed_test.exs` | yes |
| 37 | 10674 | 10673 | async | 4 | `test/platform/access/grant_writer_guard_test.exs` | yes |
| 38 | 9675 | 9644 | sync | 10 | `test/platform/access/bypass_dispatch_test.exs` |  |
| 39 | 9636 | 6371 | async | 44 | `test/platform/tenancy/scope_color_test.exs` |  |
| 40 | 9451 | 9424 | sync | 47 | `test/platform_web/live/chat_live_space_sheet_test.exs` |  |
| 41 | 9051 | 8992 | sync | 105 | `test/platform/meetings/intent_classifier_test.exs` |  |
| 42 | 9023 | 9022 | async | 12 | `test/platform/tasks/status_writer_guard_test.exs` | yes |
| 43 | 8170 | 8165 | async | 6 | `test/platform_web/inline_onclick_guard_test.exs` | yes |
| 44 | 8150 | 8146 | async | 7 | `test/platform/meetings/intent_queue/ack_window_margin_test.exs` |  |
| 45 | 7654 | 7625 | sync | 5 | `test/platform/orchestration/task_router_branch_provisioning_test.exs` |  |
| 46 | 7587 | 7539 | async | 5 | `test/platform/design/meeting_reskin_contrast_guard_test.exs` | yes |
| 47 | 7559 | 7542 | sync | 7 | `test/platform/orchestration/task_router_boot_reengagement_test.exs` |  |
| 48 | 7542 | 7504 | sync | 86 | `test/platform_web/live/inbox_live_test.exs` |  |
| 49 | 7487 | 7486 | async | 13 | `test/platform/product_name_guard_test.exs` | yes |
| 50 | 7431 | 7428 | async | 3 | `test/platform/memory/memory_service_env_async_guard_test.exs` | yes |

## Premise counts (re-run at f46ed3f2a, bash)

- 1,717 `*_test.exs` files. 1,189 contain `async: false`, and 17 have no
  `async:` option at all, which defaults to false. Together that is 1,206
  non-async files (ticket: 1,196).
- 442 of the non-async files hit `Application.put_env/delete_env`,
  `persistent_term` or `set_mox_global` (ticket: ~550).
- 288 `Process.sleep` calls in tests, plus 30 `:timer.sleep`.
- 36 files (634 tests) read lib/ with `File.read!(...lib/` on one line. A
  broader definition that also counts module-attribute lib paths gives
  72 files (1,301 tests). The ticket said 60 files and 859 tests.

## Local run (labelled local, not hosted)

10-core dev machine, `CI=true mix test --include slow`, unsharded, one
BEAM: 906 s (104.6 s async, 801.4 s sync), 25,357 tests, 1 failure
(`tool_aliases_test.exs:610`, a known local baseline). The sync share
(88%) agrees with the hosted result.

## Stage 4: sleeps converted and sleeps kept

Converted (sleep stood in for a sync point; the assertion could run before the
process under test had handled the event, so a `refute` could pass vacuously):
`intent_classifier_test.exs` (9 sites), `intent_dispatcher_test.exs` (the
`start_dispatcher!` init wait), `chat_live_test.exs` (9 sites) and
`meeting_live_test.exs` (2 sites). Each now calls `:sys.get_state/1` on the
process under test, which is handled after every message already in its
mailbox. A local PubSub broadcast has put its message in the subscriber's
mailbox before it returns, so the barrier is complete. No timeout or TTL
constant was changed.

Kept, because the elapsed time or the sleep is the behaviour under test:

- `adversarial_test.exs:606,:620,:633,:712`: measurement window for a rate or budget limit.
- `mask_names_chip_test.exs:198`: waits for a real clock to pass a stored expiry.
- `intent_classifier_test.exs:1611`: the debounce window is the subject.
- `intent_dispatcher_test.exs:1397`: three heartbeats across more than two ack windows.
- `task_router_test.exs:2525,:2528`: elapsed wall clock is the subject of `d1 - d3 >= 200`.
- Bounded poll loops (`intent_dispatcher_test.exs:191`, `adversarial_test.exs:229,:256`, `js_test.exs:325`, `intent_eval_e2e_scoring_test.exs:592,:615`): a deadline-bounded poll, not a fixed wait.

Not converted, ~280 further `Process.sleep` sites outside the slow list; not audited here.

Reported, not fixed: the press-window grace timer tests still have no
"not before grace" assertion, so an early-firing timer would pass.

`lazy_html_selector_guidance_audit_test.exs` keeps its 300 s module timeout.
With SourceIndex it takes ~24 s with the other module locally, but in the full
local run (heavily loaded) its first test still hit the 60 s default while
walking `**/*.md` across the whole repo, so the timeout is still needed.

## After (stage 5)

- Before: run `40432578697`, commit `08ec6ba56` (main `709747d4c` plus the formatter), https://github.com/GetBurrowing/core/actions/runs/40432578697
- After: run `40446864605`, commit `daed162ab` (task branch with main merged at `ab262e8f9`; merged, not rebased, so the pushed branch was not force-pushed), https://github.com/GetBurrowing/core/actions/runs/40446864605
- All 11 jobs success, `first-run-green` success, no `initial mix test failed` warning on any shard (the grep hits in the logs are the script text only). No serial retry ran, so the green is first-pass.

### Wall times (after)

| job | before job wall | after job wall | before test step | after test step |
|---|---|---|---|---|
| Test (shard 1) | 5m43s | 6m08s | 3m57s (ExUnit 233.7 s) | 4m00s (ExUnit 236.0 s: 34.7 async / 201.2 sync) |
| Test (shard 2) | 4m50s | 7m07s | 3m12s (189.1 s) | 4m47s (282.5 s: 42.6 / 239.9) |
| Test (shard 3) | 5m11s | 6m56s | 3m11s (186.8 s) | 4m43s (278.3 s: 74.7 / 203.6) |
| Test (shard 4) | 7m08s | 6m39s | 4m54s (289.8 s) | 4m33s (268.7 s: 110.1 / 158.5) |
| Test (shard 5) | 5m10s | 7m04s | 3m21s (197.9 s) | 4m42s (277.1 s: 75.6 / 201.5) |
| Test (shard 6) | 6m29s | 6m44s | 4m14s (250.4 s) | 4m35s (270.5 s: 92.4 / 178.0) |
| Test (checks) | 7m22s | 7m04s | | |
| **Test (aggregate)** | **7m29s** | **7m16s** (03:55:32 to 04:02:48) | | |
| Test (with Play), control | 19m01s | 2m59s | module tests 33 s | module tests 27 s |
| Test (with Social), control | 3m58s | 2m59s | module tests 1m45s | module tests 1m08s |

Summed ExUnit run time over the six shards: 1,613 s after against 1,347.7 s before.

**The delta is noise, not a gain, and the shard sums went up.** The aggregate moved 7m29s to 7m16s, but the shards' own ExUnit times are higher in this run (sum +265 s) and the shards finish within 8 s of each other, so the critical path is whichever shard was slowest on a shared runner. Hosted-runner variance is larger than anything this task changed. Do not read the 13 s as a saving. Play and Social are controls; their before/after differences (Play's job wall differs by 16 minutes between the runs for reasons outside the tests) are not a gain either.

### Test counts

| | passed (doctests incl.) | skipped | excluded |
|---|---|---|---|
| before, 6 shards | 25,426 | 3 | 6 |
| after, 6 shards | 25,435 | 3 | 6 |

Per shard after: 4001, 4011, 4443, 4367, 4173, 4440. The count did not drop (deleted guards: 0 rows). It rose by 9, which is main's: `voice_session_test.exs` (+18 lines, PR #9) and `ci_no_docker_hub_test.exs` (+407 lines) arrived between the two runs. This task added or removed no test. Partition membership moved between shards for the same reason, so a per-shard before/after comparison above is not like for like.

### First-pass failures

None. No retry ran. The known flake `adversarial_test.exs:681` (pool exhaustion, task 01a17b0b) did not fail here; it ran in shard 4 at 11.9 s. Nothing from stages 2 to 4 flaked, so nothing was reverted.

### Per-module delta for modules this task touched (hosted wall ms)

Only modules in the top 50 of both runs have a hosted time on both sides; a module outside the top 50 is shown as below the cutoff (10566 ms after).

| module | before | after | note |
|---|---|---|---|
| `test/platform/extension_boundary_test.exs` | 55022 | 72597 | |
| `test/platform/regression/lazy_html_selector_guidance_audit_test.exs` | 36524 | 10566 | |
| `test/platform_web/live/chat/message_actions_removed_test.exs` | 28607 | below top-50 cutoff | |
| `test/platform/meetings/intent_classifier_test.exs` | 9051 | below top-50 cutoff | |
| `test/platform/meetings/intent_dispatcher_test.exs` | 14646 | 13797 | |
| `test/platform_web/live/chat_live_test.exs` | 17283 | 19280 | |
| `test/platform_web/live/meeting_live_test.exs` | 45376 | 62690 | |
| `test/platform/meetings/press_card_test.exs` | below top-50 cutoff | below top-50 cutoff | |
| `test/platform_web/live/meeting_ask_floor_press_test.exs` | below top-50 cutoff | below top-50 cutoff | |
| `test/platform_web/live/meeting_ask_transcript_feed_test.exs` | below top-50 cutoff | below top-50 cutoff | |
| `test/platform/chat/canvas_room/handler_test.exs` | below top-50 cutoff | below top-50 cutoff | |

Reading it, honestly: the hosted numbers do NOT show a speed-up from this task.
- `lazy_html_selector_guidance_audit`: 36.5 s to 10.6 s. SourceIndex worked here.
- `message_actions_removed` (stage 2): 28.6 s to below the top-50 cutoff.
- `extension_boundary`: 55.0 s to **72.6 s**, slower on hosted. Locally SourceIndex cut it together with lazy_html from 128 s to 24 s, but on the hosted runner the module's cost is not the file reads. Each of its tests recomputes the derived needle set (`Code.string_to_quoted!` over every sibling module, `core_segments`, regex compilation) and SourceIndex caches only reads and globs. Follow-up (not done here): memoise the derived set per VM. Because the file's assertions were not touched, there is no correctness effect.
- `meeting_live` 45.4 s to 62.7 s and `chat_live` 17.3 s to 19.3 s: the `:sys.get_state` conversions were for correctness, and these two modules run on shared CPU with other async modules; the increase is within the run-to-run spread seen on the controls and is not attributable to the conversion (it removes 50 ms sleeps, it cannot add 17 s). Not reverted: no test in either module failed.
- `intent_classifier` fell below the cutoff; `intent_dispatcher` 14.6 s to 13.8 s.
- `product_name_guard_test.exs:260` rose to 21.6 s from 7.1 s; the file is untouched by this task.

### Top 100 tests after (hosted, merged across shards)

| # | ms | async | file:line | test |
|---|---|---|---|---|
| 1 | 46242 | async | `test/platform/extension_boundary_test.exs:234` | test the derived name set is not empty and covers more than one namespace |
| 2 | 26207 | async | `test/platform/meetings/open_question_pilot/imp_scope_guard_test.exs:122` | test Imp is referenced only from the pilot allowlist under apps/platform/lib |
| 3 | 21611 | async | `test/platform/product_name_guard_test.exs:260` | test scan of the repository no scanned line names the old product, outside the allowlist |
| 4 | 21501 | async | `test/platform/repo_lookup_boundary_test.exs:1970` | test the scan itself reconciles exactly against a plain-text grep of the same tree |
| 5 | 19798 | async | `test/platform/regression/board_topic_scope_audit_test.exs:105` | test global board subscriptions in async tests the scan actually sees scoped subscriptions in async files (non |
| 6 | 16568 | async | `test/platform/agents/providers/ollama_test.exs:171` | test receive_timeout (c) a response that takes longer than Req's 15s default still succeeds |
| 7 | 16253 | async | `test/platform/access/grant_writer_guard_test.exs:80` | test no arity-1 grant write outside lib/platform/access/ and nodes.ex |
| 8 | 16164 | sync | `test/platform/meetings/summarizer_test.exs:1361` | test end-to-end summarisation against a provider slower than Req's default a completion returned after 16s sti |
| 9 | 14157 | async | `test/platform/repo_lookup_boundary_test.exs:1805` | test the Repo lookup boundary inventory every Repo.get-family call site in lib is classified |
| 10 | 13498 | async | `test/platform/design/focus_ring_census_test.exs:166` | test (a) the scan surface is real the scanned file set is non-empty and contains known carriers |
| 11 | 12165 | sync | `test/platform_web/live/chat/agents_members_sheets_removed_test.exs:90` | test source sweep lib, assets/js, assets/css and test carry no name of the deleted surfaces |
| 12 | 11908 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:681` | test attack 7: pool exhaustion 9 canvases looping: the 9th is busy and the agent pool stays at 0 throughout |
| 13 | 11081 | async | `test/platform/design/focus_ring_census_test.exs:195` | test (a) the scan surface is real the exclusion is load-bearing: this file's own source carries the literal |
| 14 | 11019 | async | `test/platform/design/focus_ring_census_test.exs:291` | test (c) the census the focus-visible:ring-focus-ring call sites are still present, per file |
| 15 | 11019 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:312` | test sandbox-owner-chain claims in comments and docs every @known_unqualified_claims entry still carries an un |
| 16 | 10958 | async | `test/platform/memory/memory_service_env_async_guard_test.exs:69` | test no async: true test module writes the global :memory_service env |
| 17 | 10795 | async | `test/platform/design/subtle_text_ratchet_test.exs:192` | test the retired faint tier stays retired in lib, assets/css and assets/js |
| 18 | 10536 | async | `test/platform/regression/lazy_html_selector_guidance_audit_test.exs:100` | test LazyHTML selector guidance every paragraph naming LazyHTML.filter also states the root-node caveat |
| 19 | 10418 | async | `test/platform/tasks/status_writer_guard_test.exs:222` | test check C — no bulk or raw status writes against tasks no raw SQL updates the tasks table |
| 20 | 10390 | async | `test/platform/design/text_exemption_guard_test.exs:294` | test every text-disabled and text-decorative in the tree sits where it is exempt |
| 21 | 10230 | async | `test/platform/parallel_ui_test.exs:268` | test live tree every ledger entry is marked and every marker is registered |
| 22 | 9978 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:284` | test sandbox-owner-chain claims in comments and docs every claim names the sandbox mode it holds under |
| 23 | 9955 | async | `test/platform/design/agent_slot_tokens_guard_test.exs:416` | test no markup puts an --ag- token on a button, link or focus class |
| 24 | 9912 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:217` | test no test module drives the queue without a connection every file that enqueues or starts a queue has a dat |
| 25 | 9878 | async | `test/platform/memory/memory_service_env_async_guard_test.exs:47` | test the scan finds the :memory_service writers (positive control) |
| 26 | 9871 | async | `test/platform/regression/burrow_env_fallback_guard_test.exs:155` | test (C) no file still names a SUITE_ spelling that was renamed outright |
| 27 | 9702 | async | `test/platform/regression/spawn_primitive_inventory_audit_test.exs:294` | test spawn primitive sites under lib/ every discovered site appears in @inventory |
| 28 | 9665 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:366` | test topic inventory every topic shape in lib is classified, and every classified shape still exists |
| 29 | 9597 | async | `test/platform/design/inactive_tab_contrast_test.exs:212` | test no .tab element carries its own text colour class |
| 30 | 9002 | async | `test/platform/accounts/mask_names_test.exs:123` | test one write path only accounts.ex spells the quoted key in code |
| 31 | 8867 | async | `test/platform/tasks/status_writer_guard_test.exs:208` | test check C — no bulk or raw status writes against tasks no update_all/insert_all sets status on the tasks ta |
| 32 | 8673 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:377` | test topic inventory the scan sees a plausible number of topics (non-vacuity floor) |
| 33 | 8506 | sync | `test/platform/org/wiki/indexer_test.exs:542` | test incident repro over a real socket (task 01a0d8c9) a page ingest slower than 5s is sent exactly once, even |
| 34 | 8462 | async | `test/platform/isolated_beam_tests_test.exs:106` | test registry / tree agreement every @moduletag :isolated_beam in the suite has a registry entry naming its fi |
| 35 | 8196 | async | `test/platform/extension_boundary_test.exs:247` | test apps/platform names no module a sibling project defines, in any file it ships or tests |
| 36 | 7834 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:182` | test the carve-out cannot grow server_persistence_test.exs is the only file that turns the key off |
| 37 | 7597 | async | `test/platform/regression/attention_broadcast_funnel_audit_test.exs:72` | test attention broadcasts only Platform.Federation.AttentionDispatch broadcasts "attention" |
| 38 | 7559 | async | `test/platform/design/border_token_direction_test.exs:295` | test (e) call-site residue every allowlist entry still matches a real call site |
| 39 | 7519 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:393` | test topic inventory the scan still sees one shape per anchor kind (non-vacuity anchors) |
| 40 | 7250 | async | `test/platform/extension_boundary_test.exs:264` | test POSITIVE CONTROL: the scan hits a sibling project's own lib |
| 41 | 7201 | async | `test/platform/regression/spawn_primitive_inventory_audit_test.exs:301` | test spawn primitive sites under lib/ every @inventory entry's site still exists (staleness) |
| 42 | 6999 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:242` | test concurrency no `async: true` test file detaches a boot-attached handler |
| 43 | 6783 | async | `test/platform/regression/org_scope_choke_point_audit_test.exs:162` | test private org filters outside the choke point the scan visits a plausible number of files |
| 44 | 6663 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:196` | test the carve-out cannot grow the grep that audit uses finds things when they are there |
| 45 | 6526 | async | `test/platform/regression/org_scope_choke_point_audit_test.exs:156` | test private org filters outside the choke point no module defines its own viewer org filter |
| 46 | 6463 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:524` | test global-topic verdicts the global transcript topic is only subscribed by supervised singletons |
| 47 | 6310 | async | `test/platform/meetings/open_question_pilot/no_production_switch_guard_test.exs:27` | test no migration, seed, config or mix task names the surface |
| 48 | 6220 | sync | `test/platform/federation/tool_result_size_measure_test.exs:129` | test review_item_list serialized size for a task holding 258 review items |
| 49 | 6087 | async | `test/platform/mail/single_sender_guard_test.exs:59` | test exactly one file calls Mailer.deliver, and it is the Deliverer |
| 50 | 6027 | async | `test/platform/regression/attention_broadcast_funnel_audit_test.exs:80` | test attention broadcasts the scan actually sees the funnel itself (non-vacuity anchor) |
| 51 | 5893 | async | `test/platform/parallel_ui_test.exs:255` | test live tree each default root is actually walked |
| 52 | 5875 | sync | `test/platform/orchestration/task_router_late_ack_resume_test.exs:322` | test RESUME (the 019f9cb8 incident) a late owner ack resumes the task without re-prompting, and the next stage |
| 53 | 5783 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:199` | test the scanner itself positive control: a comment is stripped without skipping its file |
| 54 | 5743 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:439` | test responsibility trigger topics every trigger_config topic is classified, and every classified one still ex |
| 55 | 5524 | async | `test/platform/extension_boundary_test.exs:273` | test a product-name exemption never hides a full module name |
| 56 | 5381 | async | `test/platform/extension_boundary_test.exs:291` | test POSITIVE CONTROL: every planted shape is caught, built from the derived set |
| 57 | 5290 | sync | `test/platform/agents/system_event_scheduler_test.exs:1299` | test windowed threshold sweep — resumes after cap-hit second tick past debounce dispatches the next batch |
| 58 | 5278 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:307` | test hero-* corpus the allowlist covers only English prose, not missing icons |
| 59 | 5189 | async | `test/platform/regression/burrow_env_fallback_guard_test.exs:139` | test (B) every SUITE_ token in the tree is a listed fallback or out-of-scope name |
| 60 | 5151 | async | `test/platform/tasks/status_writer_guard_test.exs:268` | test self-exclusion the scan actually walks lib and finds files |
| 61 | 5098 | async | `test/platform/mail/single_sender_guard_test.exs:49` | test nothing outside lib/platform/mail/ references Swoosh or gen_smtp |
| 62 | 5084 | async | `test/platform/design/meeting_reskin_contrast_guard_test.exs:492` | test anti-vacuity: a planted Ask label goes red with the variant and ratio |
| 63 | 5055 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:274` | test hero-* corpus every hero-* class used in lib resolves to a real icon file |
| 64 | 4971 | async | `test/platform/meetings/intent_queue/mirror_fatality_test.exs:230` | test no test module drives the queue without a connection the ExUnit.Case detector fires on a module that real |
| 65 | 4886 | async | `test/platform/test_temp_test.exs:143` | test uniqueness across OS processes tokens from two freshly started BEAMs never collide |
| 66 | 4791 | sync | `test/integration/intent_eval_e2e_scoring_test.exs:160` | test the labelled corpus, driven to a row in `tasks` every routable intent mints a task and every decline does |
| 67 | 4636 | async | `test/platform_web/components/scope_pill_test.exs:1076` | test every call site declares its surface (task 01a09333-d374 stage 3) the inventory is exactly this one site, |
| 68 | 4612 | sync | `test/platform/orchestration/task_router_redispatch_cap_test.exs:231` | test (iv) with base 1_000, injections every 50ms for 1.5s deliver exactly 2, and nothing retries |
| 69 | 4594 | sync | `test/platform/access/bypass_dispatch_test.exs:90` | test TaskRouter dispatch a deny on the OWNER refuses resolve and dispatch; P on the same runtime still dispatc |
| 70 | 4518 | sync | `test/platform_web/live/mask_names_chip_test.exs:184` | test presence the chip and the page still agree after the key expires mid-session |
| 71 | 4511 | async | `test/platform/tenancy/scope_color_test.exs:391` | test derive/2 — each label clears AA against its OWN tint, with margin the themes need opposite surfaces: ligh |
| 72 | 4491 | async | `test/platform/slow_tests_test.exs:82` | test registry / tree agreement every @tag :slow in the suite has a registry entry naming its file |
| 73 | 4361 | async | `test/platform_web/hero_icon_resolution_guard_test.exs:182` | test the scanner itself positive control: comment stripping does not gut the corpus |
| 74 | 4097 | async | `test/platform/access/grant_writer_guard_test.exs:100` | test no module outside lib/platform/access/ names the access_grants table |
| 75 | 4090 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:224` | test detach of a boot-attached telemetry handler every @known_safe entry still has an unrestored detach |
| 76 | 4062 | async | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs:218` | test detach of a boot-attached telemetry handler every detach is either self-healing or preceded by a register |
| 77 | 3922 | async | `test/platform/tenancy/scope_color_test.exs:93` | test derive/2 — the AA-on-both-themes property every hue 0..359 clears AA on BOTH themes, on every surface |
| 78 | 3908 | async | `test/platform_web/components/scope_color_styles_test.exs:267` | test an org with a colour no hue drops its row: every value the solver produces passes the value whitelist |
| 79 | 3666 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:286` | test attack 1: an infinite loop while it loops, the same room, an agent suite_run and another LiveView all ser |
| 80 | 3576 | async | `test/platform/tasks/status_writer_guard_test.exs:251` | test self-exclusion the scanned set never includes this guard file |
| 81 | 3499 | async | `test/platform/regression/space_write_handle_event_audit_test.exs:214` | test client space ids reaching a Chat write from a LiveView event no handler writes to a client-supplied space |
| 82 | 3442 | async | `test/platform/regression/pubsub_topic_inventory_audit_test.exs:463` | test responsibility trigger topics the trigger_config scan is not empty (non-vacuity) |
| 83 | 3428 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:601` | test attack 6: a timer flood a handler that re-schedules itself from every fire runs at most once a second |
| 84 | 3290 | sync | `test/platform/orchestration/task_router_boot_reengagement_test.exs:257` | test a rebooted router and an unchanged planning prompt an identical restart is withheld, and a restart after  |
| 85 | 3271 | sync | `test/platform/orchestration/task_router_boot_reengagement_test.exs:503` | test each conjunct is load-bearing an engagement whose metadata has no delivered_online key does not suppress |
| 86 | 3237 | sync | `test/platform_web/live/meeting_ask_floor_press_test.exs:334` | test a quick release with nothing claimed frees the floor immediately and crumbles the card once the server's  |
| 87 | 3226 | sync | `test/platform/orchestration/task_router_withheld_dispatch_copy_test.exs:149` | test the withheld-dispatch message and the safety-net lapse the lapse blocks and dispatches nothing, and the m |
| 88 | 3166 | async | `test/platform/scope_registry_consistency_test.exs:52` | test the compiled lists are gone no source file under lib/ declares one of the retired attributes |
| 89 | 3152 | async | `test/platform/design/meeting_reskin_contrast_guard_test.exs:424` | test every pair clears its floor in all ten variants; the table prints |
| 90 | 3149 | sync | `test/platform_web/live/meeting_ask_transcript_feed_test.exs:209` | test a real release with ZERO claims resolves crumble ONLY once the server's own empty-press grace closes the  |
| 91 | 3138 | sync | `test/platform/orchestration/task_router_late_ack_resume_test.exs:442` | test CONTROL with no ack the alarm still bites: blocked, router stopped |
| 92 | 3118 | async | `test/platform/meetings/intent_queue/ack_window_margin_test.exs:300` | test where the window goes a burst of five gets a flat margin, not a degrading one — the window is not cascadi |
| 93 | 3037 | sync | `test/platform/access/bypass_dispatch_test.exs:188` | test TaskRouter dispatch after the deny is revoked the next :dispatch sends |
| 94 | 3034 | sync | `test/platform/orchestration/task_router_phase_assignee_test.exs:534` | test foreign lease on the running stage a second hydrate emits nothing — the abandon IS the idempotency |
| 95 | 3032 | async | `test/platform/regression/task_alias_shadowing_audit_test.exs:99` | test Platform.Tasks.Task alias shadowing no module that aliases the schema unqualified calls a bare Task.<OTP  |
| 96 | 3031 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:660` | test attack 6: a timer flood after CanvasRoom.stop/2, no further script_run arrives in 2 s |
| 97 | 3030 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:615` | test attack 6: a timer flood an after(100) self-chain runs at most once a second over 3 s |
| 98 | 3028 | async | `test/platform/design/border_token_direction_test.exs:280` | test (e) call-site residue no live border-base-300 call site survives outside the allowlist |
| 99 | 3026 | sync | `test/platform/canvas/script_engine/adversarial_test.exs:627` | test attack 6: a timer flood a two-handler after(100) ping-pong is held to the same floor |
| 100 | 3024 | sync | `test/platform/meetings/press_card_test.exs:266` | test a press released with nothing said the REAL timer release/3 arms is what delivers the close — no injectio |

### Top 50 modules after (hosted, merged across shards)

| # | wall ms | summed test ms | async | tests | file |
|---|---|---|---|---|---|
| 1 | 88115 | 66 | async | 15 | `test/platform/regression/install_identity_guard_test.exs` |
| 2 | 72597 | 72595 | async | 6 | `test/platform/extension_boundary_test.exs` |
| 3 | 68933 | 109 | async | 21 | `test/platform/regression/adr_citation_audit_test.exs` |
| 4 | 62690 | 62462 | async | 453 | `test/platform_web/live/meeting_live_test.exs` |
| 5 | 52128 | 52122 | async | 14 | `test/platform/repo_lookup_boundary_test.exs` |
| 6 | 48811 | 708 | sync | 20 | `test/platform/tasks/submit_plan_for_review_architect_hook_test.exs` |
| 7 | 46506 | 46110 | sync | 454 | `test/platform_web/live/tasks_live_test.exs` |
| 8 | 41534 | 41525 | async | 9 | `test/platform/regression/pubsub_topic_inventory_audit_test.exs` |
| 9 | 37490 | 37486 | async | 9 | `test/platform/design/focus_ring_census_test.exs` |
| 10 | 36180 | 36176 | async | 7 | `test/platform/regression/boot_telemetry_handler_detach_audit_test.exs` |
| 11 | 32608 | 32587 | sync | 21 | `test/platform/canvas/script_engine/adversarial_test.exs` |
| 12 | 29547 | 29523 | async | 10 | `test/platform/meetings/intent_queue/mirror_fatality_test.exs` |
| 13 | 28050 | 28039 | async | 12 | `test/platform/tasks/status_writer_guard_test.exs` |
| 14 | 27874 | 27327 | async | 8 | `test/platform/meetings/open_question_pilot/imp_scope_guard_test.exs` |
| 15 | 26848 | 26243 | sync | 99 | `test/platform/orchestration/task_router_test.exs` |
| 16 | 26724 | 78 | async | 8 | `test/platform/ci_no_docker_hub_test.exs` |
| 17 | 25816 | 25812 | async | 13 | `test/platform/product_name_guard_test.exs` |
| 18 | 24247 | 220 | sync | 6 | `test/platform/tasks/architecture_gate_open_telemetry_test.exs` |
| 19 | 22709 | 22702 | async | 10 | `test/platform_web/hero_icon_resolution_guard_test.exs` |
| 20 | 22309 | 14192 | async | 44 | `test/platform/tenancy/scope_color_test.exs` |
| 21 | 21892 | 21890 | async | 2 | `test/platform/regression/board_topic_scope_audit_test.exs` |
| 22 | 20907 | 15179 | async | 4 | `test/platform/regression/burrow_env_fallback_guard_test.exs` |
| 23 | 20838 | 20836 | async | 3 | `test/platform/memory/memory_service_env_async_guard_test.exs` |
| 24 | 20796 | 20726 | async | 87 | `test/platform_web/components/scope_pill_test.exs` |
| 25 | 20489 | 13110 | async | 29 | `test/platform/design/subtle_text_ratchet_test.exs` |
| 26 | 20354 | 20351 | async | 4 | `test/platform/access/grant_writer_guard_test.exs` |
| 27 | 19945 | 19938 | sync | 21 | `test/platform_web/live/chat/upload_dialog_removed_test.exs` |
| 28 | 19280 | 19190 | sync | 128 | `test/platform_web/live/chat_live_test.exs` |
| 29 | 19271 | 19254 | sync | 35 | `test/platform/meetings/summarizer_test.exs` |
| 30 | 18980 | 18884 | async | 24 | `test/platform_web/components/theme_picker_test.exs` |
| 31 | 18760 | 17179 | async | 6 | `test/platform/agents/providers/ollama_test.exs` |
| 32 | 17701 | 14045 | sync | 17 | `test/platform/org/wiki/indexer_test.exs` |
| 33 | 16944 | 16923 | async | 5 | `test/platform/regression/spawn_primitive_inventory_audit_test.exs` |
| 34 | 16771 | 16721 | sync | 9 | `test/platform/orchestration/task_router_phase_assignee_test.exs` |
| 35 | 16278 | 16213 | sync | 65 | `test/platform_web/live/tasks_write_fence_test.exs` |
| 36 | 16132 | 16130 | async | 19 | `test/platform/parallel_ui_test.exs` |
| 37 | 15823 | 15821 | async | 5 | `test/platform/mail/single_sender_guard_test.exs` |
| 38 | 15301 | 17 | async | 10 | `test/platform/regression/system_event_envelope_record_audit_test.exs` |
| 39 | 13987 | 13985 | sync | 5 | `test/platform_web/live/chat/agents_members_sheets_removed_test.exs` |
| 40 | 13797 | 13773 | sync | 65 | `test/platform/meetings/intent_dispatcher_test.exs` |
| 41 | 13626 | 13624 | async | 2 | `test/platform/regression/attention_broadcast_funnel_audit_test.exs` |
| 42 | 13550 | 13547 | async | 3 | `test/platform/regression/org_scope_choke_point_audit_test.exs` |
| 43 | 13496 | 13483 | sync | 4 | `test/platform/orchestration/task_router_late_ack_resume_test.exs` |
| 44 | 13276 | 13272 | sync | 13 | `test/platform/federation/tool_result_size_test.exs` |
| 45 | 12256 | 12220 | sync | 5 | `test/platform/orchestration/task_router_redispatch_cap_test.exs` |
| 46 | 11864 | 11839 | async | 33 | `test/platform/design/agent_slot_tokens_guard_test.exs` |
| 47 | 11647 | 11641 | async | 12 | `test/platform/design/border_token_direction_test.exs` |
| 48 | 11456 | 11417 | sync | 76 | `test/platform_web/live/chat_live_chat_list_test.exs` |
| 49 | 10891 | 10889 | async | 14 | `test/platform/design/text_exemption_guard_test.exs` |
| 50 | 10566 | 10565 | async | 3 | `test/platform/regression/lazy_html_selector_guidance_audit_test.exs` |
