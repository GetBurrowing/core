# Install-identity inventory: "fabrikam" in the codebase

Task 01a116de ("Scrub Fabrikam from the codebase"), stage 1. **The per-file table
below is generated** by `scripts/install_identity_inventory.py` from
`git grep -ic fabrikam` over the whole repository; do not edit it by hand. Re-run
the script after any stage that changes a count.

Scope (Rowan, 2026-10-07): scrub the CODE only. Fabrikam is a client org on Rowan's
installs and stays there as DATA (class d); an open-source release is planned,
so a fresh install must not come up owned by Fabrikam.

The guard that keeps this from growing back is
`apps/platform/test/platform/regression/no_fabrikam_identity_guard_test.exs`. It
holds an exact-count allowlist for every file in its scanned set; the
"guard" column below says whether a file is in that set. The ratchet forces
each later stage to shrink the allowlist as it removes hits.

## Classes

| class | meaning | disposition |
|---|---|---|
| a | product identity, defaults, copy | must go (stages 2 and 3) |
| a-dep | a real external dependency (published mobile ids) | stays, with the reason recorded |
| b | test fixture | stage 4 renamed the root fixture to `acme`; on-purpose legacy fixtures and non-mechanical hits stay, each with its reason |
| c | history: already-run migrations, intent_eval cassettes, ADRs, audit mocks | stays; never rewrite a migration that ran |
| d | install data (rows in a database) | listed below, never changed |

