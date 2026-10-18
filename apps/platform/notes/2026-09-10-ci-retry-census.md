# CI retry census — the disk-space warning does not explain the retries (task 01a08bfd, stage 2)

**This note is a deliverable, not commentary.** The number it carries is what decided
the design of the `Run tests` step in `.github/workflows/ci.yml`, and it is the control
that dismisses the ticket's suspected confound. Every count below is re-derivable from
the command in §5.

---

## 1. TL;DR

| Claim | Measurement |
|---|---|
| CI runs that retry-greened | **13 of 40** (32.5%) |
| CI runs carrying `Free space left: 0 MB` | **40 of 40** (100%) |
| Does disk exhaustion explain the retries? | **No.** A signal on 100% of runs has zero discriminating power over an outcome on 32.5% of them. |
| Is the 0 MB runner a real problem? | **Yes — a separate one.** It deserves its own ticket. It is not this ticket's cause. |

This **corrects** the ticket, which frames the `Free space left: 0 MB` warning as
"possibly related" to the `local_runner_test.exs` flake. It is not related; it is
merely omnipresent.

## 2. Run window

40 **completed** `ci.yml` workflow runs, all branches, newest first:

* newest: run `34512290365`, `2026-09-10T18:06:31Z`
* oldest: run `34429193716`, `2026-09-10T02:22:32Z`

One run in flight at census time (`34517708055`) was excluded — an incomplete run has
incomplete annotations, and counting it would depress both rates by an unknown amount.

A census is a claim with a timestamp. The planner's census (also 2026-09-10, earlier in
the day) reported 13/40 retry and 39/40 disk. This independent re-run reports 13/40 and
**40/40**. The retry count matches; the disk count is one higher, which strengthens
rather than weakens the argument.

## 3. Per-run results

`retry` = the job carried the `initial mix test failed; retrying failed tests serially`
annotation. `disk` = the job carried `You are running out of disk space ... Free space
left: 0 MB`. Annotations were collected across **all** jobs of each run (`Test` and
`Build and push image`), not just the test job.

| run id | created (UTC) | conclusion | retry | disk |
|---|---|---|---|---|
| 34512290365 | 18:06:31 | success | – | yes |
| 34511836908 | 18:02:06 | success | – | yes |
| 34511027978 | 17:54:06 | success | – | yes |
| 34510546759 | 17:49:20 | success | **yes** | yes |
| 34508695023 | 17:31:05 | success | **yes** | yes |
| 34508360073 | 17:27:47 | success | **yes** | yes |
| 34507488848 | 17:19:20 | success | **yes** | yes |
| 34507040013 | 17:15:03 | success | **yes** | yes |
| 34506560077 | 17:10:17 | success | – | yes |
| 34505262105 | 16:57:35 | success | – | yes |
| 34504918566 | 16:54:08 | success | **yes** | yes |
| 34503647790 | 16:41:36 | success | – | yes |
| 34497378332 | 15:42:19 | success | **yes** | yes |
| 34496184083 | 15:31:21 | success | **yes** | yes |
| 34479318143 | 12:53:38 | success | **yes** | yes |
| 34478336271 | 12:43:31 | success | – | yes |
| 34477781753 | 12:37:38 | success | – | yes |
| 34476791446 | 12:27:07 | success | **yes** | yes |
| 34471311795 | 11:26:36 | success | **yes** | yes |
| 34470476076 | 11:17:03 | success | – | yes |
| 34468196416 | 10:51:00 | success | – | yes |
| 34468155376 | 10:50:31 | **failure** | **yes** | yes |
| 34467146995 | 10:38:49 | success | – | yes |
| 34451417798 | 07:43:45 | success | – | yes |
| 34449806079 | 07:24:35 | success | – | yes |
| 34449293465 | 07:18:21 | success | – | yes |
| 34448435821 | 07:07:52 | success | – | yes |
| 34447762763 | 06:59:42 | success | – | yes |
| 34446978348 | 06:49:38 | success | – | yes |
| 34444823903 | 06:21:14 | success | – | yes |
| 34443806399 | 06:06:52 | success | – | yes |
| 34443707062 | 06:05:27 | success | – | yes |
| 34443149755 | 05:57:29 | success | – | yes |
| 34443079535 | 05:56:25 | **failure** | – | yes |
| 34435050123 | 03:53:24 | success | **yes** | yes |
| 34434491037 | 03:44:39 | success | – | yes |
| 34431481781 | 02:57:57 | success | – | yes |
| 34430942764 | 02:49:31 | success | – | yes |
| 34429749257 | 02:30:57 | success | – | yes |
| 34429193716 | 02:22:32 | success | – | yes |

Totals: **retry 13/40**, **disk 40/40**.

