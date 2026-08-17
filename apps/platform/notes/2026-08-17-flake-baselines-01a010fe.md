# Flake baselines — task `01a010fe-d286-741f-9ea4-1de24baa4e4a`, stage 1

Measurement only. No test code and no `lib/` code was changed by this stage.
Branch created from `origin/main` @ `8f26cc9d`.

All runs from `apps/platform` with an isolated `PLATFORM_TEST_DATABASE`, each rep
a fresh BEAM at a distinct `--seed`. No run was truncated through `tail`/`head`;
every rep was written to its own file and the files were grepped.

## The asymmetry rule (governs stages 2-5)

> A rep count carries evidence only against a non-zero baseline. If a target's
> baseline is 0/N, then post-fix green reps are equally consistent with "fixed"
> and "never fired", and the fix must stand on a detonation instead.

---

## TARGET A — attachment-root collision

**Scope command**

```
mix test test/platform/agents/avatar_storage_test.exs \
         test/platform/files/storage_test.exs \
         test/platform/files_test.exs \
         test/platform/chat
```

1203 tests per rep.

**Baseline: 9 failures / 20 reps.** Seeds 1001-1020.

- Load before batch: `9.95 19.05 18.91`; after: `17.57 18.21 18.70`.
  Per-rep 1-minute load ranged 11.1 - 26.0.
- Failing seeds: **1005, 1008, 1009, 1011, 1012, 1014, 1016, 1017, 1018**.
- Passing seeds: 1001, 1002, 1003, 1004, 1006, 1007, 1010, 1013, 1015, 1019, 1020.

**Rotating identity.** Seven distinct test names failed across the nine reds, and
the failure count varied per rep (1, 2 or 3) at different seeds. Two seeds that
failed in the first batch (1005, 1009) **passed** when re-run at the same seed in
a later batch. Same seed, different outcome, is proof of a race rather than
seed-dependent ordering.

**Four distinct signatures, not the two in the ticket.**

1. `{:error, :enoent}` MatchError (seed 1005, `avatar_storage_test.exs:106`):

```
  1) test get/1 and delete/1 get/1 streams the stored bytes back (Platform.Agents.AvatarStorageTest)
     test/platform/agents/avatar_storage_test.exs:106
     ** (MatchError) no match of right hand side value:

         {:error, :enoent}

     code: {:ok, stream} = AvatarStorage.get(result.storage_key)
     stacktrace:
       test/platform/agents/avatar_storage_test.exs:115: (test)
```

2. `File.exists?` false against the **production** root (seed 1014) — this is the
   decisive one, see the mechanism section:

```
  1) test put/3 key namespace writes under agent-avatars/ and never under chat/ (Platform.Agents.AvatarStorageTest)
     test/platform/agents/avatar_storage_test.exs:54
     Expected truthy, got false
     code: assert File.exists?(AttachmentStorage.path_for(result.storage_key))
     arguments:

         # 1
         "/data/platform/chat_uploads/agent-avatars/18738639-4a7e-4c82-875b-2766ecf5ba8e/c06cb1d0-39ff-4cb7-8512-3983e93cb893-face.png"

     stacktrace:
       test/platform/agents/avatar_storage_test.exs:68: (test)
```

3. A delete that does not delete — `refute File.exists?` returning true (seed 1012),
   the victim's own scratch path:

```
  1) test get/1 and delete/1 delete/1 removes the blob (Platform.Agents.AvatarStorageTest)
     test/platform/agents/avatar_storage_test.exs:127
     Expected false or nil, got true
     code: refute File.exists?(path)
```

4. `File.rm_rf!` raising inside `on_exit` (seed 1011):

```
  1) test put/3 key namespace put/3 reports the real byte size and content hash (Platform.Agents.AvatarStorageTest)
     ** (File.Error) could not remove files and directories recursively from
     ".../avatar_storage_test-5dorm3hwoxsia2wn-…": file already exists
     stacktrace:
       (elixir) lib/file.ex:1681: File.rm_rf!/1
       (ex_unit) lib/ex_unit/on_exit_handler.ex:140: ExUnit.OnExitHandler.exec_callback/1
```

`{:error, :erofs}` also appeared (seed 1008), alongside `:enoent` in the same rep.

### Population re-derived, not inherited

