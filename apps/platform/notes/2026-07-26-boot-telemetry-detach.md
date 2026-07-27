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

---
---

# Stage 3 — the prescribed fix was wrong; what the counters showed instead

Task `019f9d80-e1ac-737c-bfd3-7846e2de6469`, stage 3
("Close the sandbox-ownership route on the audit persist path").
Branch `task/019f9d80`, parent `3e888704` (stage 2).
All measurements: worktree `~/sources/worktrees/019f9d80`,
`PLATFORM_TEST_DATABASE=platform_test_019f9d80`.

## 11. Work item — the plan's B1 remedy does not do either thing it claims

Stage 1 concluded **B1 (misattribution)**, which routed this stage to a
specific remedy: add `config :platform, :audit_persist_sync, true` to
`config/test.exs`, gate `telemetry_handler.ex`'s two async historian clauses
on it, override it back to `false` in the three tests that exercise the async
branch, and add a coverage case asserting a `[:platform, :historian,
:window_dispatched]` emit persists a retrievable `Audit.Event` — an assertion
the plan states is "impossible today — the row is thrown away by the
OwnershipError rescue."

**Measured, before writing any code: the row lands today, with no flag.**

```
PROBE rows_from_test_process=1          # Audit.list/1 after an async historian emit
PROBE child_repo_result={:ok, 0}        # Repo call from a Platform.TaskSupervisor child
```

The reason is one line of `data_case.ex`: `unless tags[:async], do:
Sandbox.mode(Repo, {:shared, self()})`. Both files in question
(`telemetry_handler_test.exs`, `historian_latency_test.exs`) are
`async: false`, so the sandbox is in **shared** mode and a spawned
`Task.Supervisor` child *inherits* the owner's connection. There is no
missing owner, so no `DBConnection.OwnershipError` is raised, so the rescue
the plan blames never runs. The insert simply succeeds.

Two consequences, and they kill the remedy:

1. **The coverage case cannot be a regression detector.** It passes on the
   untouched tree. Written as specified it is a tautology.
2. **The mutation check specified for it cannot go red.** Flipping
   `:audit_persist_sync` to `false` restores the async branch, whose write
   also lands. This is the identical off-by-one causal model stage 2 hit at
   probe M0 (§9) — the plan predicts red from removing a mechanism that was
   not what made the case pass.

And the flag cannot quiet the noise either, for a reason the plan itself
states without following through: `HistorianLatencyTest` exists to prove the
branch is asynchronous, so the plan has to override the flag back to `false`
there — reinstating the exact condition, in the exact test, that produces
100 % of the sandbox noise.

So the prescribed change buys nothing and costs a global config knob, three
test-side `Application.put_env` overrides, and an edit to a `@known_safe`
exemption. **Not implemented.** Recorded here rather than silently dropped,
per the stage's own "the one thing that is NOT permitted is quietly dropping
mechanism B".

The dispatch also asked me to check whether sibling `019fa003`'s
`Platform.Orchestration.SandboxGuard` had landed and covered this. It has
not: `git ls-tree origin/main apps/platform/lib/platform/orchestration/`
at `bf12620c` contains no `sandbox_guard.ex`. Nothing to adopt.

## 12. What is actually there — 10 011 live writers at the end of the loop

```
PROBE active_children_end_of_body=2000     # after a 2 000-event burst
PROBE stragglers_at_end_of_burst=10011     # after a 10 500-event burst
```

`Task.Supervisor.start_child` gives the spawned child **no lifecycle
relationship to the emitting process**. `HistorianLatencyTest` emits 10 500
events far faster than one shared sandbox connection can absorb 10 500
inserts, so its test body returns with ~10 000 writers still queued. The
body returns, the owner exits, and DBConnection tears the connection down
under everything mid-write:

```
[error] Postgrex.Protocol (#PID<0.429.0> ("db_conn_2")) disconnected:
  ** (DBConnection.ConnectionError) owner #PID<0.535.0> exited
** (stop) exited in: DBConnection.Holder.checkout(...)
   ** (EXIT) shutdown: %DBConnection.ConnectionError{message: "owner ... exited
      Client #PID<0.931.0> (Task.Supervised) is still using a connection ...
        (platform) lib/platform/audit/telemetry_handler.ex:286:
          Platform.Audit.TelemetryHandler.persist_or_skip/4
        (elixir) lib/task/supervised.ex:105: Task.Supervised.invoke_mfa/2
```

Note it arrives as a process **exit**, not a raise. Stage 1 §4 called this
correctly and it is confirmed here.

