# Baseline measurement: the `tasks:board` PubSub topic race (task 019fca9e, stage 1)

**NO PRODUCTION CODE CHANGED IN THIS STAGE.** This note is the deliverable.

Base commit: `4dcbfb03` (`origin/main` at time of measurement), clean worktree, zero
local changes at every run below.

Measurement DB: `PLATFORM_TEST_DATABASE=platform_test_019fca9e` — a dedicated database,
created and migrated for this task. Several unrelated Elixir suites were running
concurrently on the same box against the default `platform_test`; measuring in that
shared database would have mixed other agents' schema state into these numbers.

Command, unchanged across all 20 runs, from `apps/platform`:

```
mix test test/platform/tasks/ --seed N        # N = 1..20
```

Suite size, identical every run: **5 doctests, 1539 tests**.

---

## 1. Result — the race reproduces, 6 red runs in 20 (30%)

| Seed | Result | Seed | Result |
|---|---|---|---|
| 1 | pass | 11 | pass |
| 2 | pass | 12 | **1 failure** |
| 3 | pass | 13 | pass |
| 4 | pass | 14 | pass |
| 5 | **1 failure** | 15 | pass |
| 6 | pass | 16 | **1 failure** |
| 7 | pass | 17 | **1 failure** |
| 8 | **1 failure** | 18 | pass |
| 9 | **1 failure** | 19 | pass |
| 10 | pass | 20 | pass |

**Red runs: 6 / 20.** Red seeds: 5, 8, 9, 12, 16, 17.

No run had more than one failure. No run had a failure that was not the test below.

## 2. The multiset of failing test identities has exactly one member

Every one of the 6 failures is the same test, failing on the same assertion, in the
same way:

```
test/platform/tasks/plan_test.exs: approve_plan/2 auto-supersession
  broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan}
  (Platform.Tasks.PlanTest)
```

Count by test name:

| Failing test | Occurrences |
|---|---|
| `PlanTest` "broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan}" | 6 |
| (any other test) | 0 |

Verbatim failure, run at seed 5:

```
  1) test approve_plan/2 auto-supersession broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan} (Platform.Tasks.PlanTest)
     test/platform/tasks/plan_test.exs:398
     Assertion with == failed
     code:  assert id2 == v2.id
     left:  "019fd380-c305-714c-998d-00b5886b00ae"
     right: "019fd380-c2f7-7e35-9d8f-fe245d1de127"
     stacktrace:
       test/platform/tasks/plan_test.exs:413: (test)
```

The other five are byte-identical except for the ids. All six fail at
`plan_test.exs:413` on `assert id2 == v2.id` — the *second* `assert_receive`, never
the first.

Left/right ids per red seed:

| Seed | `left` (id actually received) | `right` (`v2.id`, expected) |
|---|---|---|
| 5 | `019fd380-c305-714c-998d-00b5886b00ae` | `019fd380-c2f7-7e35-9d8f-fe245d1de127` |
| 8 | `019fd388-0e66-73d4-b099-863ff64822b3` | `019fd388-0e71-7b08-98d2-b20cd1a77e5f` |
| 9 | `019fd389-88e3-7fb0-a9ec-fbf2fb76f1fc` | `019fd389-88ed-700b-8b75-9940abedb9de` |
| 12 | `019fd38d-ae86-75bc-9d28-65402059a590` | `019fd38d-aec7-7095-a4b2-4f62eb6b7a43` |
| 16 | `019fd395-a903-7ef9-bfda-963510c066a9` | `019fd395-a92a-7c0c-b7e0-b8c4b7ff17b8` |
| 17 | `019fd397-07be-71b1-9503-78d01850c7d0` | `019fd397-080b-7e4a-be8d-ceede2ad387a` |

These are UUIDv7, so the leading hex is a timestamp. In **all six** cases the received
id sorts *before* the expected id: the plan whose `{:plan_updated, _}` the test caught
was created earlier than the plan the test itself created. That is consistent with a
foreign broadcast from a concurrently running async test arriving in the mailbox, not
with an ordering inversion inside `approve_plan/2`.

Mechanism, for the record (`lib/platform/tasks.ex:4244`):

```elixir
@board_topic "tasks:board"
```

