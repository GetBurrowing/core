#!/usr/bin/env bash
# Measure the TaskRouter-family test flake distribution as a failing SET, not a count.
#
# WHY THIS EXISTS
#
# `apps/platform/test/platform/orchestration/task_router_test.exs` synchronises
# 116 times on fixed `Process.sleep` calls (11.125s of pure sleep per run). A
# fixed sleep is a guess in both directions: too short races the router, too
# long hides a regression behind wall-clock padding. Under load the guess gets
# worse, so the file fails intermittently.
#
# The trap when measuring that is counting. The 019fa003 stage 2 measurement
# found seed 33 producing FIVE failures on both the fixed and the control tree
# with only partly-overlapping membership — i.e. equal counts, different tests.
# A count-only harness reports "no change" there and measures nothing. So this
# script records, for every run, the failing SET as stable-sorted
# `file:line<TAB>test name` lines. Deltas are set differences, never count
# differences.
#
# It also records the conditions of each run. This box is deliberately
# saturated by sibling agents (24-way busy loops were running during the
# 019fa003 stage 2 measurement), and a run taken inside a foreign load spike
# must be identifiable after the fact rather than silently averaged in. Each
# run record therefore carries the load average, the concurrent `mix test`
# process count, the tree's HEAD sha, and the UTC wall clock.
#
# The UTC wall clock matters for one specific known-independent failure:
# `HistorianDispatcherTest` "120KB transcript" fails for ANY run started inside
# the 00:00-01:00 UTC hour, because it filters telemetry by `one_hour_ago`'s
# date while bucketing on today's. That is not a flake this task can fix, and
# attributing it to a conversion would be wrong.
#
# MULTI-TREE ALTERNATION
#
# Pass `--tree LABEL=PATH` more than once and the script alternates trees
# within each (seed, repetition) cell, so a task branch and its control sit
# inside the SAME load window. Non-alternated runs on this box measure sibling
# agents' CPU saturation rather than the code under test.
#
# Usage:
#   scripts/measure-task-router-flake.sh                          # 5 seeds x 3 reps, current tree
#   scripts/measure-task-router-flake.sh --seeds "11 22 33" --reps 2
#   scripts/measure-task-router-flake.sh --tree task=/path/a --tree control=/path/b
#   scripts/measure-task-router-flake.sh --only-target             # task_router_test.exs alone
#
# Options:
#   --seeds "A B C"     seed list           (default "11 22 33 44 55")
#   --reps N            repetitions per seed (default 3)
#   --tree LABEL=PATH   repeatable; default "self=<repo root of this script>"
#   --out DIR           output directory    (default ~/sources/tmp/task-router-flake/<utc-stamp>)
#   --db-prefix NAME    per-tree test DB is <NAME>_<label> (default platform_test_flake)
#   --only-target       measure only task_router_test.exs, not the whole family
#   --allow REGEX       extra porcelain paths tolerated as "expected diff"
#   --no-setup          skip ecto.create/migrate (faster on warm databases)
#
# Exit codes: 0 measurement completed | 2 setup/precondition error.
# A non-zero `mix test` is DATA, not an error: this script expects failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SEEDS="11 22 33 44 55"
REPS=3
TREES=()
OUT_DIR=""
DB_PREFIX="platform_test_flake"
ONLY_TARGET=0
DO_SETUP=1
# Paths this task legitimately owns. Anything else dirty in a measured tree
# means the measurement is contaminated and we refuse to record it.
ALLOW_RE='^(apps/platform/test/platform/orchestration/task_router_test\.exs|scripts/measure-task-router-flake\.sh|T1-STAGE1-NOTES\.md)$'

TARGET_REL="test/platform/orchestration/task_router_test.exs"
FAMILY_REL=(
  "test/platform/orchestration/task_router_test.exs"
  "test/platform/orchestration/task_router_watcher_test.exs"
  "test/platform/orchestration/task_router_supervisor_test.exs"
  "test/platform/orchestration/task_router_stage_isolation_test.exs"
  "test/platform/orchestration/task_router_watcher_stall_sweep_test.exs"
)