### Why this is not wrapped

Every one of those children is a **victim**: it is performing a real, wanted
`INSERT` and the connection dies out from under it. Widening the rescue to
`catch :exit` would convert "an audit write was destroyed and a pooled
connection was force-reconnected" into silence — the defect class this whole
task exists to end, and the same trap sibling `019fa06a` fell into before it
turned out to need `Process.flag(:trap_exit, true)` rather than a guard.

The condition is removed where it is created: **the owner waits for its
writers before releasing the connection.** No error is caught, no branch is
gated, no production code changes.

This is also an invariant the repo already *states* and was not *checking*.
`supervised_task_repo_audit_test.exs`'s `@known_safe` entry for
`StackDeployer` spells it out — "each test monitors the spawned child and
awaits its `:DOWN` before returning, so **no child outlives the sandbox
checkin**. Any FUTURE test that flips `:async` to `true` must do the same."
`HistorianLatencyTest` breaks that rule by 10 011 children, and nothing was
looking.

## 13. The prerequisite: `DataCase`'s `on_exit` drain has never worked

The obvious home for the wait was `Platform.DataCase`'s existing `on_exit`,
which already drains `AttentionRouter` and `ContextPlane` and whose comment
states it runs "before the sandbox owner exits and the connection is freed".
Putting it there **did not work**, and the probe says why:

```
PROBE on_exit_pid=#PID<0.2544.0>  test_pid=#PID<0.541.0>
PROBE test_process_alive=false
PROBE active_children_at_on_exit=2000
PROBE repo_from_on_exit={:rescued, DBConnection.OwnershipError}
```

ExUnit runs `on_exit` callbacks **in a separate process, after the test
process has already terminated**. With the old `Sandbox.checkout(Repo)` form
the *test process* is the connection owner, so by the time any `on_exit`
runs the connection is already gone. A `Repo` call from inside `on_exit`
raises `OwnershipError`.

**That makes every connection-dependent `on_exit` in `DataCase` a no-op, and
has since it was written.** The AttentionRouter drain does not do what its
comment says it does. This is a second instance of the pattern this task is
about — a mechanism that appears to work because its failure is silent.

Fixed by moving to Ecto's documented `start_owner!`/`stop_owner` shape
(`sandbox.ex:448`), where an agent owns the connection, the test process is
either covered by shared mode or explicitly `allow`ed, and the connection
survives until `stop_owner/1` runs **last** in the `on_exit` chain. The
`Sandbox.allow(Repo, ...)` calls for supervised GenServers now pass the
owner agent rather than `self()`, because in `async: true` the test process
is itself only an allowed process and would not name an owner.

## 14. Result on the route this stage owns

`mix test test/platform/audit/telemetry_handler_test.exs --seed 0`:

| | `owner … exited` | `disconnected` | result |
|---|---|---|---|
| before | present | present | `42 tests, 1 failure` |
| after | **0** | **0** | **`42 tests, 0 failures`** |

`mix test test/platform/audit/historian_latency_test.exs --seed 0`, ×10:

| | failures |
|---|---|
| stage 2 (§8, same file, same seed) | **2/10** — `p99=2577µs`, `p99=3056µs` |
| stage 3 | **0/10** — p99 range 394–687µs |

The p99 budget assertion is the wall-clock flake §3 names and §6 says must
NOT be "fixed" here; it was not touched. It did still fire once, in an
ordered-pair run at seed 0 (`p99=3070µs`), so it is improved rather than
gone. Do not read its absence from a single run as a fix.

## 15. The finding that matters more than the fix: ~90 % of these writes were already being destroyed

`persist_or_skip/4` was temporarily instrumented with `:counters` (reverted;
`git status --porcelain` clean for `lib/`). One `HistorianLatencyTest` run:

```
entered=10000  record_ok=1045  record_err=0  skip=0
rescue_ownership=0  rescue_generic=8955  spawn_try=10000  spawn_fail=0
```

All 10 000 children run. **~9 000 of them lose their write**, caught by the
**generic** `rescue error ->` clause — a `DBConnection.ConnectionError`
("connection not available and request was dropped from queue after N ms")
from DBConnection shedding checkouts off a 10 000-deep queue. Not one is an
`OwnershipError`; the specific rescue fires **zero** times, matching stage 1.

**This is a capacity condition, not an ownership one, and this stage's fix
does not move it:**

| tree | rows landed, of 10 000 |
|---|---|
| before | 747, 902, 931 |
| after | 1142, 824, 789, 1045, 453 |

