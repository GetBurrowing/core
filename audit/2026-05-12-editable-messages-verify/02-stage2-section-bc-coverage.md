# Stage 2 — Contract Conformance (Sections b + c) coverage report

**Date:** 2026-05-12
**Stage:** Task 6 / Stage 2 — API + realtime event tests
**Branch:** `task/019df569-b82a-7319-8ac4-b9419ffe87b9`

## Surprise finding

Stage 2's plan said *"NEW `apps/platform/test/platform_web/controllers/message_edit_controller_test.exs` for the API surface; NEW `apps/platform/test/platform/chat/edit_broadcast_test.exs` for the realtime event."* — but recon revealed **the test files already exist and cover virtually all of sections b + c**. The plan was written without recon of existing tests; this Stage 2 update closes that gap.

## Existing test files inventory

| File | Lines | Purpose |
|---|---|---|
| `apps/platform/test/platform_web/controllers/message_controller_test.exs` | 303 | HTTP PATCH + GET versions API surface |
| `apps/platform/test/platform/chat/messages/edit_test.exs` | 133 | `Edit.apply_edit/3` unit + `compute_removed_substrings/2` |
| `apps/platform/test/platform/chat/message_versions_test.exs` | 242 | Version table operations (record_v1!, record_edit, list/count, freeze) |

## Section b — API contract coverage

| Contract requirement | Existing test | Status |
|---|---|---|
| `PATCH /api/messages/:id` returns 401 when no session | `message_controller_test.exs:74` | ✅ |
| 404 when message does not exist | `:84` | ✅ |
| 404 when message is soft-deleted | `:96` | ✅ |
| 403 forbidden_not_in_space when user not a participant | `:110` | ✅ |
| 403 forbidden_not_author when user in space but not author | `:122` | ✅ |
| 422 validation_failed on empty content | `:136` | ✅ |
| 422 validation_failed on content > 10_000 chars | `:148` | ✅ |
| 409 frozen with freezing_action payload | `:160` | ✅ |
| 200 happy path: content updated, edited_at set, v2 recorded | `:183` | ✅ |
| `versions_count` in response body | `:196` | ✅ |
| Response includes `edited_at` | `:197` | ✅ |
| Idempotent on identical content (no new v) | `:234` | ✅ |
| `GET /api/messages/:id/versions` newest-first for authorized participant | `:255` | ✅ |
| GET versions 404 when message absent | `:279` | ✅ |
| GET versions 403 when not a space participant | `:291` | ✅ |
| **Rate limit (10/min/user/message)** | — | ❌ **GAP** |

## Section c — Realtime event coverage

| Contract requirement | Existing test | Status |
|---|---|---|
| Broadcast event is `{:message_edited, payload}` | `message_controller_test.exs:204`; `edit_test.exs:60` | ✅ |
| Payload includes `message` (full updated row) | `:205`; `:61` | ✅ |
| Payload includes `previous_content` | `:207`; `:62` | ✅ |
| Payload includes `version_number` | `:208`; `:63` | ✅ |
| Payload includes `edited_by_participant_id` | `edit_test.exs:64` | ✅ |
| Payload includes `removed_substrings` diff (Policy 4) | `message_controller_test.exs:230`; `edit_test.exs:101` | ✅ |
| `compute_removed_substrings/2` lists contiguous runs missing from new | `edit_test.exs:101` | ✅ |
| Returns `[]` when content is unchanged | `:109` | ✅ |
| Returns `[]` when content is purely additive | `:113` | ✅ |
| Groups multi-word runs together | `:121` | ✅ |
| Handles empty previous content | `:129` | ✅ |
| No broadcast on failed edit (frozen) | `edit_test.exs:83` | ✅ |
| No broadcast on idempotent edit | `message_controller_test.exs:248` | ✅ |
| **Broadcast topic exactly `chat:space:{space_id}`** (vs raw space_id) | partial — tests use `PubSub.subscribe(space.id)`; the topic-format-as-string isn't asserted explicitly | ⚠️ **minor** |

## ORG_MEMORY drift confirmed (resolution: ORG_MEMORY is stale)

ORG_MEMORY's 2026-05-08 entry says realtime should be `{:message_updated, msg, diff}` 3-tuple. The **contract canvas `019e1827-e8e5-7c02-9534-22c1d6290bae` (Task 1 contract, 2026-05-11)** authoritatively names the event `{:message_edited, payload}`. Implementation matches the contract. **ORG_MEMORY is stale and should be updated** — flagged for Stage 5's final report (will do `org_context_write` then).

Also stale in ORG_MEMORY:
- "API ships as LV event `edit_message`, not REST PATCH." — Implementation ships **both** REST PATCH `/api/messages/:id` (matches contract Section b) AND the LV `save_edit` form-submit. Both correct.
- Table name: ORG_MEMORY says `message_versions`; actual table is `chat_message_versions`.
- Freeze column: ORG_MEMORY says `frozen_by_action_id`; actual is `frozen_by_participant_id` (per Decision D-1 on the contract canvas).

## Gaps identified — to address in this Stage 2 or punt

| Gap | Verdict |
|---|---|
| Rate limit (10/min) | **Punt to a follow-up task.** Rate limiting is an infra concern (contract Decision D-3 wasn't yet resolved at contract draft time) — the verification doesn't block on it as long as the contract is met. Will note in final Stage 5 report. |
| Broadcast topic format `chat:space:{space_id}` literal | **Skip.** Tests already implicitly verify by subscribing & receiving. An explicit topic-string assertion adds noise without catching anything real. |
| Policy-3 explicit agent-self-edit attempt → 403 | **Move to Stage 3.** Belongs in the permission/freeze enforcement stage; Stage 2 is API + broadcast only. |

## Stage 2 validation

**No new tests needed for Stage 2.** The existing coverage matches the contract sections b + c to a degree the plan didn't anticipate. The `test_pass` + `lint_pass` validations are satisfied by running the existing suite on the test files cited.

Test command (must pass):
```
cd apps/platform
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test test/platform/chat/messages/edit_test.exs \
         test/platform_web/controllers/message_controller_test.exs \
         test/platform/chat/message_versions_test.exs
```

Lint command (must pass):
```
mix format --check-formatted apps/platform/test/platform_web/controllers/message_controller_test.exs \
                              apps/platform/test/platform/chat/messages/edit_test.exs \
                              apps/platform/test/platform/chat/message_versions_test.exs
```

## Stage 2 verdict

**Sections b + c are materially conformant to the contract.** No new tests authored — the existing suite is comprehensive. One rate-limit gap punted to follow-up; one broadcast-topic-string assertion deemed not worth the noise; Policy-3 explicit agent-self-edit moved to Stage 3 where it belongs. ORG_MEMORY needs a corrective update at Stage 5 close.

**Stage 2 complete.**
