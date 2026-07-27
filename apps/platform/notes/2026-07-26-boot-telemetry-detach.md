# 2026-07-26 boot-attached TelemetryHandler detach — control baseline and root cause

Task: `019f9d80-e1ac-737c-bfd3-7846e2de6469`, stage 1
("Pin both mechanisms and record a control baseline").
Merge base / control commit: `b19eee64150074aedd9223f10683cdaae7885667`
("Fix three independent breaks in the stack-member deploy path (#615)").

**No product code changes in this stage.** Its deliverable is the measurement
protocol and the two mechanism verdicts. Stages 2–5 are compared against the
tables here.

---

## 0. Why the baseline is the deliverable

The suite carries roughly one flaky failure per full run *independent of any
diff*. A single green run at the end of the task would therefore prove nothing:
it is indistinguishable from a run that got lucky.

**What would distinguish "fixed" from "got lucky":**

| Claim | Evidence that supports it | Evidence that does NOT |
|---|---|---|
| Mechanism A is fixed | The ordered pair `historian_latency_test.exs` + `external_admission_notifier_test.exs` goes from 10/10 RED (see §2) to 10/10 GREEN at the same ten fixed seeds. Determinism on both sides is the point — a 100 %→0 % transition cannot be luck. | One green ordered-pair run. One green full-suite run. |
| The fix restores global state, rather than making the assertion pass | After every offender file has run in one BEAM, all seven boot-attached handler ids are present, each exactly once (§1). | The previously-failing assertion now passing. That is satisfiable by deleting the assertion, by reordering, or by attaching a *different* handler. |
| No regression was introduced | The fix-branch failing SET at each of the three fixed full-suite seeds is a **subset** of the control failing set at that seed (§3). Any failure not in §3's enumeration is a stop, not a flake. | A lower failure *count*. Counts are the wrong unit — the control's failing set differs run to run. |

The reasoning error this table exists to prevent is the one that kept this bug
alive: **an audit assertion that passes because nothing is listening is
indistinguishable from one that passes because the system behaved correctly.**

---

## Mandatory environment

Every measurement in this file was taken under:

```
export PLATFORM_TEST_DATABASE=platform_test_019f9d80_ctl   # control worktree
export PLATFORM_TEST_DATABASE=platform_test_019f9d80       # fix worktree
MIX_ENV=test mix ecto.create && mix ecto.migrate
rm -rf /tmp/git-repo-* /tmp/wt-root-*                      # before each full run
```

`config/test.exs:15` reads `PLATFORM_TEST_DATABASE` and defaults every worktree
to the shared `platform_test`. The ADR-0046 stack runs concurrently on this box,
and `plan_engine_architect_drift_hook_test.exs:472` takes an `ACCESS EXCLUSIVE`
lock that is sound within one BEAM but not across two `mix test` OS processes.
Cross-process deadlocks surface as Postgrex `40P01` and look exactly like app
flakes. 21 stale `git-repo-*` / `wt-root-*` dirs were cleared from
`System.tmp_dir!()` before the first run, or `LocalRunnerTest` fails for
unrelated reasons.

Control worktree: `~/sources/worktrees/019f9d80-ctl`, detached at `b19eee64`,
`git status --porcelain` empty for every measured run.

---

## 1. Work item A — blast radius of mechanism A

`grep -rn "TelemetryHandler.detach\|:telemetry.detach" apps/platform/test`
returns 178 lines at branch head. The overwhelming majority are **not** in
scope: they detach a per-test handler id (`:telemetry.detach(handler_id)`,
`:telemetry.detach(ref)`, `:telemetry.detach({:telemetry_test, self(), ref})`)
that the same test attached. Those are correct and self-contained.

In scope is any test that detaches a **globally boot-attached** handler.
Seven handlers are boot-attached in `Platform.Application.start/2`
(`lib/platform/application.ex:12-27`):

| Module | `@handler_id` | `attach/0` idempotent? |
|---|---|---|
| `Platform.Audit.TelemetryHandler` | `platform-audit-telemetry` | no (`telemetry_handler.ex:184-186`) |
| `Platform.Vault.TelemetryHandler` | `platform-vault-telemetry` | no (`:53-55`) |
| `Platform.Chat.TelemetryHandler` | `platform-chat-telemetry` | no (`:49-51`) |
| `Platform.Meetings.TelemetryHandler` | `platform-meetings-telemetry` | no (`:53-55`) |
| `Platform.Meetings.IntentCorrections.TelemetryHandler` | `platform-meetings-intent-corrections` | no (`:73-75`) — `@spec` already admits `{:error, :already_exists}` |
| `Platform.Memory.TelemetryHandler` | `platform-memory-telemetry` | no (`:19-21`) — `@doc` already *claims* "Idempotent"; the code is not |
| `Platform.Accounts.ExternalAdmissionNotifier` | `external-admission-notifier` | **yes** (`external_admission_notifier.ex:58-63`) — the gold-standard reference |