The difference is run-to-run noise. Stage 1's "21 ConnectionErrors" was the
visible tip of a ~9 000-per-run loss.

### It is invisible for a second reason: the log undercounts by ~10×

`Logger.error` is called ~9 000 times per run and **0–850 lines survive** to
the output. I nearly filed a `crashed=0` → `crashed=807` before/after as a
regression I had introduced; the counters show the underlying rate is flat
and that comparison was measuring Logger's shedding, not the failure rate.
**Do not use `grep -c "Audit handler crashed"` as a count of these failures.**

### Named, not fixed, and why

The root cause is that `HistorianLatencyTest` generates 10 500 audit writes
it explicitly does not want — its own moduledoc says "the point of this test
is caller-visible emit latency, not durable persistence". The fixes live in
that test's design (sample size, or emitting on a path whose spawned body is
cheap) or in the test-env pool's `queue_target`/`queue_interval`, and both
touch the p99 assertion stage 1 §3/§6 explicitly fenced off from this task.
Reaching for a rescue or a `catch` instead would be the wrapper this stage
is forbidden to ship.

**Follow-up, named so it is not rediscovered a third time:** the async audit
path has no backpressure. In test it manifests as a ~90 % drop rate under
burst; in production the same shape (unbounded `start_child` per event, no
pool admission control) is what would shed audit rows under a historian
storm. That is a real product question, not a test-only artifact.

## 16. Test coverage and the mutation check

Four cases added in `telemetry_handler_test.exs`, describe block
"supervised audit writes (task 019f9d80 stage 3)".

The plan's requested case ("a historian emit's async write is retrievable")
is included, **labelled in-source as a characterization test rather than a
detector**, because §11 shows it passes without any of this stage's changes.

The actual detector is "await_supervised_writes/1 returns only after every
spawned writer has finished": emit a 200-event burst, assert
`active_children() > 0` (the condition the fix exists for — emitting outruns
draining), drain, then assert `active_children() == 0` **and** that all 200
rows are retrievable.

All probes run on `mix test test/platform/audit/telemetry_handler_test.exs
--seed 0`, `PLATFORM_TEST_DATABASE=platform_test_019f9d80_b`.

