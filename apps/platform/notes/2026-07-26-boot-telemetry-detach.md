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