Search used, at `8f26cc9d`:

```
git grep -l -E "Application\.(put_env|delete_env)\(:platform, :chat_attachments_root" -- apps/platform/test
```

**31 files.** Of those, exactly **three** are `async: true`:
`test/platform/agents/avatar_storage_test.exs`, `test/platform/files/storage_test.exs`,
`test/platform/files_test.exs`. ExUnit runs sync modules only after every async
module finishes, so those three are the whole concurrent-collision set.

A caution for whoever re-runs this: a naive `grep -qE "async:\s*true"` over the 31
returns **four**, adding `test/platform/files/withdraw_from_agent_context_test.exs`.
That file is `use Platform.DataCase, async: false` at :20; the match is its
**moduledoc at :9 mentioning `async: true`**. A source scanner cannot tell a
comment from a call. The three-file figure is correct.

### Mechanism — confirmed in shape, and the plan's premise is wrong about the value

The plan's premise reads: "`config/test.exs:28` sets it at boot, so `prev` is
non-nil in every file and `on_exit` restores by `put_env(prev)` — meaning a
sibling's cleanup repoints the root to the SHARED `config/test.exs` path
mid-test."

**`prev` is non-nil: confirmed. The value it restores is not the `config/test.exs`
path: refuted, measured.**

`config/runtime.exs:177` sets `chat_attachments_root:
System.get_env("CHAT_ATTACHMENTS_ROOT", "/data/platform/chat_uploads")`. It is
unguarded by env and loads after `config/test.exs`, so it wins. Measured
directly rather than read:

```
$ MIX_ENV=test mix run -e 'IO.inspect(Application.get_env(:platform, :chat_attachments_root))'
"/data/platform/chat_uploads"
```

`config/test.exs:28`'s tmp path is dead — nothing ever observes it. So every
`on_exit` in all 31 files restores the VM-global root to a **production** path
that does not exist and whose parent is read-only. That is where `:erofs` comes
from, which the `config/test.exs` account could not explain at all.

Signature 2 above is the direct observation, from an uninstrumented rep: the
test's own `setup` had put a `Platform.TestTemp` scratch root, and by the time
the assertion resolved the path it read `/data/platform/chat_uploads/...`. The
root moved between write and read, to exactly the boot value.

Instrumented reps (temporary `IO.puts` in the three `on_exit` blocks, reverted,
not committed) show `avatar` and `storage` restores from **distinct pids**
interleaving densely inside a victim's test — e.g. at seed 1011, five restores
from five pids across two files inside one failing window.

**What was not established.** I did not capture a single trace pairing one
victim's write-root and its read-root with the exact intervening pid. The
evidence is (a) a read-time root equal to the boot value while setup had set a
scratch, and (b) concurrent restores from distinct pids. That supports the
mechanism; it is not a single-trace proof of it, and stage 2 should not cite it
as one.

**Note for stage 2.** `avatar_storage_test.exs:27` already calls
`Platform.TestTemp.mkdir!/1`, so each test already has a unique *directory* and
still fails. The missing property is ownership of the *read*, not uniqueness of
the *value*.

**VERDICT (A): reproduces, 9/20 at load 11-26. Non-zero baseline, so post-fix rep
counts are admissible evidence. The failing seeds above must be inside any
post-fix batch.**

---

## TARGET B — `Platform.Orchestration.TaskRouterStageIsolationTest:307`

**Scope command**

```
mix test test/platform/orchestration
```

1005 tests per rep.

**Baseline: 0 failures / 20 reps.** Seeds 2001-2020.

- Load before batch: `9.99 14.82 17.01`; after: `9.24 8.65 9.79`.
  Per-rep 1-minute load ranged 7.3 - 10.3 — a genuinely quiet box.
- No seed failed. No `N) test` block appeared in any of the 20 logs.

**Anti-vacuity check.** A 0/N is worthless if the test never ran, so this was
checked rather than assumed:

```
$ mix test --seed 2001 test/platform/orchestration/task_router_stage_isolation_test.exs --trace
  * test no_ack alarm fires per stage, independent of prior stage state (346.2ms) [L#307]
4 tests, 0 failures
```

The test executes and is not excluded by any tag. The 0/20 is a real zero, not a
never-ran.