### Five offenders (detach a boot-attached handler, never restore)

Verified against branch head, not transcribed on faith:

1. `test/platform/audit/historian_latency_test.exs:32` — `Platform.Audit.TelemetryHandler`
2. `test/platform/audit/telemetry_handler_test.exs:15` — `Platform.Audit.TelemetryHandler`
3. `test/platform/federation/tool_surface_alarm_silence_test.exs:347` — `Platform.Audit.TelemetryHandler`
4. `test/platform/meetings/telemetry_handler_test.exs:21` — `Platform.Meetings.TelemetryHandler`
5. `test/platform/vault/telemetry_handler_test.exs:12` — `Platform.Vault.TelemetryHandler`

The brief named only #1 and #2. **The blast radius is five files across three
different handlers**, which is why any guard for this must derive its module set
from `application.ex` source rather than hardcode it: `Meetings.TelemetryHandler`
and `IntentCorrections.TelemetryHandler` were boot-attached *after* the offending
tests were written, and a list frozen at that time would have missed #4 and #5.

Note the call shapes differ: #3 is fully qualified
(`Platform.Audit.TelemetryHandler.detach()`); #1, #2, #4, #5 use a bare alias
(`TelemetryHandler.detach()`) resolved by a file-local `alias`. A matcher that
only handles the fully-qualified form goes blind on four of the five.

### Five files already restore correctly

This establishes that restoring is the **existing in-repo convention** and the
five above are drift off it — the argument against hand-patching a sixth
`on_exit` block:

- `test/platform/federation/tool_surface_files_test.exs:1387-1393`
- `test/platform/files/purger_test.exs:115-130`
- `test/platform/files/soft_delete_test.exs:76-84`
- `test/platform/tenancy/lifecycle_test.exs:492-498`
- `test/platform/tenancy/lifecycle_test.exs:811-817`

All use `on_exit(fn -> detach(); attach() end)`.

### Two additional sites, examined and NOT counted as offenders

- `test/platform/meetings/telemetry_handler_test.exs:47` — a **mid-body** detach
  inside "detach removes the handler; re-attach re-installs it", re-attached at
  `:55` on the success path only. Not a sixth offender (the module setup already
  leaks via `:21`), but it is the reason a per-file `on_exit(detach(); attach())`
  idiom is insufficient: any failure between `:47` and `:55` leaks a detached
  global handler for the rest of the run.
- `test/platform/meetings/intent_corrections/telemetry_handler_test.exs:89` —
  `if result == :ok, do: TelemetryHandler.detach()`. Self-cancelling: the detach
  only fires when the immediately preceding `attach()` unexpectedly *succeeded*,
  so it restores the pre-call state rather than degrading it. Net-neutral, and
  the file's moduledoc explicitly documents the reasoning ("This module never
  calls `detach/0` … the exact shape of the `Platform.Audit.TelemetryHandler`
  leak already recorded in org memory"). Belongs in a guard's `@known_safe` with
  that reason written down, not in the offender list.

---

## 2. Work item B — ordered-pair control (mechanism A)

Untouched control worktree at `b19eee64`, DB `platform_test_019f9d80_ctl`,
ten fixed seeds:

```
mix test test/platform/audit/historian_latency_test.exs \
         test/platform/accounts/external_admission_notifier_test.exs --seed $S
```

| seed | exit | result | failing test |
|---|---|---|---|
| 0 | 2 | 6 tests, 1 failure | `Platform.Accounts.ExternalAdmissionNotifierTest` "a holding event persists an Audit.Event (durable queue source)" |
| 1 | 2 | 6 tests, 1 failure | same |
| 2 | 2 | 6 tests, 1 failure | same |
| 3 | 2 | 6 tests, 1 failure | same |
| 4 | 2 | 6 tests, 1 failure | same |
| 5 | 2 | 6 tests, 1 failure | same |
| 6 | 2 | 6 tests, 1 failure | same |
| 7 | 2 | 6 tests, 1 failure | same |
| 8 | 2 | 6 tests, 1 failure | same |
| 9 | 2 | 6 tests, 1 failure | same |

