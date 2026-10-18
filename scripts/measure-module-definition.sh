#!/usr/bin/env bash
# Measure cold `mix compile` wall time of apps/platform per Elixir
# `module_definition` variant (task 01a0fd73). TEST-RIG HOST ONLY:
# it refuses to run unless `hostname -s` equals RIG_HOST.
#
#   scripts/measure-module-definition.sh <mirror-ref> [variants...]
#
#   scripts/measure-module-definition.sh task/01a0fd73-f6b1-7001-8749-ba0fc4d4ef84
#   RUNS=1 scripts/measure-module-definition.sh main compiled interpreted
#   RUNS=1 scripts/measure-module-definition.sh <ref> bogus     # positive control: every row exit != 0
#
# Variants default to `compiled interpreted`. Each name is passed straight
# through as both BURROW_MODULE_DEFINITION and SUITE_MODULE_DEFINITION
# (apps/platform/mix.exs module_definition_opts/0 reads BURROW_ first; a ref
# older than task 01a14b9e reads only SUITE_, so both are always set and
# carry the same value), so a new variant is an argument, not a code
# change. An unknown name is NOT a fast win: the hook's Mix.raise makes that
# row's exit_code non-zero and it is excluded from the medians.
#
# METHOD
#   * The ref is cloned once from the test rig's mirror; `mix deps.get` runs ONCE.
#     The hex/mix cache is copied once from $RIG_DIR/cache and reused by every
#     run, and no deps.get runs between timed runs, so deps are constant.
#   * Every run is a fresh container that removes apps/platform/_build, rebuilds
#     deps UNTIMED-but-recorded (`MIX_ENV=test mix deps.compile`; the option
#     does not apply to deps, so timing them would dilute the ratio with a
#     constant), then times `BURROW_MODULE_DEFINITION=<v> SUITE_MODULE_DEFINITION=<v>
#     MIX_ENV=test mix compile`
#     with `date +%s%N` (the slim image has no /usr/bin/time).
#   * Rounds are INTERLEAVED: odd rounds run the variants in the given order,
#     even rounds in reverse (c,i / i,c / c,i), so drift in the rig's shared load
#     does not land on one variant.
#   * CPU pinning uses `taskset -c $CPUS`, inherited by podman/crun, exactly as
#     core-test.sh does. `podman run --cpuset-cpus` does NOT work here: the
#     cpuset controller is not delegated to the rootless user manager, and crun
#     fails with exit 126 ("controller `cpuset` is not available").
#   * Every run is recorded, including failures. The beam count column is the
#     guard against a variant that "won" by compiling less: it must be equal
#     across variants.
#
# Environment (RIG_HOST, RIG_DIR and MIRROR are REQUIRED, with no default):
#   RIG_HOST    short host name of the test rig; the script runs only there
#   RUNS        rounds per variant (default 3)
#   CPUS        CPU list (default 0-5,8-13, core-test.sh's CORE_TEST_CPUS default)
#   IMAGE       default localhost/core-test:1.20.4-otp-28-slim-cc
#   RIG_DIR     rig work dir (clone, cache, TSV, log)
#   MIRROR      bare mirror of core on the rig
#   CTR_PREFIX  default core-test-task_01a0fd73-f6b1-7001-8749-ba0fc4d4ef84-measure
#   WARM_CHECK=1  after the last run, compile the OTHER variant on the warm
#               _build and report whether Mix recompiled anything.
#   KEEP=1      keep the clone afterwards
#
# Output: $RIG_DIR/measure-01a0fd73-<sha8>-$$.tsv (one row per run) and
# $RIG_DIR/measure-01a0fd73-<sha8>-$$.log (every container's output).
# Exit: 0 measurement completed (failed runs are DATA) | 2 precondition error.
set -uo pipefail