`subscribe_board/0` subscribes to that one global topic; `broadcast_board/1` publishes
every board event to it. 14 test files call `subscribe_board`. A subscriber therefore
receives plan/task events produced by every other async test running at the same
moment, and `assert_receive {:plan_updated, %Plan{status: "approved"}}` matches the
first such message regardless of which task it belongs to.

## 3. Load averages — high, and driven by unrelated concurrent work

Recorded with `uptime`, before, during (every 5 seeds) and after the sweep:

```
before, at branch point:  14:46:29 up 28 days, 16:02, load average: 36.40, 30.02, 24.93
after seed 5:             14:59:47 up 28 days, 16:15, load average: 62.46, 63.06, 46.53
after seed 10:            15:09:51 up 28 days, 16:25, load average: 33.42, 45.35, 46.37
after seed 15:            15:19:46 up 28 days, 16:35, load average: 51.54, 48.29, 45.95
after seed 20 (final):    15:27:10 up 28 days, 16:43, load average: 28.77, 36.28, 41.17
```

One-minute load ranged over **28.77 – 62.46** across the sweep, and a spot check
mid-sweep read 74.94. This box was running several other full Elixir test suites, from
unrelated concurrent work, throughout. That load was **not** under this measurement's
control and did not hold steady.

This matters because of the precedent in `test/support/test_quarantine.ex` for
`task_router_test.exs`, which records that its failure rate is a function of box load
and that any figure quoted from it must carry the load it was taken under. The same
caution applies to the 6/20 here.

Wall-clock per run varied with that load, 76s to 174s (`Finished in …` lines in the raw
logs), roughly a 2.3x spread on identical work.

## 4. What this settles about the three prior, disagreeing observations

* **Ticket reporter: 2 failures in 4 runs (50%).** Same failure family. 6/20 = 30% here
  is lower but not inconsistent with 2/4 at n=4.
* **`org/journal/2026-07-31.md`: 1 failure in 14 runs (7%).** Reproduced there only by
  deliberately co-scheduling plan-mutating async files. This sweep needed no such
  arrangement — plain `mix test test/platform/tasks/` reproduces it at 30% under load.
* **`notes/2026-07-26-boot-telemetry-detach.md` lines 600-640: not reproduced in 10
  seeds of a 401-test targeted subset**, concluding full-suite scheduler load appeared
  necessary. This sweep contradicts the "full suite required" part: the 1539-test
  `test/platform/tasks/` directory is enough. It supports the "load matters" part —
  the 401-test subset offers far less concurrent async traffic to collide with, and the
  box here was heavily loaded.

Reconciling reading: the race needs (a) enough concurrently-running async tests
publishing board events, and (b) enough scheduler pressure to interleave them into the
subscriber's mailbox before its own broadcast. Both scale with directory size and box
load, which is why the reported rate has ranged 0% – 50% across measurements.

## 5. How much to trust 6/20

The **qualitative** finding is solid and is the one stages 2-5 need: there is a real,
reproducible failing baseline, it is a single named test, and it fails through a foreign
board broadcast. Nothing about that depends on the exact rate.

The **quantitative** 30% is a point estimate under variable, externally-driven load, at
n=20 (95% binomial interval roughly 12% – 54%). It should not be treated as a stable
constant. Specifically:

* A post-fix sweep on a quiet box that goes 0/20 green does **not** by itself prove the
  fix, because a quiet box may not have reproduced the bug either.
* The post-fix sweep in stages 3-4 must record `uptime` on the same schedule, and should
  be judged primarily on **whether the named test above ever fails again**, with the rate
  as secondary evidence. If the post-fix run happens under materially lower load, say so
  rather than presenting a green sweep as conclusive.

## 6. Raw artifacts

Per-seed logs were kept for all 20 runs (`seed_1.log` … `seed_20.log`) under the
measuring session's scratch directory; the numbers extracted from them are reproduced in
full above. Reproduce with the command in the header on `4dcbfb03` against a dedicated
test database.

---

# Stage 3 re-measurement: two modules moved to scoped topics

Two sweeps, both run tonight on this box within ~2 hours of each other, identical
command and identical dedicated database (`PLATFORM_TEST_DATABASE=platform_test_019fca9e`):

```
mix test test/platform/tasks/ --seed N        # N = 1..20
```

Suite size identical in both, and in every run: **5 doctests, 1551 tests**. (Stage 1's
baseline above ran 1539 tests; stage 2 added the 12 tests in
`board_topic_scope_test.exs`.)