**10/10 RED. The premise holds, and it is stronger than the brief claimed:
this is not seed-sensitive, it is deterministic.** The task's stated "seed 0
gives 6 tests, 1 failure" reproduces at every seed 0–9.

Verbatim failure body (seed 0):

```
  1) test a holding event persists an Audit.Event (durable queue source) (Platform.Accounts.ExternalAdmissionNotifierTest)
     test/platform/accounts/external_admission_notifier_test.exs:138
     Expected truthy, got false
     code: assert Enum.any?(rows, fn ev -> ev.action == "holding" and ev.actor_id == user.id end)
     arguments:

         # 1
         []

         # 2
         #Function<3.30698697/1 in Platform.Accounts.ExternalAdmissionNotifierTest."test a holding event persists an Audit.Event (durable queue source)"/1>

     stacktrace:
       test/platform/accounts/external_admission_notifier_test.exs:151: (test)
```

The assertion receives `[]` — no `Audit.Event` rows at all.

### The single-file run is green — the original blind spot, reproduced

```
mix test test/platform/accounts/external_admission_notifier_test.exs --seed 0
=> 5 tests, 0 failures     (exit 0)
```

**A guard exercising one file recreates the blind spot exactly.** The
reproduction must be the two-file run in one BEAM.

### Correction to the "ordered pair" framing

CLI argument order does **not** control execution order. Reversing the two paths
on the command line still fails, and `--trace` shows why:

```
mix test test/platform/accounts/external_admission_notifier_test.exs \
         test/platform/audit/historian_latency_test.exs --seed 0 --trace

Platform.Audit.HistorianLatencyTest [test/platform/audit/historian_latency_test.exs]
  * test historian window_dispatched emit p99 stays under 1ms across 10000 events [L#37]
Platform.Accounts.ExternalAdmissionNotifierTest [test/platform/accounts/external_admission_notifier_test.exs]
  ...
  * test a holding event persists an Audit.Event (durable queue source) [L#138]
```

`HistorianLatencyTest` runs first either way. Both files are `async: false`
(`historian_latency_test.exs:22`, `external_admission_notifier_test.exs:16`);
ExUnit's sync-module ordering here is not the CLI arg order. The invariant to
state in CI is therefore "these two files in the same BEAM", not "in this
order" — the command is the same, but a later reader must not assume the
argument order is doing the work.

---

## 3. Work item C — full-suite control

Untouched control worktree at `b19eee64`, DB `platform_test_019f9d80_ctl`,
quiescent tree, `/tmp/git-repo-*` + `/tmp/wt-root-*` cleared before each run,
three fixed seeds. Reported as the failing **set**, not the count — the count is
the wrong unit, because the control's failing set differs run to run.

Every run: `16 doctests, 8216 tests, 3 skipped (2 excluded)`.

| seed | exit | failures | failing set |
|---|---|---|---|
| 0 | 0 | 0 | ∅ |
| 1 | 2 | 5 | `TaskRouterTest:1039` (`terminate/2` clears the LeaseManager row)<br>`TaskRouterTest:479` (failed review stage bounces in_review → in_progress)<br>`TaskRouterTest:758` (safety-net fire: deadline in the past)<br>`LocalRunnerTest:92` (injects credential lease env into the child process)<br>`ExternalAdmissionNotifierTest:138` (holding event persists an Audit.Event) |
| 2 | 2 | 2 | `LocalRunnerTest:92`<br>`TaskRouterTest:1039` |

### Known-independent failures, enumerated by name for stage 5 to subtract

Stage 5's bar is that the fix-branch failing set at each seed is a **subset** of
the control set at that seed. Anything outside this enumeration appearing on the
fix branch is a **stop**, not a flake:

- `Platform.Orchestration.TaskRouterTest` sandbox / liveness cluster —
  `:1039`, `:479`, `:758` observed here; the cluster is known to produce a
  different subset each run.
- `Platform.Execution.LocalRunnerTest:92` — "injects credential lease env into
  the child process". **New to the list; name it.** Failed at seeds 1 and 2,
  passed at seed 0, with `/tmp/git-repo-*` and `/tmp/wt-root-*` cleared before
  every run — so it is *not* the stale-tmp-dir class it is usually filed under.
  Failure shape: `assert String.trim(File.read!(output_file)) == "test-token-…"`
  → `left: ""`. The spawned child had not yet written its output file. A
  spawn/read race, unrelated to this task.
- `Platform.MeetingsTest:416` — cross-test PubSub leak (the reviewer's control
  at the earlier branch point; did not fire in these three runs).