usage() { sed -n '2,55p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
REF="$1"; shift
VARIANTS=("$@")
[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=(compiled interpreted)

RUNS="${RUNS:-3}"
CPUS="${CPUS:-0-5,8-13}"
IMAGE="${IMAGE:-localhost/core-test:1.20.4-otp-28-slim-cc}"
CTR_PREFIX="${CTR_PREFIX:-core-test-task_01a0fd73-f6b1-7001-8749-ba0fc4d4ef84-measure}"

log() { echo "$(date -u '+%FT%TZ') [measure-module-definition $$] $*"; }
die() { log "ERROR: $*" >&2; exit 2; }

for v in RIG_HOST RIG_DIR MIRROR; do
    [ -n "${!v:-}" ] || die "$v is required (no default); see the header"
done
if [ "$(hostname -s)" != "$RIG_HOST" ]; then
    echo "measure-module-definition.sh runs BEAM and must only run on the test rig $RIG_HOST (found host $(hostname -s))" >&2
    exit 2
fi
case "$RUNS" in ''|*[!0-9]*|0) die "RUNS must be a positive integer, got '$RUNS'" ;; esac
podman image exists "$IMAGE" || die "image $IMAGE not present (core-test.sh builds it on first use)"
[ -d "$RIG_DIR/cache/mix" ] && [ -d "$RIG_DIR/cache/hex" ] || die "no warm cache at $RIG_DIR/cache/{mix,hex}"
SHA=$(git -C "$MIRROR" rev-parse --verify -q "refs/heads/$REF") || die "ref '$REF' not on mirror $MIRROR"
SHA8="${SHA:0:8}"

CLONE="$RIG_DIR/measure-$SHA8-$$"
HOMEDIR="$RIG_DIR/measure-home-$SHA8-$$"
TSV="${TSV:-$RIG_DIR/measure-01a0fd73-$SHA8-$$.tsv}"
LOG="$RIG_DIR/measure-01a0fd73-$SHA8-$$.log"
CURRENT_CTR=""

# Only ever removes the container THIS invocation started.
cleanup() {
    [ -n "$CURRENT_CTR" ] && podman rm -f "$CURRENT_CTR" >/dev/null 2>&1
    rm -rf "$HOMEDIR"
    [ "${KEEP:-0}" = "1" ] || rm -rf "$CLONE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

log "ref $REF @ $SHA  variants ${VARIANTS[*]}  runs $RUNS  cpus $CPUS  image $IMAGE"
log "tsv $TSV"
log "log $LOG"

git clone -q --no-checkout "$MIRROR" "$CLONE" || die "clone failed"
git -C "$CLONE" checkout -q --detach "$SHA" || die "checkout failed"
mkdir -p "$HOMEDIR"
cp -a "$RIG_DIR/cache/mix" "$HOMEDIR/mix" && cp -a "$RIG_DIR/cache/hex" "$HOMEDIR/hex" || die "cache copy failed"

# ctr <name> <script> : one fresh container on the clone, output appended to $LOG.
ctr() {
    CURRENT_CTR="$1"
    taskset -c "$CPUS" podman run --rm --name "$1" --cgroup-parent=background.slice \
        -v "$CLONE:/app:z" -v "$HOMEDIR/mix:/root/.mix:z" -v "$HOMEDIR/hex:/root/.hex:z" \
        -e MIX_HOME=/root/.mix -e HEX_HOME=/root/.hex -e LANG=C.UTF-8 -e MIX_ENV=test \
        -w /app/apps/platform "$IMAGE" bash -c "$2" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    CURRENT_CTR=""
    return "$rc"
}

log "deps.get (once)" | tee -a "$LOG"
ctr "$CTR_PREFIX-depsget-$$" '
    mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get' \
    >/dev/null || die "deps.get failed (see $LOG)"

printf 'utc_start\tvariant\tround\tsha\timage\telixir_version\tdeps_compile_s\tcompile_s\texit_code\tload1_before\tcore_test_running\tbeam_count\n' > "$TSV"

# Seconds with every nanosecond kept: never rounded.
ns_to_s() { local n="$1"; printf '%d.%09d' "$((n / 1000000000))" "$((n % 1000000000))"; }

for ((round = 1; round <= RUNS; round++)); do
    order=("${VARIANTS[@]}")
    if ((round % 2 == 0)); then
        order=()
        for ((k = ${#VARIANTS[@]} - 1; k >= 0; k--)); do order+=("${VARIANTS[k]}"); done
    fi
    for v in "${order[@]}"; do
        utc=$(date -u +%FT%TZ)
        load1=$(cut -d' ' -f1 /proc/loadavg)
        nctr=$(podman ps --format '{{.Names}}' | grep -c '^core-test-' || true)
        log "round $round variant $v  load1 $load1  core-test running $nctr" | tee -a "$LOG"
        # Set in THIS shell: ctr runs inside $(...), whose assignments the trap cannot see.
        CURRENT_CTR="$CTR_PREFIX-$v-$round-$$"
        out=$(ctr "$CURRENT_CTR" "v=$(printf '%q' "$v")"'
            echo "@@VERSION $(elixir --version | tail -1)"
            rm -rf _build
            t0=$(date +%s%N); mix deps.compile >/dev/null 2>&1; drc=$?; t1=$(date +%s%N)
            echo "@@DEPS $((t1 - t0)) $drc"
            t0=$(date +%s%N); BURROW_MODULE_DEFINITION="$v" SUITE_MODULE_DEFINITION="$v" mix compile; rc=$?; t1=$(date +%s%N)
            n=$(find _build/test/lib/platform/ebin -name "*.beam" 2>/dev/null | wc -l)
            echo "@@COMPILE $((t1 - t0)) $rc $n"
        ' 2>&1)
        CURRENT_CTR=""
        ver=$(printf '%s\n' "$out" | sed -n 's/^@@VERSION //p' | tail -1)
        read -r dns drc <<<"$(printf '%s\n' "$out" | sed -n 's/^@@DEPS //p' | tail -1)"
        read -r cns crc beams <<<"$(printf '%s\n' "$out" | sed -n 's/^@@COMPILE //p' | tail -1)"
        if [ -z "${cns:-}" ]; then cns=0; crc=255; beams=0; fi
        [ "${drc:-1}" = "0" ] || log "WARNING: deps.compile exit ${drc:-?} in round $round $v" | tee -a "$LOG"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$utc" "$v" "$round" "$SHA" "$IMAGE" "$ver" "$(ns_to_s "${dns:-0}")" "$(ns_to_s "$cns")" \
            "$crc" "$load1" "$nctr" "$beams" >> "$TSV"
        tail -1 "$TSV"
        last_variant="$v"
    done
done

echo
echo "== raw rows ($TSV)"
cat "$TSV"
echo
echo "== medians over exit_code==0 rows; ratio = variant / ${VARIANTS[0]}"
awk -F'\t' -v first="${VARIANTS[0]}" '
    NR == 1 { next }
    { beams[$2 "," $12] = 1 }
    $9 == 0 { n[$2]++; v[$2, n[$2]] = $8 + 0 }
    END {
        for (name in n) {
            m = n[name]
            for (i = 1; i <= m; i++) a[i] = v[name, i]
            for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
            med[name] = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
            printf "median %-12s %.9f s  (n=%d valid)\n", name, med[name], m
        }
        for (name in med) if (name != first && (first in med))
            printf "ratio  %s/%s = %.6f  (adoption bar 0.85)\n", name, first, med[name] / med[first]
        for (k in beams) { split(k, p, ","); nb[p[1]] = (p[1] in nb) ? nb[p[1]] " " p[2] : p[2] }
        for (name in nb) printf "beam counts %-12s %s\n", name, nb[name]
    }' "$TSV"

if [ "${WARM_CHECK:-0}" = "1" ] && [ -n "${last_variant:-}" ]; then
    other=""
    for v in "${VARIANTS[@]}"; do [ "$v" != "$last_variant" ] && other="$v" && break; done
    if [ -n "$other" ]; then
        echo
        log "WARM_CHECK: _build is warm from '$last_variant'; compiling '$other' with no rm" | tee -a "$LOG"
        ctr "$CTR_PREFIX-warm-$$" '
            t0=$(date +%s%N); BURROW_MODULE_DEFINITION='"$other"' SUITE_MODULE_DEFINITION='"$other"' mix compile 2>&1 | grep -E "^Compiling|^Generated|error" ; rc=${PIPESTATUS[0]}; t1=$(date +%s%N)
            echo "@@WARM other='"$other"' exit $rc ns $((t1 - t0)) (no Compiling line above = NOT recompiled)"
        '
    fi
fi
log "done"