`lines` is `git grep -ic fabrikam` (lines with a hit, the ticket's unit);
`matches` is case-insensitive occurrences (the guard's unit).

Not counted: this inventory's own tooling, which has to name the token
(`scripts/install_identity_inventory.py`, this file, and the guard test).

## Totals

| class | files | lines | matches |
|---|---:|---:|---:|
| a | 4 | 15 | 15 |
| a-dep | 116 | 445 | 462 |
| b | 32 | 231 | 273 |
| c | 43 | 140 | 149 |
| d | 0 | 0 | 0 |
| **all** | 195 | 831 | 899 |

Guard scanned set: 2 files with hits, so 2 allowlist entries totalling 7 matches. Class (d) has no files: it is rows, listed below.

## Class (d): install data, read-only

Measured by the planner on 2026-10-07 (read-only queries). This stage, and
every later stage, changes NONE of these rows.

| install | database | root org (slug, name) | child orgs (slug) |
|---|---|---|---|
| Fabrikam production (`core-platform` on moon) | `core_platform` on `core-postgres` | `fabrikam`, `Fabrikam` | paragon, doro-mind, soylent, wayne_tech, sxi, cyberdyne |
| Fabrikam exp (`core-platform-exp` on moon) | `core_platform_exp` | `fabrikam`, `Fabrikam` | paragon, soylent, wayne_tech, r2-org, red-star, sxi |

Before stage 2 neither install set `ROOT_ORG_SLUG`; both relied on the
`config :platform, :root_org_slug, "fabrikam"` default that stage 2 deleted.
`root_org_slug/0` now falls back to the structural root's slug, and the rollout
pinned `ROOT_ORG_SLUG=fabrikam` in both installs' env files before merge.
The `dispatch.scribe_completion` prompt-template row on these installs carries
a Fabrikam-specific mishearing correction; it is install data and is not
rewritten (`seed_defaults/0` is INSERT-only).

## FOLLOW-UP: the other hard-coded client slugs (out of scope)

Five more client slugs are hard-coded beside `fabrikam`: soylent, wayne_tech, sxi, paragon,
cyberdyne. That is the same open-source problem (a fresh install ships Rowan's client
list) and is OUT of this ticket's scope; stage 3 keeps the sibling atoms as they are.
The plan named tenancy.ex:386/1311-1326, scope_pill.ex:214/242, inheritance_pill.ex:79
and chat_live.ex:3494/4870-4895/5200-5212. Generated list of every `apps/*/lib` line
naming soylent, wayne_tech/wayne-tech, paragon or cyberdyne (sxi is omitted from this
grep: as a bare word it also matches unrelated text):

| file | lines |
|---|---|
| `apps/platform/lib/platform/chat/section.ex` | 7 |
| `apps/platform/lib/platform/chat/sidebar.ex` | 118 |
| `apps/platform/lib/platform/chat/sidebar_mask.ex` | 42, 85, 269, 303, 330, 333, 335, 347, 398 |
| `apps/platform/lib/platform/tasks.ex` | 6667, 6668, 6677 |
| `apps/platform/lib/platform/tenancy.ex` | 398, 401, 413, 1304, 1357, 1358, 1360, 1361, 1365, 1366, 1368, 1369 |
| `apps/platform/lib/platform/tenancy/scope_color.ex` | 71, 84, 85, 102, 124, 130, 154, 155, 157, 158, 166, 168, 520, 525, 539 |
| `apps/platform/lib/platform_web/components/inheritance_pill.ex` | 56 |
| `apps/platform/lib/platform_web/components/lifecycle_controls.ex` | 27, 47 |
| `apps/platform/lib/platform_web/components/scope_color_styles.ex` | 8, 284 |
| `apps/platform/lib/platform_web/components/scope_pill.ex` | 93, 126, 191, 192, 199, 204, 205, 208, 217, 547, 548, 571, 592, 634, 635, 637, 638 |
| `apps/platform/lib/platform_web/live/admin_orgs_live.ex` | 318 |
| `apps/platform/lib/platform_web/live/admin_orgs_live.html.heex` | 176 |
| `apps/platform/lib/platform_web/live/chat/partials/conversation.ex` | 168 |
| `apps/platform/lib/platform_web/live/chat/partials/rail.ex` | 1043 |
| `apps/platform/lib/platform_web/live/chat_live.ex` | 1595, 1743, 3498, 4368, 4919, 4925, 4926, 4927, 4929, 4932, 4941, 4942, 4943, 4945, 4957, 4958, 5164, 5165, 5277, 5278, 5279, 5281, 5286 |
| `apps/platform/lib/platform_web/live/tasks/board_component.ex` | 1673 |
| `apps/platform/lib/platform_web/live/tasks/filters_component.ex` | 91, 163 |
| `apps/platform/lib/platform_web/live/tasks/sidebar_component.ex` | 482 |
| `apps/platform/lib/platform_web/live/tasks/task_display.ex` | 387, 416, 447 |

## Per-file table (generated)

| path | lines | matches | class | guard | disposition |
|---|---:|---:|---|---|---|
| `.github/workflows/ci.yml` | 3 | 3 | a | no | product doc / CI comment outside the guard's scanned set. FOLLOW-UP; no plan stage removes it. |
| `apps/platform/lib/platform/mobile/fcm_device.ex` | 4 | 4 | a-dep | yes | Burrow Android applicationId `com.koboai.burrow` is the PUBLISHED package id FCM tokens are bound to; renaming it breaks every installed app. Stays, allowlisted. |
| `apps/platform/priv/intent_eval/cassettes/agent_roster_20260831.jsonl` | 2 | 3 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/cassettes/broken_malformed_schema.jsonl` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/cassettes/broken_never_off_topic.jsonl` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/cassettes/off_topic_default.jsonl` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T110556Z-off_topic_default.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T110558Z-binary_actionable.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T112342Z-broken_always_off_topic.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T112430Z-broken_never_off_topic.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T112542Z-broken_malformed_schema.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T112755Z-off_topic_default.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260827T112756Z-off_topic_default.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260829T061814Z-off_topic_default.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260831T223440Z-agent_roster.json` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260831T225724Z-off_topic_default.json` | 4 | 4 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/runs/20260831T225725Z-agent_roster.json` | 4 | 4 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/intent_eval/slices/control_60.jsonl` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519143600_create_orgs.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519143610_create_org_memberships.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519143620_seed_root_orgs.exs` | 3 | 4 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519143630_backfill_fabrikam_memberships.exs` | 18 | 18 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519160000_refine_fabrikam_admin_membership_by_email_domain.exs` | 17 | 17 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260519220000_add_roles_locked_at_to_org_memberships.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260604000000_add_org_id_to_chat_spaces.exs` | 3 | 4 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260618181114_adr_0042_org_project_topology.exs` | 5 | 5 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260618220754_add_chat_spaces_org_slug_unique_index.exs` | 3 | 3 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260619050000_skip_backfill_chat_attachments_to_files.exs` | 1 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260711000000_add_deletion_scheduled_at_to_chat_spaces.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260911003000_force_update_prompt_templates_sync_live_rows_2026_09_10.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260911180000_force_update_review_e2e_template_browser_session_check.exs` | 3 | 3 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260911181500_force_update_deploying_template_auto_merge_conditional.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260911220000_add_color_to_orgs.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260921190000_add_color_lightness_to_orgs.exs` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260922180000_update_agents_goal_heartbeat_prompt_drive.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260924171000_force_update_architect_and_planning_templates_experiment_surface.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20260927000100_make_channel_section_name_nullable.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/priv/repo/migrations/20261005120000_create_fcm_devices.exs` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `apps/platform/test/platform/data_migrations/add_color_lightness_to_orgs_test.exs` | 10 | 13 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/platform/data_migrations/adr_0042_root_org_resolution_test.exs` | 8 | 10 | b | no | on-purpose fixture: a child org slugged `fabrikam` is the discriminating case for the old slug lookup. KEEP. |
| `apps/platform/test/platform/data_migrations/seed_root_orgs_test.exs` | 9 | 11 | b | no | on-purpose fixture: refutes the brand terms the old seed migration wrote (`fabrikam` among them). KEEP. |
| `apps/platform/test/platform/legacy_fabrikam_root_org_test.exs` | 41 | 56 | b | no | on-purpose fixture: reproduces Rowan's legacy install shape (root literally `fabrikam`). KEEP. |
| `apps/platform/test/platform/mobile/voip_device_lifecycle_test.exs` | 3 | 3 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform/mobile_test.exs` | 7 | 8 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform/orchestration/prompt_templates_test.exs` | 2 | 3 | b | no | refutes `fabrikam` in the code default; quotes a Fabrikam install's `scribe_completion` row (class-d data shape). KEEP. |
| `apps/platform/test/platform/push/apns_test.exs` | 3 | 3 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform/push/apns_voip_test.exs` | 4 | 4 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform/root_org_admin_by_domain_e2e_test.exs` | 29 | 29 | b | no | on-purpose fixture: proves the pre-01a068f6 compiled `@example.com` admin literal is gone. KEEP. |
| `apps/platform/test/platform/root_org_admin_email_domain_test.exs` | 12 | 12 | b | no | on-purpose fixture: proves no fallback to the historical `example.com` admin domain. KEEP. |
| `apps/platform/test/platform/root_org_slug_test.exs` | 1 | 1 | b | no | moduledoc history: the hard-coded `"fabrikam"` task 01a081c2 removed. KEEP (history). |
| `apps/platform/test/platform/tenancy/scope_color_painted_test.exs` | 3 | 3 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/platform/tenancy/scope_color_test.exs` | 20 | 24 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/platform_web/components/scope_color_styles_shipped_six_test.exs` | 12 | 13 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/platform_web/components/scope_pill_static_opacity_test.exs` | 4 | 4 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/platform_web/components/scope_pill_test.exs` | 3 | 5 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/controllers/app_api_controller_test.exs` | 7 | 7 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform_web/controllers/app_meetings_controller_test.exs` | 1 | 1 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/platform_web/live/admin_route_guards_test.exs` | 1 | 1 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/live/canvas_live_test.exs` | 1 | 1 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/live/chat_live_external_rail_test.exs` | 2 | 2 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/live/chat_live_root_org_rail_test.exs` | 29 | 40 | b | no | on-purpose fixture: case (b) renames the root to Rowan's legacy `fabrikam|Fabrikam` shape inside the sandbox; case (a) refutes /fabrikam/i. KEEP. |
| `apps/platform/test/platform_web/live/experiments_live_test.exs` | 3 | 3 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/live/external_holding_live_test.exs` | 1 | 1 | b | no | `refute` that a removed compiled literal (`Fabrikam` copy, `bg-fabrikam*` classes) stays gone; renaming would point the guard at the live fixture root. KEEP. |
| `apps/platform/test/platform_web/live/org_memory_live_scope_test.exs` | 4 | 4 | b | no | re-pin notes quoting the exact `Fabrikam` phrases stages removed from wiki.ex. KEEP (history). |
| `apps/platform/test/support/fcm_fixtures.ex` | 1 | 1 | b | no | published Burrow bundle/package ids (`com.kobo-ai.burrow`, `com.koboai.burrow`) as test data for the a-dep ids. KEEP. |
| `apps/platform/test/support/scope_color_painted_fixture.ex` | 4 | 4 | b | no | keyed on the historical `fabrikam` slug the shipped-colour migrations pin (`20260911220000`, `20260921190000`) and the app.css history they reproduce. KEEP (class-c data); stage 4 not mechanical. |
| `apps/platform/test/test_helper.exs` | 3 | 3 | b | no | comments describing the historical `fabrikam` seed and colour pins. KEEP (history). |
| `audit/2026-05-08-ui-ux/mocks/_hero/all-surfaces-redesign.html` | 2 | 2 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `audit/2026-05-08-ui-ux/mocks/_preview/system-preview-v2.html` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `audit/2026-05-08-ui-ux/mocks/_preview/system-preview.html` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `clients/android/README.md` | 16 | 22 | a-dep | no | mobile app: 18 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/build.gradle` | 7 | 7 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/debug/AndroidManifest.xml` | 8 | 9 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/debug/java/com/koboai/burrow/push/DebugPushReceiver.kt` | 6 | 7 | a-dep | no | mobile app: 5 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/debug/java/com/koboai/burrow/push/DebugTokenSource.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/debug/java/com/koboai/burrow/push/DebugWidgetReceiver.kt` | 7 | 8 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/AppApiClient.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/AuthCallback.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/AuthSession.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/BurrowWebViewClient.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/InstallPickerView.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/InstallProbe.kt` | 2 | 2 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/InstallSession.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/InstallStore.kt` | 3 | 3 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/KeyValueStore.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/KeystoreTokenStore.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/MainActivity.kt` | 7 | 7 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/NativeBridgeExposure.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/NavigationPolicy.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/Pkce.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/SuiteNativePlugin.kt` | 7 | 7 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/BurrowMessagingService.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/BurrowPush.kt` | 10 | 10 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/NotificationChannels.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/NotificationPresenter.kt` | 9 | 9 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/PermissionExplainerActivity.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/PushPayload.kt` | 3 | 3 | a-dep | no | mobile app: 2 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/PushPermission.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/PushRegistrar.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/PushTokenSource.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/push/ReplyReceiver.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/share/MultipartForm.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/share/ShareActivity.kt` | 4 | 4 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/share/ShareClient.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/share/ShareIntents.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/share/ShareSheetModel.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/widgets/CountWidgets.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/widgets/CountsRepository.kt` | 4 | 4 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/widgets/SlabColors.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/widgets/SlabState.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/main/java/com/koboai/burrow/widgets/WidgetRefresh.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/release/java/com/koboai/burrow/push/BuildTypeTokenSource.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/AppApiClientTest.kt` | 2 | 2 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/AuthCallbackTest.kt` | 2 | 2 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/FakeTokenCipher.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/InMemoryKeyValueStore.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/InstallSessionTest.kt` | 10 | 13 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 12 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/InstallStoreTest.kt` | 8 | 9 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 8 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/KeystoreTokenStoreTest.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/NavigationPolicyTest.kt` | 19 | 19 | a-dep | no | mobile app: 8 bundle/package-id hit(s) and 11 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/NoSecretLoggingTest.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/PkceTest.kt` | 3 | 3 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/RecordingTransport.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/NoTokenInLogsTest.kt` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/NotificationPresenterTest.kt` | 10 | 10 | a-dep | no | mobile app: 7 bundle/package-id hit(s) and 3 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/PushPayloadTest.kt` | 17 | 18 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 17 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/PushPermissionTest.kt` | 3 | 3 | a-dep | no | mobile app: 2 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/PushRegistrarTest.kt` | 12 | 12 | a-dep | no | mobile app: 11 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/PushTestSupport.kt` | 7 | 7 | a-dep | no | mobile app: 3 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/ReleaseManifestTest.kt` | 9 | 9 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/push/ReplyTest.kt` | 10 | 10 | a-dep | no | mobile app: 9 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/share/AppShareClientTest.kt` | 9 | 9 | a-dep | no | mobile app: 8 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/share/ShareSheetModelTest.kt` | 3 | 3 | a-dep | no | mobile app: 2 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/widgets/CountWidgetsTest.kt` | 3 | 3 | a-dep | no | mobile app: 2 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/widgets/CountsRepositoryTest.kt` | 9 | 9 | a-dep | no | mobile app: 8 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/widgets/SlabStateTest.kt` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/android/app/src/test/java/com/koboai/burrow/widgets/WidgetGuardTest.kt` | 4 | 4 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 3 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/android/android/app/src/testDebug/java/com/koboai/burrow/push/DebugPushTest.kt` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/capacitor.config.ts` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/scripts/play_upload.py` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/scripts/release.sh` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/scripts/test_play_upload.py` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/android/scripts/test_release.sh` | 4 | 4 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/README.md` | 13 | 13 | a-dep | no | mobile app: 10 bundle/package-id hit(s) and 3 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/WHATSNEW.md` | 2 | 2 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/capacitor.config.ts` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App.xcodeproj/project.pbxproj` | 12 | 12 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/App.entitlements` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Info.plist` | 4 | 4 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/InstallPickerView.swift` | 1 | 1 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/App/Intents/EntityActivity.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Meetings/CallController.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Meetings/MeetingSession.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Meetings/RingCenter.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Meetings/VoIPRegistrar.swift` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/Plugins/SuiteNativePlugin.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/App/SceneDelegate.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/AppTests/DeepLinkTests.swift` | 4 | 4 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/InstallSessionTests.swift` | 4 | 4 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/InstallStoreTests.swift` | 6 | 7 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 7 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/IntentsTests.swift` | 6 | 6 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 6 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/KeychainTokenStoreTests.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/App/AppTests/MeetingLauncherTests.swift` | 4 | 4 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/NavigationPolicyTests.swift` | 6 | 6 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 6 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/NotificationTests.swift` | 6 | 7 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 7 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/PKCETests.swift` | 2 | 2 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/SlabStateTests.swift` | 8 | 8 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 8 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/SuiteAPIClientTests.swift` | 4 | 4 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 4 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/AppTests/WidgetApprovalTests.swift` | 1 | 2 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/EvidenceUITests/EvidenceUITests.swift` | 3 | 3 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 3 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/ExtensionRenderTests/ExtensionRenderTests.swift` | 12 | 12 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 12 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/App/project.yml` | 7 | 7 | a-dep | no | mobile app: 6 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/Intents/ApprovalsWidgetModel.swift` | 3 | 3 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/Intents/IntentSupport.swift` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/ShareExtension/Info.plist` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/ShareExtension/ShareExtension.entitlements` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/Shared/CountsEntry.swift` | 1 | 1 | a-dep | no | mobile app: 0 bundle/package-id hit(s) and 1 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/Shared/InstallStore.swift` | 3 | 3 | a-dep | no | mobile app: 1 bundle/package-id hit(s) and 2 other hit(s) (e.g. a `suite.example.com` host default). Out of guard scope; FOLLOW-UP. |
| `clients/ios/ios/Shared/KeychainTokenStore.swift` | 3 | 3 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/SuiteWidgets/Controls.swift` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/SuiteWidgets/Info.plist` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/SuiteWidgets/SuiteWidgets.entitlements` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/ios/SuiteWidgets/SuiteWidgets.swift` | 2 | 2 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/scripts/set_testflight_notes.py` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `clients/ios/scripts/testflight.sh` | 1 | 1 | a-dep | no | mobile app: published bundle/package id only. Keep; out of guard scope. |
| `deployment/installer/tests/test_mac_render.py` | 1 | 1 | b | no | installer's own forbidden-word guard; must keep the literal. KEEP (excluded from the guard's scanned set). |
| `deployment/installer/tests/test_mac_validate.py` | 1 | 1 | b | no | installer's own forbidden-word guard; must keep the literal. KEEP (excluded from the guard's scanned set). |
| `deployment/schema/install-modules.md` | 3 | 3 | a | yes | names Rowan's production installs. NO plan stage removes it yet; allowlisted pending a decision. |
| `docs/decisions/0022-dm-unread-badge.md` | 1 | 1 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `docs/decisions/0042-org-project-topology-and-context-inheritance.md` | 13 | 17 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `docs/decisions/0055-extension-contract-and-build-time-modules.md` | 13 | 14 | c | no | history (already-run migration / eval cassette / ADR / audit). Keep. |
| `docs/design-system/01-foundations.md` | 2 | 2 | a | no | product doc / CI comment outside the guard's scanned set. FOLLOW-UP; no plan stage removes it. |
| `docs/runbooks/onboard_tenant_org.md` | 7 | 7 | a | no | product doc / CI comment outside the guard's scanned set. FOLLOW-UP; no plan stage removes it. |
| `e2e/scripts/seed-meeting-mute-fixture.sh` | 1 | 1 | b | no | test fixture outside the apps' test trees (stage 4 scope). FOLLOW-UP. |