Contingency, which is the whole argument in one table:

|  | disk warning | no disk warning |
|---|---|---|
| retried | 13 | 0 |
| did not retry | 27 | 0 |

The warning is present on every run in **both** rows. It cannot separate them. If the
disk warning appeared only on the retrying runs, the confound would be live and half A's
premise would be in doubt — it does not, so it is not.

## 4. What the base rate rules out, and what it does not

**Rules out:** disk exhaustion as the *cause* of the first-pass test failures that the
serial retry then greens. 27 runs hit `Free space left: 0 MB` and passed on the first
pass. A condition that co-occurs with both outcomes at the same rate explains neither.

**Does not rule out, and is not claimed:** that the 0 MB runner is harmless. It is a
real operational problem — a runner at zero free space will eventually fail hard rather
than flakily — and it warrants its own ticket. It is simply not this ticket's mechanism.

## 5. The exact command

Run from a checkout with `gh` authenticated against `Startup-Suite/core`:

```bash
gh run list --workflow=ci.yml --limit 60 \
  --json databaseId,createdAt,conclusion,status \
  | jq -r '[.[] | select(.status=="completed")] | .[0:40] | .[] | "\(.databaseId)\t\(.createdAt)\t\(.conclusion)"' \
  > census-runs.tsv

for rid in $(cut -f1 census-runs.tsv); do
  msgs=$(for j in $(gh api "repos/Startup-Suite/core/actions/runs/$rid/jobs" \
                      --jq '.jobs[].id' < /dev/null); do
           gh api "repos/Startup-Suite/core/check-runs/$j/annotations" \
             --jq '.[].message' < /dev/null
         done)
  retry=0; disk=0
  case "$msgs" in (*"initial mix test failed"*) retry=1;; esac
  case "$msgs" in (*"running out of disk space"*) disk=1;; esac
  printf "%s\t%s\t%s\n" "$rid" "$retry" "$disk"
done | awk -F'\t' '{r+=$2; d+=$3; n++} END {print "runs="n, "retry="r, "disk="d}'
```

**Apparatus warning, recorded because it nearly produced a false census.** A first
version of this loop used `while IFS=$'\t' read ... done < census-runs.tsv` with
un-redirected `gh` calls inside. It printed **`retry=0 disk=0`** — a clean, plausible,
entirely fabricated zero, with no error on any line. Both counters reading zero is what
exposed it; a single zero would have been believable. The `< /dev/null` on each `gh`
invocation, and iterating over `$(cut -f1 ...)` rather than reading the loop's stdin,
are what make the numbers above real. If you re-derive this and get zeros, suspect the
loop before you conclude the annotations changed.

## 6. Why the count decided the design

At 13/40 (~32.5%), a rule of the form *"fail the build after N retry annotations in a
window"* would block roughly a third of merges. It would be switched off within a week,
and a control that gets switched off is worse than no control, because for that week it
also stops anyone from building the one that would have survived.

So the change landed in this stage is **aggregation and naming, not failing the build**:

* the first pass's exit status is captured correctly (see §7),
* on failure, a `::warning::` names every failed test with its `file:line`,
* on a green retry, a `$GITHUB_STEP_SUMMARY` block titled **Retry-greened tests** lists
  the same names,
* the step's success/failure semantics are **unchanged**: a first-pass failure the retry
  does not fix still fails the build.

## 7. The exit-status trap this step was one line away from shipping

`mix test --include slow | tee log` reports **tee's** exit status, not `mix test`'s.
Written naively, `mix test --include slow | tee log || (retry)` would **never** fire the
retry, and every first-pass failure would report as a pass. That is strictly worse than
the silent one-liner it replaces: it converts real red builds into green ones.

Demonstrated locally against a stub `mix` that exits 1:

```
naive   (no pipefail):  mix test --include slow | tee log   -> exit 0   # wrong
guarded (pipefail):     mix test --include slow | tee log   -> exit 1   # correct
```

The shipped construct is `set -o pipefail` followed by
`if ! mix test --include slow 2>&1 | tee "$first_pass_log"; then`. The `if !` context
additionally suspends the default `bash -e` errexit, so a red first pass reaches the
retry rather than aborting the step.

## 8. Why the log is grepped and the `--failed` manifest is not

The stage offered both. The manifest was inspected rather than assumed:

```
$ file  _build/test/lib/platform/.mix/.mix_test_failures
... data
$ xxd  _build/test/lib/platform/.mix/.mix_test_failures | head
00000000: 8368 0261 0174 0000 0001 6802 773a 456c  .h.a.t....h.w:El
```

It is an Erlang external-term-format binary (`0x83` ETF magic), not text. It stores
module, test **name** and absolute file path, and carries **no line number**. Parsing it
from shell would need an escaping BEAM subprocess, and it still could not produce
`file:line`. The first pass's own ExUnit failure blocks carry `test/....exs:NNN`
directly, so the log is grepped.