## Why a fresh pre-change sweep, rather than reusing the 6/20 above

The stage-1 baseline was taken under load that ranged 28.77 – 62.46 (spot check 74.94).
The box is much quieter now. Comparing a post-fix sweep on a quiet box against a
baseline from a loaded one measures the box as much as the change, so the pre-change
sweep below was re-run from scratch at the *unmodified* stage-2 commit `18e239f1` —
zero local changes, the same commit at which the two subscribers were still on the
global firehose.

## 1. Pre-change (commit `18e239f1`, no local changes) — 8 / 20 red

| Seed | Result | 1-min load at run start | Seed | Result | 1-min load at run start |
|---|---|---|---|---|---|
| 1 | **1 failure** | 15.06 | 11 | pass | 15.89 |
| 2 | pass | 18.42 | 12 | pass | 15.24 |
| 3 | pass | 31.33 | 13 | **1 failure** | 16.29 |
| 4 | pass | 26.37 | 14 | pass | 21.47 |
| 5 | **1 failure** | 23.97 | 15 | **1 failure** | 17.31 |
| 6 | **1 failure** | 19.08 | 16 | **1 failure** | 13.72 |
| 7 | pass | 19.00 | 17 | **1 failure** | 14.90 |
| 8 | pass | 15.66 | 18 | pass | 15.20 |
| 9 | pass | 17.43 | 19 | **1 failure** | 14.89 |
| 10 | pass | 14.97 | 20 | pass | 15.79 |

Red seeds: 1, 5, 6, 13, 15, 16, 17, 19. **8 / 20 (40%).**

Failing-test breakdown — the multiset again has exactly one member:

| Failing test | Occurrences |
|---|---|
| `Platform.Tasks.PlanTest` "broadcasts {:plan_updated, supersedee} BEFORE {:plan_updated, new_plan}" (`plan_test.exs:398`) | 8 |
| (any other test) | 0 |

No run had more than one failure. `test/platform/tasks/` carries other known flakes
(see `test/support/test_quarantine.ex`); none of them fired in these 20 runs.

## 2. Post-change — 0 / 20 red

| Seed | Result | 1-min load at run start | Seed | Result | 1-min load at run start |
|---|---|---|---|---|---|
| 1 | pass | 29.99 | 11 | pass | 13.72 |
| 2 | pass | 27.58 | 12 | pass | 11.84 |
| 3 | pass | 23.82 | 13 | pass | 17.80 |
| 4 | pass | 20.79 | 14 | pass | 20.01 |
| 5 | pass | 19.43 | 15 | pass | 22.42 |
| 6 | pass | 16.95 | 16 | pass | 15.73 |
| 7 | pass | 17.44 | 17 | pass | 13.62 |
| 8 | pass | 14.27 | 18 | pass | 12.05 |
| 9 | pass | 16.16 | 19 | pass | 16.81 |
| 10 | pass | 14.74 | 20 | pass | 13.44 |

**0 / 20.** Zero failures of any kind, so the per-test breakdown is empty and the
stronger claim — zero failures attributable to board-topic cross-talk — holds
trivially.

## 3. Side-by-side, and how much it is worth

| | Pre-change (`18e239f1`) | Post-change |
|---|---|---|
| Red runs | **8 / 20** | **0 / 20** |
| `plan_test.exs:398` failures | 8 | 0 |
| Any other failing test | 0 | 0 |
| 1-min load, min – max | 13.72 – 31.33 | 11.84 – 29.99 |
| 1-min load, median | ~16.3 | ~16.5 |

The two load bands overlap almost exactly and their medians differ by ~0.2, so unlike
the stage-1 → stage-3 comparison this one is not confounded by box quietness. Fisher's
exact test on 8/20 vs 0/20 gives a one-sided p ≈ 0.0016.

The claim being defended is the named-test one: **`plan_test.exs:398` failed 8 times in
20 seeded runs immediately before the change and 0 times in 20 seeded runs immediately
after, at comparable load.** The percentages are secondary; each is a point estimate at
n = 20.

## 4. What this does NOT show