**Scope caveat, recorded rather than acted on.** The original observation was
made incidentally during a *full* suite on a heavily contended box. This batch
was a directory-scoped run on a quiet one. That is a difference in conditions and
it may be why nothing fired. It is not a reason to extend reps: the plan's
terminal-outcome rule applies, and hunting for a failure until one appears would
produce a number with no denominator.

**THE ASYMMETRY RULE APPLIES TO THIS TARGET.** Target B's baseline is 0/20.
Post-change green reps for this target would be equally consistent with "fixed"
and "never fired". Any stage-3 change must rest on a **detonation**, not on a rep
count, and its commit message must say so.

**The `Process.sleep(100)` at :324 is still only a hypothesis.** The measurement
neither confirmed nor refuted it, because nothing failed. Its presence is not
evidence: the lease row being late and the lease row never being written in some
interleaving are different defects needing opposite fixes, and this batch
separates neither.

**VERDICT (B): 0/20 at load 7.3-10.3, scope `mix test test/platform/orchestration`.
Did not reproduce. No test was tagged, quarantined or modified. Terminal outcome
for this stage; stage 3 runs only on a detonation.**

---

## Summary

| Target | Scope | Baseline | Load | Evidence status |
| --- | --- | --- | --- | --- |
| A — attachment root | 3 async files + `test/platform/chat` | **9/20** | 11-26 | Reproduces; reps admissible |
| B — stage-isolation lease | `test/platform/orchestration` | **0/20** | 7.3-10.3 | Did not reproduce; detonation-only |
| C — ShellLive mic icon | `shell_live_test.exs` / `test/platform_web/live` | **2/29** and **1/10** | 7.9-10.7 | Reproduces; measured only, not fixed (see stage 4 below) |

The targets do not have the same evidence shape and must not be written up
under one summary sentence.

---

# TARGET C — ShellLive mic-icon red (stage 4)

Measurement only. **No test code and no `lib/` code was changed by this stage.**
`test/platform_web/live/shell_live_test.exs` is byte-identical to `origin/main`.
This target was included to get a *number*, not a fix; a fix, if warranted,
belongs to a new ticket.

Target: `PlatformWeb.ShellLiveTest`, test
`broadcast_media_state(mic_enabled: false) updates the bar's rendered mic button`
at `test/platform_web/live/shell_live_test.exs:1122`, failing assertion at
`:1157`. The file is `use PlatformWeb.ConnCase, async: false` (`:2`), so it is
**not** target A's family and the stage-2 fix has no bearing on it.

## Anti-vacuity proof — the target really runs

A 0/N is only a real zero if the test is shown to execute. It is:

```
* test meeting state hydration broadcast_media_state(mic_enabled: false) updates
  the bar's rendered mic button (57.7ms) [L#1122]
```

from `mix test test/platform_web/live/shell_live_test.exs --seed 3001 --trace`
— 85 tests, executing, not excluded and not skipped. (This is moot here, since
the target did reproduce, but it is recorded so the zero-vs-never-ran question
cannot be reopened.)

## Scope commands

- File-isolated: `mix test test/platform_web/live/shell_live_test.exs --seed <s>` (85 tests)
- Batched: `mix test test/platform_web/live --seed <s>` (2361 tests)

## Pre-change baseline (there is no post-change; nothing was changed)

| Scope | Reps | Failures | Failing seeds | Load (1-min range) |
| --- | --- | --- | --- | --- |
| File-isolated, plain | 20 (seeds 3001-3020) | **1** | `3020` | 7.91 - 9.54 |
| File-isolated, `--trace` | 9 (seeds 3001-3008, plus the initial 3001 proof run) | **1** | `3001` (first run only) | 9.16 - 10.20 |
| File-isolated, combined | **29** | **2** | `3020`, `3001` | 7.91 - 10.20 |
| Batched `test/platform_web/live` | 10 (seeds 4001-4010) | **1** | `4006` | 8.70 - 10.70 |

**Measured rate: ~5-7% file-isolated (2/29), 1/10 batched.** It reproduces in
both scopes on a quiet box. This is a real, non-zero baseline.

## Verbatim failure signature

Identical in all three failures (`3020` file-isolated, `3001` under `--trace`,
`4006` batched), modulo the LiveView DOM id:

```
  1) test meeting state hydration broadcast_media_state(mic_enabled: false) updates the bar's rendered mic button (PlatformWeb.ShellLiveTest)
     test/platform_web/live/shell_live_test.exs:1122
     Assertion with =~ failed
     code:  assert post_html =~ "hero-microphone-slash"
     left:  "<div id=\"phx-GMyv5aNJ8JDWTRoi\" data-phx-main=\"\" ... "
     right: "hero-microphone-slash"
     stacktrace:
       test/platform_web/live/shell_live_test.exs:1157: (test)
```

The *preceding* assertion at `:1145` (`pre_html =~ "hero-microphone"`) passes in
every failing rep. So the bar renders, and the mic-on state renders; it is only
the post-broadcast state that is missing at the moment the render is taken.

## THE FAILURE IS NOT SEED-DETERMINED — and this killed my first reading

Seed `3001` **failed once and then passed twice at the same seed** (once plain,
once under `--trace`). Seed `3020` failed plain. A fixed seed therefore does not
fix the outcome.

I initially read the first `--trace` failure as a discriminator — "the same seed
passes plain and fails under `--trace`, so `--trace`'s timing perturbation is the
trigger" — and that reading was wrong. Eight further `--trace` reps at the same
and adjacent seeds all passed. **The `--trace` failure was simply the same ~5%
flake landing on the first run.** Recorded because the wrong version of this note
was one confidently-written mechanism away from being written down as a finding.

The load-bearing consequence stands on the rotating identity, not on `--trace`:
the outcome varies with a fixed seed, so this is **not** a seed-ordering flake.
That independently corroborates the CI observation that a same-image retry
(which cannot redraw the ExUnit seed) CLEARED `ShellLiveTest` while leaving
`IntentRoutingTest` red. Target C sits in the **timing/environment** family.

## The PubSub hypothesis: UNREACHABLE by this measurement

The hypothesis was that `broadcast_media_state/2` (`:1147`) is a PubSub broadcast
from another process, that `render(view)` (`:1155`) synchronises with the
LiveView process but not with delivery of that broadcast, and that the render can
therefore be taken before `ShellLive` has handled the message and issued
`send_update/2`. There is no sleep anywhere in this path.

**This measurement can neither confirm nor refute it.** It establishes the
*family* (timing, not seed-ordering) and that is all. Every observation above is
consistent with the hypothesis, but it is equally consistent with any other
timing-dependent path into the same assertion, and consistency is not
confirmation. Reaching the mechanism requires instrumenting or modifying the
test, which this stage is explicitly forbidden to do. Recorded as **open**.

Note also that "the broadcast arrives late" and "the broadcast is not handled at
all in some interleaving" are different defects needing opposite fixes, and
nothing measured here separates them.

## VERDICT (C)

> **REPRODUCES. 2/29 file-isolated (seeds 3020, 3001) at load 7.9-10.2, and 1/10
> batched against `test/platform_web/live` (seed 4006) at load 8.7-10.7. Not
> seed-determined — seed 3001 both failed and passed. Timing/environment family.
> Mechanism open: the PubSub-delivery hypothesis is neither confirmed nor
> refuted, because the measurement cannot reach it. NOT FIXED, NOT QUARANTINED,
> NOT TAGGED, test unmodified — a fix belongs to a new ticket.**

Target C has a **non-zero** baseline, so a future rep count against it *is*
admissible evidence — unlike target B. The three targets in this file have three
different evidence shapes and must not be summarised in one sentence.

## Recommended follow-up ticket

- **Title**: `ShellLiveTest mic-icon assertion races PubSub broadcast delivery`
- **Measured rate**: 2/29 file-isolated, 1/10 batched (this stage, quiet box)
- **Signature**: the verbatim block above
- **Family**: timing/environment; not seed-ordering (proved by rotating identity
  at fixed seed 3001)
- **First move**: establish whether the render at `:1155` can precede the
  `send_update/2` triggered by `:1147` — confirm or refute before changing
  anything. A retry, a poll loop or a `Process.sleep` here would convert a
  false red into a slower false green and is out of bounds.

## `Platform.Meetings.IntentRoutingTest` — confirmed fixed on `main`

No work was done on this target, as instructed. Confirming only:

`01a01037` has now merged as `e0928e4f` ("Fix IntentRoutingTest atom-leak flake;
record ProofRunTest debt as `:unexplained`", PR #774) and is on `origin/main`.
At `e0928e4f`, `test/platform/meetings/intent_routing_test.exs` contains **zero
non-comment references** to `:erlang.system_info(:atom_count)`; the surviving
matches are the comment block at `:61-76` explaining why the equality assertion
was the wrong instrument. The VM-global equality assertion is gone from `main`.

A plain `git grep atom_count` still reports hits on `main` and looks alarming —
those are the explanatory comment, not a call. A source scanner cannot tell a
comment from a call; the check that matters excludes comment lines.

This branch is based on `8f26cc9d` and does not contain `e0928e4f`, so this
worktree still carries the old assertion. That is expected and irrelevant to the
measurement above.

---

# CONSOLIDATED EVIDENCE (stage 5)

This section is the one a later reader should trust. Everything above is the
working record; this is the settled account. **The three targets have three
different evidence shapes and there is deliberately no combined summary
sentence** — writing one flattering line over targets with different evidence
is the specific error that cost real confusion on `01a0108a-9f39`.

Nothing in this stage changed test or `lib/` code. The re-runs and the
detonation below were re-executed for this stage rather than copied from the
earlier stages' reports, because a restated number is not a verified one.

---

## TARGET A — attachment-root collision (`AvatarStorageTest` / `Files.StorageTest`)

**Scope command**

```
mix test test/platform/chat/attachment_storage/root_test.exs \
         test/platform/agents/avatar_storage_test.exs \
         test/platform/files/storage_test.exs \
         test/platform/files_test.exs \
         test/platform/chat
```

**Pre-change baseline: 9 failures / 20 reps** (seeds 1001-1020), load 9.95 ->
17.57 with per-rep 1-minute load 11.1 - 26.0.
Failing seeds: **1005, 1008, 1009, 1011, 1012, 1014, 1016, 1017, 1018**.
Four distinct signatures: `{:error, :enoent}` MatchError, `{:error, :erofs}`,
`refute File.exists?` returning true, and `File.rm_rf!` raising inside
`on_exit`.

**Same-seed non-determinism.** Seeds 1005 and 1009 failed in the baseline batch
and **passed** when re-run at the same seed. Same seed, different outcome, is
proof of a **race** rather than seed-dependent ordering. This is what makes the
rep counts below readable as evidence at all.

**What changed.** `4a77e0f6` — the storage-root read became process-scoped
(`Platform.Chat.AttachmentStorage.Root`) instead of a VM-global
`Application.put_env` key, so a sibling module structurally cannot repoint a
victim's root mid-test. No sleep, no retry, no poll loop, no `async: true` ->
`async: false` flip.

### Detonation — verbatim red, re-run in this stage

Mutant: `Root.get/1` amended to discard the process-scoped lookup and always
return the caller's app-env fallback, i.e. exactly the pre-change VM-global
read.

```
mix test test/platform/agents/avatar_storage_test.exs \
         test/platform/files/storage_test.exs --seed 1005
25 tests, 13 failures
```

```
  1) test put/3 + get/1 round-trip persists a binary and returns size + sha256 hash (Platform.Files.StorageTest)
     test/platform/files/storage_test.exs:41
     match (=) failed
     code:  assert {:ok, %{storage_key: key, content_hash: hash, byte_size: size}} =
              Storage.put({:binary, "hello world"}, project_id, filename: "greeting.txt")
     left:  {:ok, %{storage_key: key, content_hash: hash, byte_size: size}}
     right: {:error, :erofs}
     stacktrace:
       test/platform/files/storage_test.exs:44: (test)
```

with the adapter log naming the root it fell back to:

```
[error] [chat.attachment_storage.local_disk] mkdir_p failed:
  dir="/data/platform/chat_uploads/files/00000000-0000-0000-0000-000000000fff/…"
  reason=:erofs storage_root="/data/platform/chat_uploads"
```

That path is the repo's own default from `config/runtime.exs`, not a
deployment secret, and it is load-bearing: it is the direct observation that the
global root resolves to an unwritable production path, which is the only account
that explains the `:erofs` signature. The mutant was reverted; the working tree
is clean.

**The assertions can see the mechanism.** 13 of 25 reddened, across both files
and three of the four baseline signatures.

### Post-change reps — verified in this stage, not restated

Every one of the nine baseline failing seeds re-run on the fixed tree:

| Seed | Result | 1-min load at start |
| --- | --- | --- |
| 1005 | 1210 tests, 0 failures, 1 skipped | 7.24 |
| 1008 | 1210 tests, 0 failures, 1 skipped | 9.60 |
| 1009 | 1210 tests, 0 failures, 1 skipped | 10.78 |
| 1011 | 1210 tests, 0 failures, 1 skipped | 11.57 |
| 1012 | 1210 tests, 0 failures, 1 skipped | 11.27 |
| 1014 | 1210 tests, 0 failures, 1 skipped | 10.90 |
| 1016 | 1210 tests, 0 failures, 1 skipped | 10.80 |
| 1017 | 1210 tests, 0 failures, 1 skipped | 10.38 |
| 1018 | 1210 tests, 0 failures, 1 skipped | 10.50 |

**0 failures / 9 reps at the nine seeds that failed pre-change.** No `N) test`
header appeared in any log; no run was truncated.

**A weakness in this evidence, stated rather than omitted.** The baseline batch
ran at 1-minute load **11.1 - 26.0**; this post-change batch ran at **7.2 -
11.6**. The post-change window was meaningfully quieter than the window that
produced the failures. Since the defect is a race, lower contention independently
lowers the failure probability, so the rep count alone is weaker than the bare
9/20 -> 0/9 comparison suggests. The load-bearing evidence for target A is the
**detonation**, which is contention-independent; the reps corroborate it.

> **VERDICT (A): REPRODUCED (9/20 at load 11-26), FIXED in `4a77e0f6`, and the
> fix DETONATED — reinstating the VM-global read reddens 13/25 with the verbatim
> `{:error, :erofs}` signature above. All nine baseline failing seeds re-run
> green post-change (0/9), verified in this stage; that batch ran at lower load
> than the baseline, so the detonation carries the weight and the reps
> corroborate.**

---

## TARGET B — `TaskRouterStageIsolationTest:307`

**Scope command**

```
mix test test/platform/orchestration
```

**Pre-change baseline: 0 failures / 20 reps** (seeds 2001-2020), load 7.3 - 10.3.

**Anti-vacuity: the zero is real, not a never-ran.** `--trace` at seed 2001 shows
the target executing:

```
* test no_ack alarm fires per stage, independent of prior stage state (346.2ms) [L#307]
```

**What changed: nothing.** Stage 3 skipped on its own opening condition.
`test/platform/orchestration/task_router_stage_isolation_test.exs` is
byte-identical to `origin/main` (verified in this stage: `git diff origin/main`
on that path is empty). No tag, no quarantine entry, no rewrite.

**Detonation: none, and none was possible.** There is no change to detonate. A
detonation here would have to be a mutant of a fix that does not exist.

**Post-change reps: none, and none would mean anything.** Because nothing
changed, there is no "post-change" state. And per the asymmetry rule, even if
reps had been run: **against a 0/N baseline, green reps are equally consistent
with "fixed" and "never fired", so they would prove nothing.**

**The `Process.sleep(100)` hypothesis is neither confirmed nor refuted.** Nothing
failed, so the hypothesised path was never reached. Its mere presence in the
source is not evidence. Note that "the lease row is written late" and "the lease
row is never written in some interleaving" are different defects needing
opposite fixes, and no observation here separates them.

**Conditions differed from the original sighting, and that is why the door stays
open.** The original was incidental, inside a **full suite on a heavily contended
box**. This was **directory-scoped on a quiet box**. Non-reproduction under
narrower conditions than the sighting is not a refutation of the sighting.

> **VERDICT (B): DID NOT REPRODUCE — 0 failures / 20 reps at load 7.3-10.3, scope
> `mix test test/platform/orchestration`. NOT "fixed": nothing was changed, so
> "fixed" is not a state this target can be in. Mechanism UNRESOLVED, the
> `Process.sleep(100)` hypothesis neither confirmed nor refuted. Measured under
> narrower conditions (directory-scoped, quiet) than the original sighting (full
> suite, heavily contended), so the target is open, not closed.**

---

## TARGET C — `ShellLiveTest` mic icon

**Scope commands**

```
mix test test/platform_web/live/shell_live_test.exs --seed <s>   # 85 tests
mix test test/platform_web/live --seed <s>                       # 2361 tests
```

**Pre-change baseline: 2 failures / 29 reps file-isolated** (failing seeds
**3020**, **3001**; load 7.91 - 10.20) and **1 failure / 10 reps batched**
(failing seed **4006**; load 8.70 - 10.70). Non-zero, in both scopes, on a quiet
box.

Anti-vacuity: `--trace` shows the target executing at 57.7 ms — moot, since it
reproduced, but recorded so the zero-vs-never-ran question cannot be reopened.

**Not seed-determined.** Seed 3001 failed once and then passed twice at the same
seed. A fixed seed does not fix the outcome, which places this in the
**timing/environment** family rather than seed-ordering — independently
corroborating the CI observation that a same-image retry (which cannot redraw
the ExUnit seed) cleared `ShellLiveTest` while leaving `IntentRoutingTest` red.

`use PlatformWeb.ConnCase, async: false`, so this is **not** target A's family
and `4a77e0f6` has no bearing on it.

**What changed: nothing** — measurement-only by design.
`shell_live_test.exs` is byte-identical to `origin/main`.

**Detonation: none, and none was possible** — there is no change to detonate.

**Post-change reps: none** — there is no post-change state.

**Mechanism open.** The PubSub-delivery hypothesis (that `render/1` synchronises
with the LiveView process but not with delivery of the broadcast) is neither
confirmed nor refuted: every observation is *consistent* with it and equally
consistent with any other timing path into the same assertion, and consistency
is not confirmation. Reaching it requires instrumenting the test, which stage 4
was forbidden to do.

> **VERDICT (C): REPRODUCES — 2/29 file-isolated (seeds 3020, 3001) at load
> 7.9-10.2 and 1/10 batched (seed 4006) at load 8.7-10.7. NOT FIXED, NOT
> QUARANTINED, NOT TAGGED, test unmodified — measurement-only by design.
> Timing/environment family, mechanism open. Deliverable is a new ticket, not a
> fix in this task.**

Because target C's baseline is **non-zero**, a future rep count against it *is*
admissible evidence — unlike target B.

---

## QUARANTINE: no entry added, and that is a decision, not an omission

`apps/platform/test/support/test_quarantine.ex` is **untouched by this task**.

An entry is warranted only for a target that **reproduced and was not fixed**:

- **A** reproduced and was fixed. An entry would hide a test that now passes.
- **B** did not reproduce. Tagging a test that was never shown to fail would be
  a false record, and the task explicitly forbids it.
- **C** reproduced and is deliberately unfixed — but it is *unfixed by design*,
  routed to a new ticket, with its rate and verbatim signature recorded here.
  It is **not hidden**: it still runs and still reds. Quarantining it would
  convert a visible, measured, ticketed flake into a suppressed one, which is
  the opposite of what the registry is for.

Had an entry been needed for C, the honest class would have been
**`:unexplained`**, not `:intermittent`: `:intermittent` asserts a known
contended resource and its `:reason` must **name** one that the measurements
*demonstrate*. For C nothing was demonstrated — the PubSub account is a
hypothesis the measurement could not reach — so naming a resource would have
been a false record, and `:unexplained` is never excludable anyway.

Note `main` has moved: `e0928e4f` (task `01a01037`) added an entry to that same
file. This branch is based on `8f26cc9d` and does not carry it. Since this task
adds no entry, there is nothing here to conflict with it.

## Where the three targets stand

There is intentionally no single sentence covering all three. Read the three
verdicts above; they do not say the same kind of thing.

| Target | Reproduced? | Changed? | Detonated? | What carries the confidence |
| --- | --- | --- | --- | --- |
| A — attachment root | Yes, 9/20 | Yes, `4a77e0f6` | **Yes**, 13/25 red | The detonation; reps corroborate |
| B — stage-isolation lease | **No**, 0/20 | **No** | N/A — nothing to detonate | Nothing. Target is open, mechanism unresolved |
| C — ShellLive mic icon | Yes, 2/29 + 1/10 | **No**, by design | N/A — nothing to detonate | The measured rate; fix belongs to a new ticket |