## 9. The masked population is already known to be bigger than one test

@[Dalton] owns task `01a08b5f-9d25`, a **different** flake class: a cross-test telemetry
handler attach leak (`refute_received {:delivered_but_open_telemetry, _, _}`), now known
to span at least four files across three runs. That class is out of scope here and was
not touched.

It is, however, the strongest argument for this stage. The retry annotation is currently
the **only** thing that made any of those four files visible at all — and it did so
without naming a single one of them. So the population of flakes this workflow has been
masking is already known, by direct evidence, to be larger than the one test in half A
of this ticket. That is the case for naming, independent of any per-test fix.

## 10. What is NOT verified

Stated plainly rather than left for a reader to notice:

* **The new retry path has never run in GitHub Actions.** A workflow edit cannot be
  executed locally. It was exercised against a stub `mix` on mac-host in three scenarios —
  first pass green (exit 0, no warning, no summary), first pass red + retry green
  (exit 0, warning and summary both naming the tests with `file:line`), first pass red +
  retry red (exit 1, no summary) — under `bash -e` to match the runner's default shell.
  That is a shell-semantics check, not proof GitHub executed it.
* The only in-suite checks available are `Platform.SlowTestsTest` (a **drift alarm** on
  the workflow's text, which cannot prove execution — its own moduledoc says so) and
  YAML parseability. Stage 3 adds more text guards; they are text guards too.
* A green local suite carries no weight on this change. Nothing in `apps/platform`
  executes `.github/workflows/ci.yml`.
* The census covers one calendar day. A 32.5% retry rate over 40 runs on 2026-09-10 is
  not a claim about last week.

## 11. Addendum (task 01a08d81) — the `first-run-green` check, and why it is keyed to an outcome, never a rate

**Window-attached rates.** A rate is a claim with a window; two were measured on
2026-09-10 and they do not agree, which is itself the finding:

| window (UTC, created_at) | runs | retry-greened | rate |
|---|---|---|---|
| 02:22Z – 18:06Z (§2–§3 above, oldest `34429193716`, newest `34512290365`) | 40 | 13 | 32.5% |
| 12:37Z – 22:32Z (later census, same annotation matcher as §5) | 40 | 21 | 52.5% |

The two windows overlap for ~5.5 hours and still differ by twenty points, because the
later one is dominated by the evening's PR traffic. Any threshold rule — "fail after N
retries in M runs", "fail when the rate exceeds X%" — would therefore have fired or not
fired on the same code depending on what else was merging that afternoon. That is not a
property of the code under test, and a check whose verdict depends on the neighbours'
traffic is one that gets switched off (§6).

**Design rule: keyed to an outcome, never a rate.** The `Test` job's *conclusion* is
`success` for both first-run-green and failed-then-retry-green, and branch protection can
only require a named check by its conclusion (`GET /repos/…/branches/main` reports
`required_status_checks.contexts: ["Test"]`; the ticket's own pair `34476791446` red-retry
and `34478336271` clean both conclude `success`). So the retry census can never become a
gate through `Test`. What can is a **separate check whose conclusion IS the per-run
outcome**:

* `Run tests` now carries `id: run-tests` and writes `retry_fired=true` to
  `$GITHUB_OUTPUT` inside the retry-green branch, `retry_fired=false` after a green first
  pass (a retry-red path exits 1 and writes nothing; `Test` is red, which protection
  already blocks). The `test` job exposes it as `outputs.retry_fired`.
* A new job **`first-run-green`** (`needs: test`, same runner class, no container, no
  checkout) reads `needs.test.outputs.retry_fired` and exits 1 iff it is `true`. It runs
  no tests, so it has no flakes of its own, and it has no `||` retry.
* `Test`'s semantics are **unchanged**: it is still green on retry-green. Nothing merging
  today is blocked by the new job until protection is told to require it — until then it
  is advisory, a red "first-run-green" check on a green PR.
* `Platform.CiFirstRunGreenTest` is the drift alarm on all of the above (text only, like
  every other guard on this file).

**Positive control.** A check must be shown to produce both outcomes before it is
required; the reference pair above predates the job and cannot exercise it. The PR that
added the job carries its own pair: a throwaway commit with a test that fails once (marker
file) and passes on the serial retry — `first-run-green` red on that run — then the
revert — `first-run-green` green. Both run ids are in the PR body.

**The product owner's click.** Settings → Branches → protection rule for `main` → required status
checks: keep `Test`, add `first-run-green`. From that moment a retry-green PR cannot merge
until it is re-run first-run-green (or its flake is fixed), which is the point.