`tasks_context_test.exs`'s "create_epic/1 does NOT broadcast when the changeset is
invalid" was **never observed failing** — not in stage 1's 20 runs, and not in the
pre-change 20 runs here. Its `refute_receive {:epic_created, _}, 50` is a genuine
theoretical race on a global topic, and it is the case that proves scoping was the
required fix rather than id-pinning (the epic is never inserted, so no id exists to pin
into the pattern) — but this sweep contains no measurement of it failing and therefore
demonstrates no improvement for it. That subscription was scoped on the strength of the
argument, not of a measurement.

Also unshown: 12 of the 14 `subscribe_board/0` call sites in the test tree are
untouched by this stage and remain on the global firehose.

## 5. Changes made

`test/platform/tasks/plan_test.exs` — all three `Tasks.subscribe_board()` calls became
`Tasks.subscribe_board(task: task.id)`. The measured-failing test now pins `^v1_id` /
`^v2_id` into its two `assert_receive` patterns instead of matching loosely and
comparing the id on the following line. The two sibling tests already pinned `^task_id`
into their first assertion; their second `assert_receive` is now pinned to the plan id
in hand as well.

`test/platform/tasks/tasks_context_test.exs` — the `describe "epic broadcasts +
changeset"` setup became `Tasks.subscribe_board(project: project.id)`. Each test in the
block creates its own project inside the Ecto sandbox, so that id is unreachable by any
other module by construction.

---

# Stage 4: the scope-narrowing sweep found nothing left to narrow

Stage 4 was specified to migrate five further `subscribe_board/0` call sites onto
scoped topics. **Its premise did not survive verification.** All five modules declare
`async: false`:

| File | Declaration |
|---|---|
| `test/platform/tasks_phase_pointer_test.exs` | `use Platform.DataCase, async: false` |
| `test/platform/tasks/submit_plan_for_review_architect_hook_test.exs` | `use Platform.DataCase, async: false` |
| `test/platform/tasks/plan_engine_architect_drift_hook_test.exs` | `use Platform.DataCase, async: false` |
| `test/platform/tasks/stacks_test.exs` | `use Platform.DataCase, async: false` |
| `test/platform/tasks/planning_step_test.exs` | bare `use Platform.DataCase` |

The last is the subtle one: a bare `use Platform.DataCase` is SYNCHRONOUS, because
`test/support/data_case.ex` sets `shared: not tags[:async]`. Reading it as async is the
easy mistake, and the stage spec made it.

A sync module cannot be raced by a concurrent module, so none of the five is exposed to
the defect this task fixes. Stage 4 therefore made **no functional change** and instead
recorded the reason at each module as a greppable `BOARD-SCOPE-EXEMPT:` comment key,
plus one per-site note in `stacks_test.exs`: two of its four assertions are
`refute_receive {:stack_gate_opened, _, _}` asserting that no gate fires for ANY stack.
There is no stack id to subscribe to, so that site could not be scoped even if the
module went async.

**After-count, end of stage 4:** zero `async: true` test modules call the zero-arity
`Tasks.subscribe_board()` outside `board_topic_scope_test.exs`, which is the unit test
of the fan-out itself and must subscribe globally to observe the global copy still goes
out. Stage 3 migrated the only two real ones.

---

# Stage 5: guard, quarantine retirement, and what was ruled out

## 1. The guard

`test/platform/regression/board_topic_scope_audit_test.exs`, mirroring
`attention_broadcast_funnel_audit_test.exs`. `Path.wildcard` + `File.read!` + regex; no
DB, no PubSub; `async: true`, so it runs in the default `mix test` set.

**Keyed on the `async:` declaration, not on a roster of call sites.** The exempt set is
"every synchronous module", which the scan determines from each module's own
`use ... async: true` line, rather than from a list of individually-blessed files. That
is the right key because sync modules are out of scope BY CONSTRUCTION — nothing
concurrent can put a foreign board event in their mailbox — rather than by exception.
`@allowed_files` is consequently one entry long (`board_topic_scope_test.exs`) instead
of fourteen. The offender set is computed as *every* match minus that allowed set; it is
NOT an assertion that the matches equal a remembered list, which is a form satisfied by
any site the author forgot.

The guard also excludes its own file from the walk: its regex literals are code, not
comments, so `strip_prose/1` cannot blank them, and without the exclusion the guard
reports itself and the anchor would be satisfied by its own literal.

## 2. The guard was shown to fire — three states