- `AttentionRouterTest:753` — eye-as-mutex TTL expiry under full-suite load.
- `Org.Wiki.IndexerT3E2ETest` — burst-dedupe tick race.
- `CleanupGhostTasksTest` — `DBConnection.OwnershipError` from
  `RuntimeSupervision.expire_stale_leases/2` (filed separately as
  `019fa06a-a413`).
- **`Platform.Audit.TelemetryHandlerTest`'s historian emit p99 wall-clock budget
  assertion — this is a WALL-CLOCK flake, independently reproduced at 2 failures
  in 10 consecutive single-file runs on a clean `bbf4c0c2` control worktree
  (`p99=6961µs`, `p99=12134µs`). It lives inside a file this task edits and WILL
  be mistaken for a regression. It is NOT cross-file pollution and it must NOT
  be "fixed" here.**

### The one-flake-per-run premise, demonstrated on a zero-code diff

The stage-1 branch (`task/019f9d80`) adds exactly one file — this markdown
document. No `lib/`, no `test/`, no config. Full suite on that branch, DB
`platform_test_019f9d80`, seed 0:

```
16 doctests, 8216 tests, 1 failure, 3 skipped (2 excluded)
  1) test PubSub event handling completed plan transitions in_review task to deploying
     (Platform.Orchestration.TaskRouterTest)
     test/platform/orchestration/task_router_test.exs:412
     Assertion with == failed
     code:  assert updated_task.status == "deploying"
     left:  "in_review"
     right: "deploying"
```

Focused rerun `mix test test/platform/orchestration/task_router_test.exs
--seed 0` — **3/3 green, 66 tests each time.**

The control at the same seed was 0 failures; this branch at the same seed is 1
failure; the diff between them cannot cause a test failure. That is the
one-flake-per-run premise, measured rather than asserted. It is also why the
comparison unit in stage 5 must be the failing SET across seeds and not a single
run's count.

`TaskRouterTest:412` joins `:479`, `:758`, `:1039` in the named cluster above.

The ordered pair is red on this branch too (`6 tests, 1 failure`, seed 0), as it
must be — stage 1 changes no product code.

### The full suite is NOT a detector for mechanism A

Seed 0 ran the whole suite **green** while the two-file ordered pair at the same
seed 0 was **red** (§2). Whether `ExternalAdmissionNotifierTest:138` fires in a
full run depends on whether `historian_latency_test.exs` happens to be scheduled
before it, which the seed permutes.

Two consequences, both load-bearing:

1. **A green full suite is not evidence that this bug is fixed.** It was green at
   seed 0 on a tree where the bug was 100 % reproducible. Stage 5 must lead with
   the ordered-pair table; the full-suite table is only there to prove nothing
   else regressed.
2. It explains the eight-brief write-off directly. Executors ran the full suite,
   saw the failure appear and disappear across seeds, and reasonably-looking
   inferred "flake". The variability was real; the conclusion drawn from it was
   wrong. Intermittency in a full run is not evidence of non-determinism in the
   underlying defect.

---

## 4. Work item D — mechanism B's actual route: **B1, MISATTRIBUTION**

The reported route was `DBConnection.OwnershipError` raised inside
`Platform.Audit.TelemetryHandler.persist_or_skip/4` on a `Task.Supervised` child
whose sandbox owner had exited, on the external-admission path.

**That is not what happens.** Determined by instrumentation, not by reading:

1. A probe was added to the failing test printing the handler ids attached to
   `[:platform, :auth, :external_admission]` immediately before the emit.
2. The `rescue DBConnection.OwnershipError` clause at
   `telemetry_handler.ex:297` was temporarily widened to
   `e in DBConnection.OwnershipError ->` and made to print the event name, the
   `self()` pid, and the full `Exception.format(:error, e, __STACKTRACE__)`.

Both were reverted; `git status --porcelain` is empty on the control worktree.

### Result — ordered pair (RED run)

```
PROBE audit_attached_for_external_admission=false
PROBE external_admission_handlers=["external-admission-notifier"]
grep -c "PROBE OWNERSHIP_ERROR"  =>  0
```

### Result — single file (GREEN run)

```
PROBE audit_attached_for_external_admission=true
PROBE external_admission_handlers=["platform-audit-telemetry", "external-admission-notifier"]
5 tests, 0 failures
```

**Verdict: B1.** In the failing run `platform-audit-telemetry` is not attached
to the event at all, so `persist_or_skip/4` never executes for it, so no
`OwnershipError` can arise from it — and indeed the widened rescue fired **zero
times across the entire ordered-pair run**. Mechanism A alone accounts for the
symptom, completely and deterministically.