| probe | change | result |
|---|---|---|
| baseline (committed tree) | — | `42 tests, 0 failures`; `owner … exited` **0**, `disconnected` **0** |
| M0 (the plan's, adapted) | the coverage case the plan specified, on the async branch it specified | **GREEN — not a detector.** See §11. |
| **M1** | `await_supervised_writes/1` returns `:ok` immediately (wait loop deleted) | **RED, 2 failures** — `assert active_children() == 0` → `left: 190, right: 0`; and `assert {:timeout, active} = …` → `right: :ok` |
| **M2** | `DataCase` reverted to `Sandbox.checkout(Repo)` | **RED** — `owner … exited` **0 → 208**, `disconnected` **0 → 2**, `42 tests, 1 failure` |

M1 isolates the wait; M2 isolates the ownership model. Both probes reverted;
the committed tree contains neither.

Note M2's magnitude: **208** `owner … exited` lines, not the 21 stage 1 saw.
Stage 1 measured the ordered pair, where most children were already dead;
this is the same route measured on the file that emits from more cases.

**Surviving mutation, stated rather than omitted:** deleting the
`if shared_mode?` guard in `DataCase` (i.e. draining in `async: true` too)
does **not** go red on the ordered pair or on the audit files. It is still
wrong — `async: true` modules run concurrently, so `Platform.TaskSupervisor`'s
child set there belongs to other modules as much as to this one, and waiting
on it is waiting on an unrelated test — but that is an argument from
concurrency semantics, not something the suite detects. Recorded so the next
reader does not "simplify" it away on the grounds that nothing breaks.

## 17. The `start_owner!` migration's blast radius, and how it was found

The first full-suite run on this change was **36 failures at seed 0**
against stage 2's baseline of 1. Enumerated by module:

```
23  Platform.Responsibilities.RouterTest
 7  Platform.Orchestration.TaskRouterTest
 2  Platform.Agents.SystemEventSchedulerTenantsSummaryTest.IntegrationTest
 1  PlatformWeb.RuntimeChannelTest
 1  Platform.Review.MeetingSummarizeE2EReviewTest
 1  Platform.Meetings.IntentDispatcherTest
 1  Platform.Chat.PresenceTest
```

**Cause — a real defect in the migration, not a flake.** 24 test files call
`Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)` and match the result on
`:ok`. `start_owner!/2` allows the calling process only on its `shared: false`
branch (`sandbox.ex:459`); the `shared: true` branch just sets
`{:shared, owner}`, which lets the test process *use* the connection but
leaves it neither owner nor allowed. `DBConnection.Ownership.allow/4` takes an
`owner_or_allowed` parent, so `self()` stopped being a valid parent and every
such call returned `:not_found`:

```
** (MatchError) no match of right hand side value: :not_found
   code: {_pid, name} = start_router()
   test/platform/responsibilities/router_test.exs:71
```

Fixed inside `DataCase` with one line — `Sandbox.allow(Repo, owner, self())`
on the shared branch — which restores `self()` as a valid parent in both
modes and leaves all 24 call sites untouched. Targeted rerun of the affected
files: `111 tests, 1 failure` → `0 failures`.

### The residual `TaskRouterTest` / `RuntimeChannelTest` failures are not mine

Per §0 and the dispatch's "do not clear a surprising failure by matching it to
a flake list, including mine", these were run against an **untouched control
at the same seed, in the same load window**, by swapping only `data_case.ex`:

```
mix test test/platform/orchestration/task_router_test.exs \
         test/platform_web/channels/runtime_channel_test.exs \
         test/platform/review/meeting_summarize_e2e_review_test.exs --seed 0
```

| tree | failures | members |
|---|---|---|
| fix | 5 | `RuntimeChannelTest` "execution_event records…"; `TaskRouterTest` ×4 |
| control (`HEAD` `data_case.ex`) | **6** | `RuntimeChannelTest` "tool_call executes tool…"; `TaskRouterTest` ×5 |

Different members, overlapping cluster, control strictly worse. This is the
`Platform.Orchestration.TaskRouterTest` sandbox/liveness cluster §3 already
names as "known to produce a different subset each run"; `RuntimeChannelTest`
joins it here with the same signature. Not caused by this diff.

## 18. What this stage changed

Product code: **one comment**, in `audit/telemetry_handler.ex`. The rescue's
old rationale asserted the opposite of measured behaviour and is the reason
the real route stayed invisible; the clause itself is unchanged, and is kept
(a) because it genuinely covers the `async: true` shape and (b) because
`supervised_task_repo_audit_test.exs` assertion 1 requires it of every
`Platform.TaskSupervisor` caller.

Test infrastructure:
- `test/support/sandbox_helpers.ex` (new) — `await_supervised_writes/1`,
  `active_children/1`, `drain_or_warn/1`.
- `test/support/data_case.ex` — `start_owner!`/`stop_owner` ownership,
  `allow(Repo, owner, self())` on the shared branch, `allow` parent switched
  from `self()` to `owner`, supervised-writer drain before `stop_owner`.
- `historian_latency_test.exs`, `telemetry_handler_test.exs` — three comments
  corrected from claims that measurement contradicts.
- `supervised_task_repo_audit_test.exs` — moduledoc + `StackDeployer`
  `@known_safe` entry updated so the exemptions' stated reasons stay true.
- `telemetry_handler_test.exs` — 4 new cases (§16).

## 19. Full suite, against a stage-2 control at the same seed

`mix format --check-formatted` → clean (`FORMAT_OK`).

Baseline is 8220 (§10). This stage adds 4, all in
`audit/telemetry_handler_test.exs` (§16) → **8224**.

Control for this stage is **stage 2's own tree**, not stage 1's: a fresh
worktree `~/sources/worktrees/019f9d80-s2` detached at `3e888704`, its own
`mix deps.get` (no symlinked deps), DB `platform_test_019f9d80_s2ctl`,
`/tmp/git-repo-*` + `/tmp/wt-root-*` cleared, seed 0, adjacent load windows.

| tree | window (UTC) | result | failing set |
|---|---|---|---|
| fix `task/019f9d80` | 02:09–02:23 | `16 doctests, 8224 tests, 5 failures, 3 skipped` | `HistorianLatencyTest` p99 · `TaskRouterStageIsolationTest:307` · `TaskRouterTest` ×3 (`:479` failed-review bounce, `:758` safety-net fire, `:1039` terminate/2 clears LeaseManager) |
| control `3e888704` | 02:35–02:48 | `16 doctests, 8220 tests, 3 failures, 3 skipped` | `TaskRouterTest` ×2 (in_review→deploying, no-ack silence lapses) · `Platform.Security.RuntimeChannelCapabilityTest` "canvas.create executes" |

**The fix set is not a strict subset, and the control set is not a subset of
§3's enumeration either** — the control produced `RuntimeChannelCapabilityTest`,
which §3 does not name. Both observations are the same fact §3 records: the
`TaskRouter` lease/liveness cluster (and now the runtime-channel tests that
share its fixtures) emits a different subset every run. Counts are the wrong
unit; each new member has to be explained individually, which is what follows.

### `Platform.Audit.HistorianLatencyTest` p99 — the named §3 flake, rate unchanged

Ordered pair on the fix branch, seeds 0–9:

| seed | result | p99 (µs) |
|---|---|---|
| 0 | 0 failures | 581 |
| 1 | 0 failures | 693 |
| 2 | 0 failures | 415 |
| **3** | **1 failure** | **4848** |
| 4 | 0 failures | 787 |
| 5 | 0 failures | 346 |
| **6** | **1 failure** | **1540** |
| 7 | 0 failures | 513 |
| 8 | 0 failures | 553 |
| 9 | 0 failures | 549 |

**2/10, exactly the rate stage 2 measured at §8 and §3 measured on a clean
control.** Both failures are the `@p99_budget_us` wall-clock assertion. §3 and
§6 say it must not be "fixed" here; it was not touched.

**`ExternalAdmissionNotifierTest` appears zero times across all ten runs.**
Mechanism A remains fixed — 10/10 on the assertion that actually pins it,
which is the comparison §0's table asks for.

### `Platform.Orchestration.TaskRouterStageIsolationTest:307` — new to the list, and independent

Not in §3's enumeration, so per §0 a stop until explained. Explained
mechanically, and measured against the control rather than matched to a list:

```
assert %{stage_id: recorded_stage_id, ack_at: nil, no_ack_fired?: false} =
         LeaseManager.get(task.id)
left:  %{stage_id: recorded_stage_id, ack_at: nil, no_ack_fired?: false}
right: nil
```

Standalone, seed 3, ×10 each:

| tree | failures |
|---|---|
| fix | 8/10 |
| control `3e888704` | **5/10** |

It fails on the untouched control, so it is not introduced here. The mechanism
rules this diff out on its own: **`LeaseManager.get/1` reads ETS**
(`lease_manager.ex:263-272`, `:ets.lookup(@table, task_id)`), not `Repo`. ETS
is not sandboxed, so nothing about connection ownership or a supervised-writer
drain can reach it. The race is the test's own fixed `Process.sleep(100)` after
`await_attention!()` against the router's asynchronous `record_dispatch`; any
change in machine load moves the rate, which is why 5/10 and 8/10 are the same
finding rather than two.

**Add `TaskRouterStageIsolationTest:307` to the known-independent list with
that mechanism written next to it** — sleep-based race on an ETS read, not a
sandbox failure. Same handling as `PlanTest:398` (§10.1) and
`HistorianDispatcherTest:322` (§10.2): explained, not resembled.

### `Platform.Security.RuntimeChannelCapabilityTest` — control-only, named for completeness

Appeared on the **control** and not on the fix branch. Named here so the next
reader does not treat its future appearance as a regression from this stage.
`PlatformWeb.RuntimeChannelTest` behaved the same way in the targeted
comparison at §17 — a different member on each side, control strictly worse.

---
---

# Stage 4 — the guard, and the two premises in the stage plan that are false

Task `019f9d80-e1ac-737c-bfd3-7846e2de6469`, stage 4
("Add a source-scan guard and an ordered-pair CI step").
Branch `task/019f9d80`, parent `080d59bc` (stage 3).
All measurements: worktree `~/sources/worktrees/019f9d80`,
`PLATFORM_TEST_DATABASE=platform_test_019f9d80`.

## 20. What shipped

- **`test/platform/regression/boot_telemetry_handler_detach_audit_test.exs`**
  (new) — `use ExUnit.Case, async: true`, no DB, no PubSub, default `mix test`
  set. Seven cases across four assertions (§21).
- **`.github/workflows/ci.yml`** — a second test step running the two-file pair
  in one BEAM (§23).
- **`test/platform/audit/telemetry_handler_test.exs`** — one real offender the
  new guard found on the committed tree, fixed (§22).
- **`lib/platform/orchestration/task_router_watcher.ex`** and
  **`test/platform/regression/supervised_task_repo_audit_test.exs`** — two
  surviving unqualified sandbox-ownership claims, corrected (§24).

### What was deliberately NOT built: a "DB work inside `on_exit`" scan

The stage brief raised it and asked for a judgement. **Left out.** §13 is right
that `on_exit` runs in a separate process after the test process is dead, and
that this made every connection-dependent `on_exit` in `DataCase` a no-op —
but stage 3 fixed that at the source (`start_owner!` keeps the connection alive
until `stop_owner/1` runs last), so DB work in `on_exit` is now *legitimate*
under shared mode and the property to guard evaporated.

More importantly the scan would not work. Measured across all 473 files in
`test/**`: **zero** `on_exit` bodies contain a `Repo.*` call. A guard for the
`Repo.` shape would therefore pass unconditionally today while being
structurally unable to see the case that actually matters — DB work reached
indirectly through a context function (`Platform.Tasks.delete_task/1` and its
hundreds of siblings). That is a guard that certifies a property it cannot
check, which is the same defect class as an audit assertion passing because
nothing is listening. A noisy guard becomes an ignored guard; a vacuous one
becomes a false credential. Both were declined.

## 21. The four assertions, and why the stage plan's premise for the guard was wrong

The stage plan asked for a source scan **and** an ordered-pair CI step whose
combination proves the invariant. Two of its premises do not survive
measurement, and both were already recorded upstream in this file:

1. **The ordered pair cannot detect a missing restore.** §9 probe M0: deleting
   the restoring `on_exit` leaves the pair GREEN, because what repairs today's
   offenders is that their setup no longer detaches at all. The `on_exit`
   defends a *future* or *mid-body* detach. So the runtime half of the guard is
   a regression pin for mechanism A, not a detector for the rule — and the rule
   has to be enforced statically or not at all.
2. **CLI argument order does not control ExUnit execution order** (§2). The CI
   step's invariant is "same BEAM", not "this order", and it says so in-file.
   Writing an order-based claim into `ci.yml` would ship a guard that looks
   like it pins ordering and does not, which is this task's own defect class
   reproduced inside its fix.

The four assertions:

| # | Assertion | Why it is not a formality |
|---|---|---|
| 1 | The boot-attached module set is **parsed from `Platform.Application.start/2`**, plus a companion check that the parser understood *every* `.attach()` in the file | Two of the seven handlers were boot-attached *after* the offending tests were written; a frozen list would have missed two of the five offenders. The companion check is the anti-rot half — see M-G |
| 2 | Every `detach()` of a derived module in `test/**` is either an adjacent `detach(); attach()` pair, or is preceded by a **registered** restore for that same module | Ordering is the whole point: a restore registered *after* the detach does not run if the assertion between them fails |
| 3 | No `async: true` file detaches a boot handler | VM-global state; no `on_exit` ordering can close a window that is open while other files run |
| 4 | No comment or doc anywhere in `lib/` or `test/` claims something is outside the sandbox owner chain **without naming the sandbox mode** | §24 |

Implementation note: assertions 1–3 walk the AST (`Code.string_to_quoted!`)
rather than matching regexes. `supervised_task_repo_audit_test.exs` is the
pattern this file mirrors and it is regex-based, but its two 2026-07-25
widenings are a written record of regex going blind on the exact file it was
meant to catch. Assertion 2 has to know whether a restore was registered
*before* a given line, whether two calls are *adjacent statements*, and what a
bare `TelemetryHandler` alias resolves to in each file — regex cannot answer
any of those without guessing. Four of the five original offenders used the
bare-alias call shape, so alias resolution is not optional. Assertion 4 is
prose and stays regex, over joined comment/doc blocks rather than single lines
(the `responsibilities/router.ex` claim is split across two source lines).

Whole file: **7 tests, 0 failures, 6.5–10 s** wall clock under a box load of
~25–30.

## 22. The guard found a real offender on the committed tree

Not a synthetic mutation — the first run against stage 3's tree:

```
test/platform/audit/telemetry_handler_test.exs:905 — Platform.Vault.TelemetryHandler
```

`"ensure_boot_handler!/1 re-attaches a handler that is currently detached"`
detaches the **Vault** handler, asserts `handler_ids_for(...) == []`, and only
then calls `ensure_boot_handler!/1`. That file's `setup` registers a restore for
`Platform.Audit.TelemetryHandler` only. If the assertion between the detach and
the restore ever fails, the Vault bridge stays detached for the remainder of the
BEAM — the exact leak, in the test written to prove the leak is fixed, created
by stage 2. Fixed by registering the restore before the detach; the case still
tests what it tested.

This is the anti-vacuity evidence that matters most: the guard was red on
arrival for a reason nobody had noticed.

## 23. The CI step

```yaml
- name: Boot-telemetry-handler cross-file regression (same BEAM)
  run: |
    pair="test/platform/audit/historian_latency_test.exs test/platform/accounts/external_admission_notifier_test.exs"
    mix test $pair --seed 0 || (echo "::warning::..." && mix test $pair --seed 0)
```

The retry is the **whole command again**, not `mix test --failed`. That
distinction is the entire point of §5: `--failed` reruns only the failed tests
serially, re-partitioning them, so a cross-file failure turns green. Re-running
the identical two-file command preserves the same-BEAM invariant, so mechanism A
— deterministic at 10/10 across ten fixed seeds (§2) — fails both attempts. What
the retry absorbs is `historian_latency_test.exs`'s `@p99_budget_us` wall-clock
assertion, measured at 2/10 on a clean control (§3), on a stage-2 tree (§8) and
on a stage-3 tree (§19): two independent draws put a double failure at ~4%.

`.github/workflows/ci.yml:87`'s `mix test --failed --max-cases 1` retry is
**still flagged, still not fixed**, per §5 and the stage fence.

## 24. Assertion 4 — the self-certifying comment, and the two that survived stage 3

Stage 3 corrected three comments asserting that a `Task.Supervisor` child "is
not in the DataCase sandbox owner chain". `data_case.ex` does
`Sandbox.start_owner!(Repo, shared: not tags[:async])`, so under `async: false`
the child **inherits** the connection and the claim is false. A scan for the
claim shape found **seven** blocks in `lib/` + `test/`; four name their sandbox
mode, three did not:

| site | disposition |
|---|---|
| `lib/platform/orchestration/task_router_watcher.ex:276` | **corrected.** Claim is true under `async: true` (manual mode) only; the `catch` clause directly below already describes the shared-mode case, so the file contradicted itself |
| `test/platform/regression/supervised_task_repo_audit_test.exs:370` | **corrected.** This is the fourth of the four the stage brief named — it lives in a *failure message*, not a comment, which is why the prose scan reads heredocs as well |
| `lib/platform/responsibilities/router.ex:1323` | **recorded, not fixed.** Inside this task's ADR-0046 scope fence. Listed in `@known_unqualified_claims` with the fence cited; the rot guard fails the moment it is corrected, which is how the entry gets removed rather than outliving its reason |

The rule enforced is not "this claim is forbidden" — it is often true — but
**"name the mode you mean"**. That is checkable; "is not in the owner chain" is
not.

**Stated limitation** (probe M-D): the scan is block-scoped, so a block that
names a mode *anywhere* passes even if one sentence inside it is unconditional.
De-qualifying one line of `audit/telemetry_handler.ex`'s rescue comment left the
guard GREEN because the same comment run discusses `async: false` further down.
Tightening this to sentence scope was tried and rejected: comment prose wraps
mid-sentence constantly, and a sentence splitter over `#`-run text produces
false positives on every abbreviation and code fragment. Block scope catches the
failure that actually occurred — a comment with no mode discussion at all — and
declines to guess about the rest.

## 25. Deliberate-violation checks — every assertion fails when violated

Each probe patches the tree in place, runs
`mix test test/platform/regression/boot_telemetry_handler_detach_audit_test.exs
--seed 0`, and restores the exact original bytes. `git status --porcelain` shows
only the intended stage-4 changes afterwards. No `git stash` (shared ref across
worktrees).

| probe | mutation | result |
|---|---|---|
| **M-A** | plan's (a): `vault/telemetry_handler_test.exs` setup reverted to `detach(); attach(); on_exit(fn -> detach() end)` | **RED** — `test/platform/vault/telemetry_handler_test.exs:13 — Platform.Vault.TelemetryHandler` |
| **M-B1** | `meetings/telemetry_handler_test.exs` loses its `ensure_boot_handler!` | **RED** — `test/platform/meetings/telemetry_handler_test.exs:47 — Platform.Meetings.TelemetryHandler` |
| **M-B2** | M-B1 **plus** `Platform.Meetings.TelemetryHandler.attach()` deleted from `application.ex:15` | **GREEN** — plan's (b), and the proof the set is parsed: the identical test defect is reported or not purely as a function of `application.ex`'s contents. A hardcoded list keeps M-B2 red |
| **M-C** | plan's (c): `tenancy/lifecycle_test.exs` flipped to `async: true` | **RED** — names the file and all four detach lines with the module at each |
| **M-D** | one `async: true` mention removed from `audit/telemetry_handler.ex`'s rescue comment | **GREEN — surviving mutation**, block scope, §24 |
| **M-D2** | `task_router_watcher.ex` comment reverted to its unqualified pre-stage-4 form | **RED** — `lib/platform/orchestration/task_router_watcher.ex:276 — "NOT part of the sandbox owner chain"` |
| **M-E** | a `@known_safe` entry with nothing behind it | **RED** — names the stale entry |
| **M-F** | `@known_unqualified_claims` emptied | **RED** — `lib/platform/responsibilities/router.ex:1323`, confirming the exemption is load-bearing rather than decorative |
| **M-G** | `Platform.Memory.TelemetryHandler.attach()` rewritten as `Enum.each([...], & &1.attach())` | **RED** — "application.ex contains 7 `.attach()` call(s) but this audit only understood 6", and lists the six |

**Every failure message names the offending file, the line, and the specific
handler module or claim.** Stage 3 noted that the existing migration-timestamp
guard in `ci.yml` fails on a bare count mismatch with no hint which file is new;
M-G is the analogous check here and it prints the set it understood so the
missing member is visible by subtraction.

## 26. Formatting and suite

`mix format --check-formatted` → clean (`FORMAT_OK`).

Full suite on the stage-4 tree, DB `platform_test_019f9d80`,
`/tmp/git-repo-*` + `/tmp/wt-root-*` cleared, seed 0, box load ~25-30:

```
16 doctests, 8231 tests, 0 failures, 3 skipped (2 excluded)    exit 0
```

Stage 3's baseline was 8224; this stage adds **7**, all in the new audit file.
Ordered pair on this tree, seeds 0/1/2: **3/3 GREEN**, `6 tests, 0 failures`.

## 27. Cross-task query: is `Platform.Accounts.ExternalAdmissionNotifier` a second instance?

Raised mid-stage from task `019fa129` stage 2: the notifier is a globally
attached handler with a no-arg global `detach/0`
(`external_admission_notifier.ex:66`), and
`ExternalAdmissionNotifierTest` — "a holding event persists an Audit.Event
(durable queue source)" — fails intermittently in full-suite runs while passing
in isolation. Asked whether the stage-4 guard covers it.

**Two separate answers, and the distinction matters.**

**(a) Coverage: yes, and measured, not asserted.** The guard is not scoped to
the audit path. `boot_attached_modules/0` parses `Application.start/2` and the
notifier is one of the seven it returns — M-G's failure output lists
`Platform.Accounts.ExternalAdmissionNotifier` by name. Probe **M-H** injected an
unrestored `ExternalAdmissionNotifier.detach()` into
`test/platform_web/live/external_recovery_live_test.exs` (which already aliases
the module, so the bare-alias resolution path is exercised, and which is a
`PlatformWeb.ConnCase` rather than a `DataCase`):

```
RED — test/platform_web/live/external_recovery_live_test.exs:23
      — Platform.Accounts.ExternalAdmissionNotifier
```

For the record on the current tree: **no test detaches the notifier.**
`grep -rn ExternalAdmissionNotifier test/` returns two `alias` lines and no
`detach` call anywhere. So there is no live second offender to fix; the guard
covers the shape prospectively.

**(b) Attribution: it is the same instance, not a second one — and it is
already fixed on this branch.** The notifier does not write the audit row the
failing assertion reads. `Platform.Audit.TelemetryHandler` does: it subscribes
to `[:platform, :auth, :external_admission]` (`telemetry_handler.ex:42`) and
persists through the default synchronous clause. The failure is
`ExternalAdmissionNotifierTest:138` reading `[]`, and §4 pinned its cause by
instrumentation rather than resemblance — in the failing run
`platform-audit-telemetry` is not attached to the event at all, because
`historian_latency_test.exs` detached it and never put it back. The notifier's
own handler stays attached throughout (`PROBE
external_admission_handlers=["external-admission-notifier"]` in the RED run).

That is mechanism A, this task's subject. §2 measured it deterministic — 10/10
RED at ten fixed seeds on the control — and §2 explains the isolation-passes
half: the single-file run is green because nothing has detached the bridge yet.
"Intermittent in full-suite runs, green in isolation" is the exact signature and
is what got it written off as a flake in roughly eight briefs (§6).

On this branch it is fixed: ordered pair 10/10 GREEN at stage 2 (§8), 10/10 at
stage 3 (§19) with `ExternalAdmissionNotifierTest` absent from every run, 3/3 at
stage 4, and the full suite above is 0 failures. **The standing known-bad list
must lose the `ExternalAdmissionNotifierTest:138` entry** (§6, stage 5's job) —
a failure there is now real, and re-filing it as "a sibling detaching a global
handler" would re-open the write-off this task closed.