Command in all three, from `apps/platform`:

```
mix test test/platform/regression/board_topic_scope_audit_test.exs
```

**(a) With a deliberate violation** — a bare `Tasks.subscribe_board()` temporarily added
at `test/platform/tasks/plan_test.exs:408` (an `async: true` file, not in the allowlist):

```
  1) test global board subscriptions in async tests no async: true test module calls
     the zero-arity Tasks.subscribe_board() (Platform.Regression.BoardTopicScopeAuditTest)
     The following `async: true` test module(s) subscribe to the GLOBAL kanban
     board topic:

       test/platform/tasks/plan_test.exs — line(s) 408
2 tests, 1 failure
```

The offending path is named. Reverted by file copy from a backup, not by
`git checkout --`.

**(b) With the scan deliberately blinded** — `@scoped_call_regex` changed to
`~r/\bsubscribeXboard\(\s*\w+:/`, everything else untouched:

```
  1) test global board subscriptions in async tests the scan actually sees scoped
     subscriptions in async files (non-vacuity anchor)
     The source scan found NO scoped `subscribe_board(task: ...)` call in ANY
     `async: true` test file. ...
     async: true files the scan saw at all: ["platform/tasks/board_topic_scope_test.exs",
       "platform/tasks/plan_test.exs", "platform/tasks/tasks_context_test.exs"]
2 tests, 1 failure
```

The offender assertion stayed GREEN throughout (b) — which is exactly the vacuous pass
the anchor exists to expose, and why the anchor carries the whole burden of proof here:
with the offender set legitimately empty, only the anchor can distinguish "clean" from
"blind".

**(c) Clean, both reverts applied:**

```
2 tests, 0 failures
```

## 3. Quarantine entry retired

Deleted from `test/support/test_quarantine.ex`: the `:intermittent` entry for
`test/platform/tasks/plan_test.exs: broadcasts {:plan_updated, supersedee} BEFORE
{:plan_updated, new_plan}` (`added_on: ~D[2026-07-26]`). The module's own moduledoc
holds that "every entry names a test the suite cannot currently trust", and that test
went 0/20 red in stage 3's post-change sweep after 8/20 red immediately before, at
comparable load. `test/platform/test_quarantine_test.exs` still passes (17 tests, 0
failures). **No new entry was added for this task** — the fix is the resolution, not a
quarantine.

## 4. What was ruled out, and why

**(a) Replacing the global topic with per-scope topics — REJECTED.** Four production
subscribers are legitimately board-scoped: `tasks_live.ex` (the kanban, which must see
every card move), `shell_live.ex` (the nav badge count), `task_router.ex` and
`task_router_watcher.ex` (which subscribe globally and filter, because the router's job
is precisely to react to any task's transitions). Removing the global topic would break
the board and the badge. Stage 2 therefore ADDED scoped topics alongside the global one:
`broadcast_board/1` publishes to both, and each subscription gets exactly one copy.

**(b) Id-pinning in the assertions alone (the ticket's option 2) — REJECTED as
sufficient**, though applied where it helps. One of the two measured-vulnerable sites is
a `refute_receive` on an event that is never emitted: `tasks_context_test.exs`'s
"create_epic/1 does NOT broadcast when the changeset is invalid". The epic is never
inserted, so there is no id in existence to pin into the pattern; only a scope the
foreign broadcast cannot reach fixes it. Pinning was still applied in `plan_test.exs` as
strictly-stronger belt-and-braces on top of the scoping.

**(c) Narrowing `TaskRouter` to a per-task subscription — DEFERRED, not done.** It would
change router semantics, and the router's existing subscribe-globally-then-filter is
correct for a component whose remit is the whole board. It belongs in its own task with
its own measurement, not smuggled into a test-isolation fix.

## 5. Honest limits

* The 0/20 post-change sweep is stage 3's, re-read here, not re-run in stage 5.
* `tasks_context_test.exs`'s invalid-changeset case was never observed failing in any
  sweep. Its subscription was scoped on the strength of the argument in (b) above, not
  of a measurement, and this note does not claim a measured improvement for it.
* The guard proves a source-level property. It cannot prove the absence of a board race
  arising some other way — e.g. a future async module subscribing through a helper that
  wraps `subscribe_board/0` under a different name. It catches the direct call, which is
  how every instance in this task's history was written.