log() { printf '[flake] %s\n' "$*"; }
die() { printf '[flake] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --seeds)      SEEDS="$2"; shift 2 ;;
    --reps)       REPS="$2"; shift 2 ;;
    --tree)       TREES+=("$2"); shift 2 ;;
    --out)        OUT_DIR="$2"; shift 2 ;;
    --db-prefix)  DB_PREFIX="$2"; shift 2 ;;
    --allow)      ALLOW_RE="$2"; shift 2 ;;
    --only-target) ONLY_TARGET=1; shift ;;
    --no-setup)   DO_SETUP=0; shift ;;
    -h|--help)    sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[ ${#TREES[@]} -eq 0 ] && TREES=("self=$DEFAULT_ROOT")

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
[ -z "$OUT_DIR" ] && OUT_DIR="$HOME/sources/tmp/task-router-flake/$STAMP"

# ── single-instance guard ───────────────────────────────────────────────────
# This script has no natural mutual exclusion and two invocations SILENTLY
# interleave. Stage 2 of 019fa121 lost an entire measurement to exactly that:
# launched under `nohup … &`, the first run was never reaped, a second launch
# started inside the same UTC second, and both wrote into one output directory
# while their `mix test` processes shared one set of test databases. The only
# visible symptom was `summary.tsv` carrying two rows per (seed, rep, tree)
# cell about two seconds apart — nothing in the per-run records looked wrong,
# and every number in them was contaminated.
#
# The lock is keyed on the DB PREFIX, not on the output directory, because the
# databases are what actually collide: a second launch with its own `--out`
# would still corrupt the first. `flock -n` fails fast and loudly rather than
# queueing, since a measurement that starts 30 minutes late has been taken in
# a different load window and is not the measurement that was asked for.
LOCK_FILE="${TMPDIR:-/tmp}/measure-task-router-flake.${DB_PREFIX}.lock"
exec 9>"$LOCK_FILE" || die "cannot open lock file: $LOCK_FILE"
if ! flock -n 9; then
  die "another measurement already holds db-prefix '$DB_PREFIX' (lock: $LOCK_FILE).
       Wait for it to finish, or re-run with a different --db-prefix. Do NOT
       run two measurements against one database set — the results interleave
       and the only symptom is duplicate rows in summary.tsv."
fi
printf 'pid=%s started_utc=%s out=%s\n' \
  "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OUT_DIR" >&9

# Belt and braces for the observed symptom itself: even with a distinct
# db-prefix, never append into a directory that already carries a measurement.
[ -e "$OUT_DIR/summary.tsv" ] && \
  die "$OUT_DIR already contains a measurement (summary.tsv). Refusing to interleave; pass a fresh --out."

mkdir -p "$OUT_DIR/runs" || die "cannot create $OUT_DIR"

SETS_TSV="$OUT_DIR/failing-sets.tsv"
SUMMARY_TSV="$OUT_DIR/summary.tsv"
printf 'label\tseed\trep\tfile_line\ttest_name\n' > "$SETS_TSV"
printf 'label\tseed\trep\tstarted_utc\thead_sha\tloadavg_1m\tmix_test_procs\twall_s\ttotal_tests\tfailures\tinvalid\tskipped\tdistinct_failing\texit_code\n' > "$SUMMARY_TSV"

# ── validate trees up front, so a typo fails before a 30-minute measurement ──
declare -A TREE_PATH
declare -A TREE_DB
LABELS=()
for spec in "${TREES[@]}"; do
  label="${spec%%=*}"
  path="${spec#*=}"
  [ "$label" = "$spec" ] && die "--tree needs LABEL=PATH, got '$spec'"
  path="$(cd "$path" 2>/dev/null && pwd)" || die "tree '$label' path does not exist: ${spec#*=}"
  [ -d "$path/apps/platform" ] || die "tree '$label' is not a core checkout (no apps/platform): $path"
  TREE_PATH["$label"]="$path"
  TREE_DB["$label"]="${DB_PREFIX}_${label}"
  LABELS+=("$label")
done

# ── preconditions -----------------------------------------------------------
# ABORT rather than record if a measured tree carries an unexpected diff. A
# foreign edit to a tree mid-measurement is indistinguishable from a real
# regression, and that is exactly how two executors produced 5/0/10 failures at
# the same seed on the same file on 2026-07-26 (shared `refs/stash` across
# worktrees of one .git — NEVER run `git stash` in a shared checkout).
check_tree_clean() {
  local label="$1" path="$2" dirty
  dirty="$(cd "$path" && git status --porcelain | awk '{ $1=""; sub(/^ +/,""); print }' \
            | grep -Ev "$ALLOW_RE" || true)"
  if [ -n "$dirty" ]; then
    printf '[flake] ERROR: tree %s (%s) has unexpected modifications:\n%s\n' \
      "$label" "$path" "$dirty" >&2
    printf '[flake]        Refusing to measure a contaminated tree.\n' >&2
    return 1
  fi
  return 0
}

loadavg_1m() { awk '{print $1}' /proc/loadavg 2>/dev/null || echo "na"; }
# `grep -c` prints its count AND exits 1 when the count is zero, so a naive
# `|| echo 0` fallback emits a SECOND line on an idle box. The caller
# interpolates that "0\n0" straight into `summary.tsv`, which splits every
# zero-concurrency row across two lines and shifts every column after it —
# `wall_s`, `failures` and `distinct_failing` all land under the wrong header.
# Stage 6 of 019fa121 was the first measurement taken on a genuinely quiet box
# and so the first to hit it; `failing-sets.tsv` and the per-run records were
# unaffected, which is why it survived four earlier stages unnoticed. Swallow
# grep's exit status rather than adding a fallback that also prints.
mix_test_procs() {
  local n
  n="$(ps -eo args 2>/dev/null | grep -c '[m]ix test')" || true
  printf '%s' "${n:-0}"
}

# ── one-time setup per tree -------------------------------------------------
if [ "$DO_SETUP" -eq 1 ]; then
  for label in "${LABELS[@]}"; do
    path="${TREE_PATH[$label]}"
    log "setup: $label -> ${TREE_DB[$label]}"
    ( cd "$path/apps/platform" \
      && MIX_ENV=test PLATFORM_TEST_DATABASE="${TREE_DB[$label]}" mix ecto.create \
      && MIX_ENV=test PLATFORM_TEST_DATABASE="${TREE_DB[$label]}" mix ecto.migrate \
    ) >"$OUT_DIR/setup-$label.log" 2>&1 \
      || die "setup failed for tree '$label' — see $OUT_DIR/setup-$label.log"
  done
fi

# ── extract the failing SET from ExUnit output ------------------------------
# ExUnit prints, per failure:
#     1) test <name> (<Module>)
#        test/path/file.exs:123
# We emit "file:line<TAB>test name (Module)" and stable-sort, so two runs are
# comparable with a plain `diff` / `comm`.
#
# IMPORTANT — which column is the stable key. `file:line` is NOT comparable
# across stages of this task: deleting 116 sleeps and adding a comment block
# shifts every line number in the file (stage 1's taxonomy header alone moved
# them by +89). The TEST NAME is the stable identity, so the cross-stage set
# comparisons below key on the name and carry file:line only as a locator.
extract_failing_set() {
  awk '
    /^[[:space:]]+[0-9]+\) (test|doctest|property) / {
      name = $0
      sub(/^[[:space:]]+[0-9]+\) /, "", name)
      if ((getline loc) > 0) {
        gsub(/^[[:space:]]+/, "", loc)
        gsub(/[[:space:]]+$/, "", loc)
        if (loc ~ /\.exs?:[0-9]+$/) print loc "\t" name
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

# ── the measurement loop ----------------------------------------------------
# Tree is the INNERMOST loop so alternating trees land back-to-back inside the
# same load window at each (seed, rep) cell.
total_runs=$(( $(echo "$SEEDS" | wc -w) * REPS * ${#LABELS[@]} ))
run_no=0
log "output: $OUT_DIR"
log "plan: seeds [$SEEDS] x $REPS reps x ${#LABELS[@]} tree(s) = $total_runs runs"

cell=0
for rep in $(seq 1 "$REPS"); do
  for seed in $SEEDS; do
    # Swap tree order on alternate cells. Strict alternation in a FIXED order
    # gives whichever tree runs first a systematic advantage: measured on this
    # box, the first run in a cell consistently absorbed the residual load left
    # by the previous cell, and a 6-run fixed-order comparison of two trees that
    # were provably IDENTICAL (a comments-only diff) reported 9 failures for the
    # first-positioned tree against 1 for the second. Without this swap a later
    # stage could "prove" a conversion helped when it only measured position.
    cell=$(( cell + 1 ))
    if [ $(( cell % 2 )) -eq 0 ]; then
      ORDER=()
      for (( idx=${#LABELS[@]}-1 ; idx>=0 ; idx-- )); do ORDER+=("${LABELS[idx]}"); done
    else
      ORDER=("${LABELS[@]}")
    fi

    for label in "${ORDER[@]}"; do
      path="${TREE_PATH[$label]}"
      run_no=$(( run_no + 1 ))

      if ! check_tree_clean "$label" "$path"; then
        die "aborting measurement at run $run_no/$total_runs"
      fi

      if [ "$ONLY_TARGET" -eq 1 ]; then
        files=("$TARGET_REL")
      else
        files=()
        for f in "${FAMILY_REL[@]}"; do
          [ -f "$path/apps/platform/$f" ] && files+=("$f")
        done
      fi

      started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      head_sha="$(cd "$path" && git rev-parse --short HEAD)"
      load_before="$(loadavg_1m)"
      procs_before="$(mix_test_procs)"
      raw="$OUT_DIR/runs/${label}-seed${seed}-rep${rep}.raw"
      rec="$OUT_DIR/runs/${label}-seed${seed}-rep${rep}.txt"

      log "run $run_no/$total_runs: tree=$label seed=$seed rep=$rep load=$load_before mix_test_procs=$procs_before"

      t0=$SECONDS
      ( cd "$path/apps/platform" \
        && MIX_ENV=test PLATFORM_TEST_DATABASE="${TREE_DB[$label]}" \
           mix test "${files[@]}" --seed "$seed" ) >"$raw" 2>&1
      exit_code=$?
      wall=$(( SECONDS - t0 ))

      # ExUnit tail line, one of:
      #   "66 tests, 3 failures, 1 skipped"
      #   "16 doctests, 8216 tests, 7 failures, 3 skipped (2 excluded)"
      # Pull the test count from the "N tests" group rather than the leading
      # number — with doctests present the leading number is the DOCTEST count,
      # which silently reports a full 8,216-test suite as "16".
      tail_line="$(grep -E '^[0-9]+ (doctest|test|feature)s?,' "$raw" | tail -1)"
      total_tests="$(echo "$tail_line" | grep -oE '[0-9]+ tests?' | grep -oE '^[0-9]+' | tail -1)"
      [ -z "$total_tests" ] && total_tests=na
      failures="$(echo "$tail_line"  | grep -oE '[0-9]+ failure'  | grep -oE '^[0-9]+' || echo 0)"
      invalid="$(echo "$tail_line"   | grep -oE '[0-9]+ invalid'  | grep -oE '^[0-9]+' || echo 0)"
      skipped="$(echo "$tail_line"   | grep -oE '[0-9]+ (skipped|excluded)' | grep -oE '^[0-9]+' | head -1 || echo 0)"

      extract_failing_set "$raw" > "$raw.set"
      distinct="$(wc -l < "$raw.set" | tr -d ' ')"

      {
        printf '=== RUN %s/%s ===\n' "$run_no" "$total_runs"
        printf 'tree_label      : %s\n' "$label"
        printf 'tree_path       : %s\n' "$path"
        printf 'head_sha        : %s\n' "$head_sha"
        printf 'test_database   : %s\n' "${TREE_DB[$label]}"
        printf 'seed            : %s\n' "$seed"
        printf 'repetition      : %s\n' "$rep"
        printf 'started_utc     : %s\n' "$started_utc"
        printf 'wall_seconds    : %s\n' "$wall"
        printf 'loadavg_1m      : %s (before) / %s (after)\n' "$load_before" "$(loadavg_1m)"
        printf 'mix_test_procs  : %s (before) / %s (after)\n' "$procs_before" "$(mix_test_procs)"
        printf 'exit_code       : %s\n' "$exit_code"
        printf 'summary_line    : %s\n' "$tail_line"
        printf 'distinct_failing: %s\n' "$distinct"
        printf '\n--- concurrent mix test processes ---\n'
        ps -eo args 2>/dev/null | grep '[m]ix test' | head -20
        printf '\n--- FAILING SET (file:line<TAB>test name) ---\n'
        cat "$raw.set"
        printf '\n--- ExUnit tail ---\n'
        tail -25 "$raw"
      } > "$rec"

      while IFS=$'\t' read -r fl name; do
        [ -z "$fl" ] && continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$seed" "$rep" "$fl" "$name" >> "$SETS_TSV"
      done < "$raw.set"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$seed" "$rep" "$started_utc" "$head_sha" "$load_before" \
        "$procs_before" "$wall" "$total_tests" "$failures" "$invalid" \
        "$skipped" "$distinct" "$exit_code" >> "$SUMMARY_TSV"
    done
  done
done

# ── report ------------------------------------------------------------------
{
  printf '=== TASK ROUTER FLAKE MEASUREMENT ===\n'
  printf 'generated_utc : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'seeds         : %s\n' "$SEEDS"
  printf 'repetitions   : %s\n' "$REPS"
  printf 'scope         : %s\n' "$([ "$ONLY_TARGET" -eq 1 ] && echo 'task_router_test.exs only' || echo 'TaskRouter family (5 files)')"
  printf 'trees         : %s\n' "${LABELS[*]}"
  printf '\n--- PER-RUN SUMMARY ---\n'
  column -t -s $'\t' "$SUMMARY_TSV" 2>/dev/null || cat "$SUMMARY_TSV"

  for label in "${LABELS[@]}"; do
    printf '\n--- UNION OF FAILING TESTS: %s ---\n' "$label"
    awk -F'\t' -v l="$label" 'NR>1 && $1==l {print $4"\t"$5}' "$SETS_TSV" \
      | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn

    printf '\n--- SET STABILITY ACROSS REPETITIONS AT THE SAME SEED: %s ---\n' "$label"
    # The whole point: identical counts with differing membership is the
    # failure mode this task exists to eliminate, so report membership drift
    # explicitly rather than leaving it to be inferred from counts. Keyed on
    # test NAME (column 5), not file:line, so it stays valid across stages.
    for seed in $SEEDS; do
      n_distinct_sets=$(
        for rep in $(seq 1 "$REPS"); do
          awk -F'\t' -v l="$label" -v s="$seed" -v r="$rep" \
            'NR>1 && $1==l && $2==s && $3==r {print $5}' "$SETS_TSV" \
            | LC_ALL=C sort | paste -sd, -
        done | LC_ALL=C sort -u | wc -l
      )
      counts=$(
        for rep in $(seq 1 "$REPS"); do
          awk -F'\t' -v l="$label" -v s="$seed" -v r="$rep" \
            'NR>1 && $1==l && $2==s && $3==r {print $5}' "$SETS_TSV" | wc -l | tr -d ' '
        done | paste -sd/ -
      )
      if [ "$n_distinct_sets" -le 1 ]; then
        verdict="STABLE membership"
      else
        verdict="MEMBERSHIP DRIFT ($n_distinct_sets distinct sets at one seed)"
      fi
      printf '  seed %-5s failures/rep=%-12s %s\n' "$seed" "$counts" "$verdict"
    done
  done

  # Cross-tree set difference — only meaningful with 2+ trees, and the reason
  # the script alternates them inside one load window.
  if [ ${#LABELS[@]} -ge 2 ]; then
    a="${LABELS[0]}"; b="${LABELS[1]}"
    printf '\n--- CROSS-TREE SET DIFFERENCE (%s vs %s), keyed on test name ---\n' "$a" "$b"
    awk -F'\t' -v l="$a" 'NR>1 && $1==l {print $5}' "$SETS_TSV" | LC_ALL=C sort -u > "$OUT_DIR/.union-$a"
    awk -F'\t' -v l="$b" 'NR>1 && $1==l {print $5}' "$SETS_TSV" | LC_ALL=C sort -u > "$OUT_DIR/.union-$b"
    printf '  only in %s (%s):\n' "$a" "$(comm -23 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | wc -l)"
    comm -23 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | sed 's/^/    /'
    printf '  only in %s (%s):\n' "$b" "$(comm -13 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | wc -l)"
    comm -13 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | sed 's/^/    /'
    printf '  in both (%s):\n' "$(comm -12 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | wc -l)"
    comm -12 "$OUT_DIR/.union-$a" "$OUT_DIR/.union-$b" | sed 's/^/    /'
  fi
} | tee "$OUT_DIR/report.txt"

log "done. records: $OUT_DIR/runs/  report: $OUT_DIR/report.txt"
