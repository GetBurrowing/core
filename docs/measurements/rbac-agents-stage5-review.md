# RBAC agents stage 5 review runbook

This is a preparation artifact, not a verdict. Run only after stage 4 passes and its
drop-column migration is on the task branch. The review stage remains pending.
Use a private dev database on moon; production stays read-only. Do not put bearer
tokens, token hashes, or response bodies in this repository or a shared log.

## Isolated app under test

On hive, check `git worktree list` first, then create a **new** worktree named
`rbac5-stage5-e2e` at the final pushed task branch. The dev-on-moon helper sources
**hive** worktrees, not rock worktrees. Use this worktree only for this review.

```sh
ssh dev@dev-host 'cd ~/sources/core && git fetch origin && git worktree add --detach ~/sources/worktrees/rbac5-stage5-e2e origin/task/01a1386e-1710-7001-a77b-721b18695f04'
ssh dev@dev-host '~/cron/spawn-dev-on-moon.sh --port-only rbac5-stage5-e2e'
ssh dev@dev-host '~/cron/spawn-dev-on-moon.sh rbac5-stage5-e2e'
ssh dev@192.0.2.200 'podman inspect -f "{{index .Config.Labels \"dev-on-moon.port\"}}" dev-platform-rbac5-stage5-e2e'
```

Record the branch SHA in the hive worktree, the helper's actual URL, the container
name and its port label. Confirm the served code contains the new Agents rail and
profile behavior before grading. Before UI cases, verify `/assets/js/app.js` is
HTTP 200, `window.liveSocket` exists and is connected, and a known control works.
Use a fresh Chrome container on moon only if CDP port 9222 is free; otherwise
coordinate with its owner. Remove only this review's containers at teardown.

Run fixture code in the dev container with `MIX_ENV=dev`, or attach to its dev
node. Do not run `mix test` on hive or rock. Keep tokens in local shell variables
with shell history disabled, and issue JSON-RPC using a fixed request id so raw
responses are comparable. Store evidence outside the worktree in a private
directory, redacting bearer credentials and personally identifying data.

## Case 1: guest grant and owner deny

Seed root-org projects P/Q with two tasks each, guest G with a channel
participation, internal member M, and active runtimes B/G and A/M. Both profiles
are `federation space context_read messaging task`, restriction `nil`. Record P/Q
task ids privately. Assert both owners and their memberships before measuring.

1. POST `/mcp` `tools/list` for A and B. Save ordered names. A must have task
   tools. B must have exactly six chat tools in profile order and no task tool.
2. Call `task_list` as B with no filters. Capture JSON-RPC `-32001`.
3. In the dev node call `Grants.grant(%{principal: G, permission: "tasks.read",
   resource: {:project, P.id}})` and record its grant id. Repeat B's list and
   `task_list`: only `task_list` is added among task tools, and exactly P's two
   task ids return. Revoke the specific grant and confirm B's list is byte and
   order equivalent to step 1.
4. Call `task_list` as A and confirm Q's two ids. Deny M `tasks.read` on Q;
   repeat. Q ids disappear and P ids remain. Record the deny id and the exact
   before/after id sets.

Evidence: owner/membership/profile assertions, ordered name lists, `-32001`
response, grant/deny ids, and task id sets for each step. Do not label a case
passed if either the positive grant or negative deny control cannot be observed.

## Case 2: direct and code-mode authorization

Seed root admin RA, active runtime R with profile
`federation space context_read messaging task code_mode`, restriction `nil`, and
task T. Keep R's token private. Confirm a `suite_run` script calling
`suite.task_update` changes T's title to `e2e-1`.

Build the explicit restriction map from R's **currently held** permissions,
omitting `tasks.write`. Call `RuntimeProfiles.restrict(R, map)` in the dev node.
Then save `tools/list` and `suite_run_describe`; `task_update` must be absent
from both. Run inner calls through `suite.task_update` and
`suite.call("task_update", ...)`, and a direct `tools/call task_update`. The
two scripts must return `ok:false`, `kind:"forbidden"`; direct call must return
`-32001`; T must still be `e2e-1`. Query recent `dispatch_tool_calls` rows for
R (tool, status, parent_run_id only): the two inner calls must be `denied` and
linked to their parent run ids. Restore `restrict(R, nil)` and confirm the
positive control updates T to `e2e-5`.

Evidence: T titles after every call, both catalogues, redacted JSON-RPC
responses, and narrow ledger rows. A title change during restriction or an
inner ledger status `ok` fails even if a later retry behaves correctly.

## Case 4: rail and own-agent management

Seed internal root members U and V (neither admin), root admin RA, and guest G.
As V, register VA via the actor-checked Federation API and pin VA to empty
responsibility X. Leave Y empty. Use separate U and RA browser sessions.

1. As U inspect Agents tile on desktop, 375px bottom rail and More sheet.
   Federate `u-agent` through onboarding. Capture a redacted screenshot of the
   token being shown once; query only whether `owner_user_id == U.id`.
2. As U edit `u-agent`: untick one profile module, enable restriction and
   untick one permission. Reload and compare the stored profile and restriction
   to those choices.
3. Open VA as U. Capture absence of write controls. Call actor-checked
   `Federation.generate_runtime_token/2`,
   `RuntimeProfiles.set_tool_profile/3`, and `Roles.unassign_role/2` as U.
   Each must return `{:error, :unauthorized}`. Compare VA's token hash by
   equality **without printing it**, its profile row, and X pin before/after.
4. As U assign `u-agent` to Y and remove it. As RA remove VA from X.
5. As G request `/control` and `/chat`: access page for `/control`, no Agents
   tile in G's rail.

Evidence: screenshots for all three U rail surfaces, onboarding token display
with token redacted, persisted profile/restriction, VA control state, three
unauthorized results, boolean unchanged comparisons, Y/X assignment results,
and G route/rail screenshots. Stage 4 behavior must be served from the final
branch; a disconnected LiveView is an invalid measurement.

## Case 3 ruling to apply before review

The current case text is stale. Rowan accepted removal of
`play_session_start`, `play_session_stop`, and `play_session_status` from C/K/N,
and N must be root-admin-owned after a human promotion in production. Raw
base/branch response hashes for C/K/N cannot be equal when those names are
removed. The case must be amended by an independent reviewer/operator before
evaluation: compare raw hashes and report the expected Play-only mismatch,
then compare ordered definitions after removing those three names from both
sides. Keep exact array-order and rollback checks. Do not self-amend or grade
the stale case as passing. If a non-Play definition differs or any other tool
is lost, fail and name the runtime.
