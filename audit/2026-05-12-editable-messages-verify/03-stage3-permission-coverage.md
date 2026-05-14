# Stage 3 — Permission + Freeze Enforcement (Sections e + f, Policies 2 + 3) coverage

**Date:** 2026-05-12 (initial), updated 2026-05-13 after Policy 2 trigger shipped
**Stage:** Task 6 / Stage 3
**Branch:** `task/019df569-b82a-7319-8ac4-b9419ffe87b9`
**New test file:** `apps/platform/test/platform/chat/edit_permissions_test.exs`

## ✅ Update — Policy 2 freeze trigger SHIPPED on main (2026-05-13)

Task `019e1e80-4230-7a79-ac73-c157975b3999` shipped both freeze triggers via
PR #343 (squash `60f24be` on main):

- **Task-scoped:** wired into `Tasks.transition_task/2` — status flip + freeze loop in one `Repo.transaction`.
- **Ad-hoc:** new `Platform.Chat.AdHocFreezeListener` GenServer subscribes to `chat:agent_runtime` and freezes in-context messages atomically on `{:agent_first_state_op, agent_participant_id, space_id}`.
- **Implementation tests on the Policy 2 branch:** 24 tests across 3 files (in-context query 12, task-scoped freeze 7, ad-hoc listener 5).

Cases 4, 5, 6 in this file are now **active** and assert end-to-end Policy 2 enforcement through the PATCH endpoint (controller-level integration). Test result on this branch:

```
$ mix test test/platform/chat/edit_permissions_test.exs
5 tests, 0 failures, 1 skipped
```

The single skipped test is **Case 3** (intentional architectural skip — see "Policy 3 architecture note" below). The critical-finding section below is preserved as a historical record of what was found and how it was closed.

---

## ★ Critical finding (resolved) — Policy 2 freeze trigger was NOT implemented in production

Exhaustive grep of `apps/platform/lib/` for any call site of `MessageVersions.freeze/2` or `MessageVersions.freeze!/2` outside tests returned **zero matches**. The freeze mechanism exists at the data layer (`frozen_at` + `frozen_by_participant_id` columns, plus `MessageVersions.freeze/2` function), and the HTTP controller correctly returns 409-with-freezing-action when `frozen_at` is non-null — but **no production code path automatically calls freeze** when:
- An associated task transitions to `in_progress` (Policy 2 task-scoped trigger), or
- The assigned agent performs its first state-changing op — file write / git commit / PR / canvas mutation / external API mutation (Policy 2 ad-hoc trigger).

The existing freeze tests (`message_controller_test.exs:160`, `edit_test.exs:67`) pass only because they **manually call `MessageVersions.freeze`** in test setup. In production the freeze never fires automatically. The result: users can freely edit messages even after an agent has begun work, contradicting the editable-messages contract's Policy 2.

This is a real shipping gap that the Task 1 contract pinned but Tasks 2–5 didn't close. **A follow-up task has been filed** to wire the triggers — see "Follow-up filed" below.

## Permission coverage matrix (the five forbidden scenarios)

| # | Forbidden scenario | Expected | Coverage |
|---|---|---|---|
| 1 | Edit another user's message | 403 forbidden_not_author | ✅ `message_controller_test.exs:122` (Stage 2 confirmed) |
| 2 | Edit a bot/agent message as a human | 403 forbidden_not_author | ✅ **NEW** `edit_permissions_test.exs` Case 2 — explicit agent fixture, asserts response code + DB content unchanged |
| 3 | Edit own agent message as the agent | 403 (Policy 3) | ⏭️ Skipped — see "Policy 3 architecture note" below |
| 4 | Edit after task `in_progress` | 409 + freezing_action | ✅ **NEW** `edit_permissions_test.exs` Case 4 — drives `Tasks.transition_task → in_progress`, then PATCH returns 409 with `freezing_action.participant_display_name == "Saru"`, DB content unchanged |
| 5 | Edit after agent first state-changing op | 409 + freezing_action | ✅ **NEW** Case 5 — calls `AdHocFreezeListener.handle_info/2` directly with `{:agent_first_state_op, …}` (deterministic; mirrors `ad_hoc_freeze_listener_test.exs` pattern), then PATCH returns 409 |
| 6 | Planning-time tools (reads, search) do NOT trigger freeze | no freeze, 200 | ✅ **NEW** Case 6 (negative) — calls `AdHocFreezeListener.handle_info/2` with `{:agent_read_op, …}` (a non-state-op shape the listener silently ignores), then PATCH returns 200 and DB content updates |

## Policy 3 architecture note (Case 3)

Policy 3 says: agents cannot edit their own messages; they must issue a *correction* (a new message with `corrects_message_id` set). Enforcement at the HTTP layer is by absence of code path, not by a runtime check:

- The PATCH endpoint is mounted under the `:require_auth_api` router pipeline.
- `:require_auth_api` only attaches *user sessions* (`current_user_id`) — an agent never has a user session.
- Therefore an agent can never hit the controller; the policy is enforced by the authn pipeline.
- The `check_author/2` helper at `message_controller.ex:146` is belt-and-suspenders defense.

The LV `save_edit` event path (`chat_live.ex:253`) is a separate surface. Agents *could* theoretically hit it if they had an LV session, but they don't have user sessions either, so the same authn block applies. Documented in the skipped test for clarity; no follow-up needed unless the LV authn assumption changes.

## Tests in this file (post-2026-05-13 update)

`apps/platform/test/platform/chat/edit_permissions_test.exs` — 5 ExUnit tests:
- **4 active:**
  - Case 2: 403 `forbidden_not_author` when a human tries to edit an agent-authored message.
  - Case 4: 409 `frozen` after the associated task transitions to `in_progress` (Policy 2, task-scoped).
  - Case 5: 409 `frozen` after the assigned agent's first state-changing op (Policy 2, ad-hoc).
  - Case 6 (negative): planning-time signals do NOT freeze; PATCH 200 OK and content updates.
- **1 skipped (intentional):** Case 3 — Policy 3 enforcement is by architecture, not by runtime check (HTTP API only attaches user sessions, agents have no authn path).

Test result:
```
mix test test/platform/chat/edit_permissions_test.exs
5 tests, 0 failures, 1 skipped
```

Lint clean (`mix format --check-formatted`, exit 0).

## Follow-up status

**Suite Task `019e1e80-4230-7a79-ac73-c157975b3999`: "Implement Policy 2 freeze trigger (task-scoped + ad-hoc)"** — **SHIPPED** via PR #343 (squash `60f24be` on main, 2026-05-13 20:32 EDT). Cases 4, 5, 6 above exercise that implementation through the PATCH endpoint.

## Stage 3 verdict — updated

**Permission enforcement (Cases 1, 2): ✅ conformant.** All 403 cases are server-side enforced.

**Policy 2 (Cases 4, 5, 6): ✅ conformant.** Both triggers (task-scoped + ad-hoc) are wired in production code and verified end-to-end through the controller. Atomicity contract verified independently in `policy_2_freeze_test.exs` and `ad_hoc_freeze_listener_test.exs` on the Policy 2 branch.

**Policy 3 (Case 3): ✅ conformant by architecture.** Agents have no authn path to the editing endpoints; documented skip preserved.

Test_pass: ✅ (5 tests, 0 failures, 1 skipped)
Lint_pass: ✅

**Stage 3 complete (with 2026-05-13 close-out update).**