### Where the sandbox-ownership noise actually comes from

It is real, it is just a different route, and it belongs to
`HistorianLatencyTest`, not to the external-admission emit. The same run
produced 21 log entries of this shape:

```
[error] Postgrex.Protocol (#PID<0.446.0> ("db_conn_4")) disconnected:
  ** (DBConnection.ConnectionError) owner #PID<0.550.0> exited

Client #PID<0.899.0> (Task.Supervised) is still using a connection from owner at location:
    ...
    (platform 0.1.0) lib/platform/audit.ex:42: Platform.Audit.record/1
    (platform 0.1.0) lib/platform/audit/telemetry_handler.ex:274: Platform.Audit.TelemetryHandler.persist_or_skip/4
    (elixir 1.19.5) lib/task/supervised.ex:105: Task.Supervised.invoke_mfa/2
```

These are the 10 000 async historian children spawned by
`telemetry_handler.ex:197`, outliving `HistorianLatencyTest`'s sandbox owner.
They appear in the log immediately after the `historian emit latency (µs) over
10000 events: p50=42 p95=98 p99=189` line and before the external-admission
cases start. **This is the noise that was read as the cause.**

### Secondary finding, handed forward to stage 3

The exception here is `DBConnection.ConnectionError`, **not**
`DBConnection.OwnershipError`. So the `rescue DBConnection.OwnershipError`
clause at `telemetry_handler.ex:297-301` — whose comment says it exists exactly
for "`Task.Supervisor.start_child` callers under `Platform.TaskSupervisor`" —
**does not catch this case**. Counts from the instrumented run:

| | count |
|---|---|
| `PROBE OWNERSHIP_ERROR` (the rescue firing) | 0 |
| `"Audit handler crashed"` (the generic rescue firing) | 0 |
| `DBConnection.ConnectionError` in the log | 21 |

The child exits `shutdown: %DBConnection.ConnectionError{…}` — a process exit,
not a raise inside `persist_or_skip/4` — so neither `rescue` clause is reachable
for it. The guard is written for an exception the async path does not actually
produce. Stage 3 should treat this, not the phantom external-admission route, as
the real thing to harden.

**Coordination note.** Sibling tasks `019fa003-091a` (a
`Platform.Orchestration.SandboxGuard` ownership primitive for
`TaskRouterWatcher`) and `019fa06a-a413` (`CleanupGhostTasksTest` failing 5/5 on
`DBConnection.OwnershipError` from `RuntimeSupervision.expire_stale_leases/2`)
are the same family. If `SandboxGuard` lands an ownership/liveness primitive,
stage 3 should adopt it rather than build a parallel one — but note that this
particular route is a *ConnectionError on owner exit*, not an OwnershipError on
a missing owner, so check the primitive actually covers it before assuming.

---

## 5. Follow-ups flagged, deliberately NOT fixed in this task

**`.github/workflows/ci.yml:87` masks exactly this class of bug.** The step is
`mix test || (echo "::warning::…" && mix test --failed --max-cases 1)`. The
retry reruns only the failed tests, serially — which *reorders* them. A genuine
cross-file ordering failure therefore turns green on the retry and is reported
as a warning, not a failure. That retry is a structural reason this bug survived
CI. Removing it will surface the unrelated known flakes enumerated in §3 and
turn CI red for reasons this task does not own, so it is recorded here as a
named follow-up rather than changed.

---

## 6. The write-off is part of the finding

`ExternalAdmissionNotifierTest:138` was dismissed as a "known unrelated flake —
cross-file pollution" in roughly eight execution and review briefs across
2026-07-25/26. It was never a flake: §2 shows it failing 10/10 at ten fixed
seeds, deterministically.

Once the fix lands, a failure there is REAL. The standing known-bad list must
lose that entry (stage 5) or the next agent keeps dismissing a now-real failure.
The `Platform.Audit.TelemetryHandlerTest` **p99 budget** entry must stay, but
correctly relabelled as a wall-clock latency flake rather than cross-file
pollution — it lives in a file this task edits and will otherwise be misread as
a regression. Mislabelling one flake as another is what made this bug invisible;
the precision is the point.

---
---

# Stage 2 — the fix, and what the mutation check actually proved

Task `019f9d80-e1ac-737c-bfd3-7846e2de6469`, stage 2
("Make boot-handler attach idempotent and add a restoring test helper").
Branch `task/019f9d80`, parent `331bf1d5` (stage 1).
All measurements below: worktree `~/sources/worktrees/019f9d80`,
`PLATFORM_TEST_DATABASE=platform_test_019f9d80`, control worktree
`~/sources/worktrees/019f9d80-ctl` at `b19eee64` with
`PLATFORM_TEST_DATABASE=platform_test_019f9d80_ctl`.

## 7. What changed

`attach/0` is now idempotent on all six boot-attached handlers that were not
(`{:error, :already_exists} -> :ok`), mirroring
`accounts/external_admission_notifier.ex:58-63`. `@spec attach() :: :ok` on each,
including `IntentCorrections.TelemetryHandler` whose spec previously admitted the
error tuple.

`test/support/telemetry_helpers.ex` is new:
`Platform.TelemetryHelpers.ensure_boot_handler!/1` attaches the module and
registers an **unconditional** `on_exit(fn -> module.attach() end)`.

The five offenders now call it instead of `detach(); attach(); on_exit(detach)`:
`audit/historian_latency_test.exs`, `audit/telemetry_handler_test.exs`,
`federation/tool_surface_alarm_silence_test.exs`,
`meetings/telemetry_handler_test.exs`, `vault/telemetry_handler_test.exs`.
The false rationale comment at `historian_latency_test.exs:28-29` is deleted with
the code it justified: `:telemetry` keys by a fixed `@handler_id`, so the
double-fire it claimed to prevent was never possible.

### A sixth site the stage-2 plan did not name, which idempotency turns INTO a leak

`meetings/intent_corrections/telemetry_handler_test.exs:89` read:

```elixir
result = TelemetryHandler.attach()
if result == :ok, do: TelemetryHandler.detach()
assert {:error, :already_exists} = result
```

Stage 1 correctly classified this as self-cancelling **while `attach/0` still
returned `{:error, :already_exists}`**. Making `attach/0` idempotent inverts it:
`result` becomes `:ok` unconditionally, so the detach fires unconditionally — in
an `async: true` file — and the file becomes a new offender created by the fix
itself. It is rewritten to assert the boot attach is already present *before*
calling `attach/0` (which preserves the anti-masking property the old comment was
protecting) and then to assert exactly one registration remains. It never
detaches. The file's moduledoc claim "This module never calls `detach/0`" is now
true, which it was not before.

## 8. Ordered pair — the mechanism-A regression check

Same command as §2, same worktree, before and after the diff.

| | seeds 0-9 |
|---|---|
| Before (this worktree, pre-fix) | seed 0: `6 tests, 1 failure` — `ExternalAdmissionNotifierTest` "a holding event persists an Audit.Event (durable queue source)", assertion receiving `[]`. Matches §2's control 10/10 exactly. |
| After | **10/10 GREEN**, `6 tests, 0 failures` at every seed 0-9. Plus 5 extra runs at seed 0: green. |

A 100 %→0 % transition on a deterministic reproduction, per §0's table.

### One post-fix seed-0 failure, named rather than waved through

The **first** post-fix sweep reported `6 tests, 1 failure` at seed 0; that sweep
only captured counts, so the failing test's name was lost. Rather than match it
to a flake list — the habit that created this task — the class was reproduced
directly, in this worktree, on this diff:

```
mix test test/platform/audit/historian_latency_test.exs --seed 0   (x10)
run  1: FAIL  p99=2577µs
runs 2-9: pass p99=294..436µs
run 10: FAIL  p99=3056µs
```

**2/10**, the same rate §3 measured on a clean control, on the single file that
contains a wall-clock budget assertion (`@p99_budget_us 1_000`). The 15
subsequent seed-0 ordered-pair runs recorded above are all green, and
`ExternalAdmissionNotifierTest:138` did not fail in any of them. This is the §3
p99 wall-clock entry, measured here rather than assumed here.

## 9. Mutation check — the plan's version does NOT go red, and why that matters

The stage-2 plan specified: delete the `on_exit` re-attach inside
`ensure_boot_handler!/1`, rerun the ordered pair, expect RED.

**Run it and it stays GREEN** (`6 tests, 0 failures`, seed 0 — probe M0 below).
That is not a defective guard; it is the plan's causal model being off by one
step. What fixes mechanism A is that `historian_latency_test.exs`'s setup **no
longer detaches at all** — idempotent `attach/0` removed the reason to. The
`on_exit` is not what repairs the existing five offenders; it is what makes a
*future* detach, or a mid-body detach, harmless. Deleting it therefore cannot
turn the ordered pair red, because with the setup detach gone there is nothing
left to restore.

So the mutation must reintroduce the condition the `on_exit` defends. Probe:
inject `TelemetryHandler.detach()` into `historian_latency_test.exs`'s setup —
i.e. simulate exactly the mid-body/legacy detach the helper exists for — and vary
only the `on_exit` line.

| probe | `on_exit` restore | injected detach | ordered pair, seed 0 |
|---|---|---|---|
| M0 (the plan's mutation, verbatim) | deleted | no | `6 tests, 0 failures` — GREEN |
| **M1** | **deleted** | **yes** | **`6 tests, 1 failure`** — `ExternalAdmissionNotifierTest` "a holding event persists an Audit.Event (durable queue source)", `Expected truthy, got false`, arguments `[]` — byte-for-byte the §2 failure |
| **M2** | **restored** | **yes** | **`6 tests, 0 failures`** — GREEN |

M1 vs M2 isolates the `on_exit` as the only difference and shows it is
load-bearing: with a detach present, deleting the restore reproduces the original
defect exactly. Both probes were reverted; the committed tree contains neither.

A note for whoever writes stage 4's guard: **M0 is the more important row.** It
says the ordered pair does not detect a missing restore once the setup detach is
gone. A guard that watches only the ordered pair would pass a future test that
detaches and never restores, right up until that test's file happens to precede a
victim. The guard has to be static (no `detach` of a boot handler without a
restoring `on_exit`, and none at all in an `async: true` file), not behavioural.

## 10. Full suite

`mix format --check-formatted` → clean (`FORMAT_OK`).

Baseline is 8216 tests (§3). This stage adds 4, all in
`audit/telemetry_handler_test.exs`: `attach/0` returns `:ok` when already
attached (table over all seven boot-attached handlers); a repeated `attach/0`
installs one registration, not two; `ensure_boot_handler!/1` re-attaches a
detached handler; `ensure_boot_handler!/1` raises on a module without `attach/0`.

| tree | seed | result | failing set |
|---|---|---|---|
| fix `task/019f9d80` | 0 | `16 doctests, 8220 tests, 1 failure, 3 skipped` | `Platform.Tasks.PlanTest:398` (§10.1) |
| fix `task/019f9d80` | 0 (rerun) | `16 doctests, 8220 tests, 0 failures, 3 skipped` | ∅ |
| control `b19eee64` | 0 | `16 doctests, 8216 tests, 1 failure, 3 skipped` | `Platform.Chat.AttentionRouterTest` "the eye falls closed on TTL expiry…" (named in §3) |
| fix `task/019f9d80` | 1 (ran 00:35-00:41 UTC) | `16 doctests, 8220 tests, 5 failures, 3 skipped` | `TaskRouterTest:1039`, `TaskRouterTest:964`, `TaskRouterTest:412`, `TaskRouterTest:758`, `HistorianDispatcherTest:322` (§10.2) |
| fix `task/019f9d80` | 1 (rerun 01:06-01:13 UTC) | `16 doctests, 8220 tests, 1 failure, 3 skipped` | `LocalRunnerTest:92` |

Note the control at seed 0 produced a failure here where §3 recorded ∅ for the
same commit at the same seed — the one-flake-per-run premise, again, on
byte-identical code.

**The seed-1 comparison is the informative one.** §3's control at seed 1 failed
`{TaskRouterTest:1039, :479, :758, LocalRunnerTest:92,
ExternalAdmissionNotifierTest:138}`. On the fix branch at seed 1,
`ExternalAdmissionNotifierTest:138` is **gone** from both runs — mechanism A
surfacing in a full run at the one control seed where it surfaced, and no longer
firing. Both fix-branch seed-1 sets are subsets of the control's once §10.2 is
subtracted; `TaskRouterTest:964` ("silence + prior ack → `:check_no_ack` silent",
`MatchError` on `LeaseManager.record_ack/1` returning `{:error, :not_found}`) is
a new member of the TaskRouter sandbox/liveness cluster §3 already names as
producing a different subset each run.

### 10.1 `Platform.Tasks.PlanTest:398`

A new entry for the known-independent list.

```
test broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan}
  assert id2 == v2.id
  left:  "019fa0e3-db97-7020-b707-166608a9c75c"
  right: "019fa0e3-dbf9-7df0-8d44-5406e3b6ca73"
```

Not in §3's enumeration, so per §0 it is a stop until explained. Explanation,
mechanical rather than by resemblance:

- `plan_test.exs:2` is `async: true` and the test subscribes to
  `Tasks.subscribe_board()` — a **single global topic** (`tasks.ex:3611`,
  `broadcast_board/1`, unfiltered by task).
- `{:plan_updated, plan}` is broadcast from six call sites in `Platform.Tasks`
  (`:1536`, `:1860`, `:1863`, `:2134`, `:2209`, `:2318`), and **13 other
  `async: true` test files** approve plans (`tasks_context_test.exs`,
  `plan_engine_test.exs`, `stage_test.exs`, `validation_test.exs`,
  `task_test.exs`, `auto_merger_test.exs`, `review_requests_test.exs`,
  `queries_test.exs`, `deploy_rollback_test.exs`,
  `review_request_inbox_test.exs`, `deploy_credentials_test.exs`,
  `github_webhook_controller_test.exs`, `submit_plan_for_review_architect_hook_test.exs`).
- The test's second `assert_receive` matches on `status: "approved"` only, so any
  concurrent file's approval binds `id2`. The observed id is a UUIDv7 whose
  timestamp is ~98 ms *earlier* than `v2` — a plan that already existed before the
  operation under test, which the operation under test cannot have produced.
- `approve_v1/1` runs *before* `subscribe_board/0`, and `Phoenix.PubSub` does not
  deliver to a process that subscribed afterwards, so it is not v1 either.

That is a cross-test PubSub leak in the test's own design — the same class as the
`MeetingsTest:416` entry in §3, at a new site. No telemetry handler broadcasts
`{:plan_updated, _}` (`audit/telemetry_handler.ex` only writes rows), so handler
attachment cannot cause it. Not reproduced on the fix branch rerun at the same
seed, nor in 10 seeds of a 401-test targeted subset of the nine board-broadcasting
async files on the control — full-suite scheduler load appears to be required.

**Add `Platform.Tasks.PlanTest:398` to the known-independent list for stage 5,
with the mechanism above written next to it.** The nearby cases at
`plan_test.exs:479` and `:584` subscribe to the same global topic and are
vulnerable to the same leak; they have not been observed failing.

### 10.2 `Platform.Agents.HistorianDispatcherTest:322` — broken for one hour a day, and it is a clock bug, not a flake

This one looked like a regression: it is historian-adjacent, it is in the blast
radius of "the Audit handler is now reliably attached during historian emits",
and unlike everything else in §3 it failed **deterministically** — 3/3 on the fix
branch in a single-file run. The temptation to file it under §3's p99 entry
(same file family, same "historian" in the name) is exactly the move that kept
the original bug alive for eight briefs, so it was not made.

```
test (a) 120KB transcript, tight-range oversize path stamps day_bytes on today
  expected a transcripts telemetry event on 2026-07-27 with day_bytes ≈ 120_000, got: []
```

Measured, in this order:

| tree | wall clock (UTC) | seeds 1,2,3 |
|---|---|---|
| fix `task/019f9d80` | 00:41-00:47 | **3/3 RED** |
| control `b19eee64`, `git status --porcelain` empty | 00:47-00:53 | **3/3 RED** |
| fix `task/019f9d80` | 01:05 | **3/3 GREEN** |

The untouched branch-point control fails it identically at the same wall clock,
so it is not this diff. And the transition at 01:00 UTC names the mechanism:

`historian_dispatcher_test.exs:328-332` builds `now = DateTime.utc_now()` and
`one_hour_ago = now - 3600s`, then at `:398-405` filters the drained telemetry
events by

```elixir
String.starts_with?(meta.day_span, DateTime.to_iso8601(one_hour_ago) |> String.slice(0, 10))
```

— the UTC **date of `now - 1h`** — while the seeded transcript
(`thirty_min_ago`) and the per-day byte histogram are keyed on the UTC date of
`now`. Between 00:00 and 01:00 UTC those two dates differ, the filter matches
nothing, and the assertion receives `[]`. The test's own failure message betrays
the inconsistency: it reports "on 2026-07-27" (`today_utc`, from `now`) while
filtering for `2026-07-26`. Outside that hour the two dates coincide and the test
passes.

So: a genuine test defect, live for one hour in every 24 on any machine running
the suite in that window, pre-dating this task. The fix is one line — filter on
`today_utc` rather than on `one_hour_ago`'s date (or pin the cursor with
`DateTime.new!(today_utc, ~T[00:30:00])` so the tight range cannot straddle
midnight) — but it is outside the stage-1 scope fence and is left to a follow-up.

**Add it to the known-independent list with the time window written down**, not
as "a historian flake". A reviewer who runs the suite at 00:30 UTC will see it
3/3 and, without this note, will read a deterministic failure as a regression.
