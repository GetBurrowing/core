#!/bin/sh
#
# adr_corpus_probe.sh — prove the architect's ADR index resolves from a
# RELEASE's own priv/, not from a `docs/decisions/` directory that happens
# to be lying around on the build machine.
#
# WHY THIS EXISTS
#
# `ContextProviders.adr_dir/0` resolves in three steps: a configured
# `:platform, :adr_dir`, then an ancestor walk from the compile-time
# `__ENV__.file`, then an ancestor walk from the cwd. In any dev checkout
# the second step succeeds, so "the ADR index is non-empty" is TRUE on a
# machine where the production defect is fully present. Asserting on
# non-emptiness — or on the shape of the index — cannot fail for the
# reason this probe exists.
#
# The discriminator is the RESOLVED DIRECTORY. Step 4 below requires the
# resolved `dir` to sit inside the release's own `lib/platform-<vsn>/priv`.
# That path exists only if `config/runtime.exs` pointed `:adr_dir` at the
# packaged corpus. Revert that config key and this probe fails on the
# `dir` assertion while every "is it non-empty" check stays green — which
# is the whole point.
#
# WHAT THIS IS A PROXY FOR, AND WHAT IT IS NOT
#
# The release built here is a LOCAL `MIX_ENV=prod mix release`, produced
# by mirroring the Dockerfile's `COPY docs/decisions priv/adr_decisions`
# with a `cp -R`. It exercises the runtime config, the release's priv/
# snapshotting and the provider's resolution order. It does NOT exercise
# the Dockerfile itself, the repo-root build context, or `.dockerignore`
# — a `docs` entry added to `.dockerignore` would make the image's COPY
# copy nothing, silently, and this probe would still pass.
#
# Pass --docker to additionally build and run the real image, which does
# cover those three. Without it, treat a pass as the closest faithful
# proxy available and not as evidence about the shipped image.
#
# Usage:
#   scripts/adr_corpus_probe.sh [--docker] [--keep]
#
# Exits non-zero naming the first failed assertion.

set -eu

WITH_DOCKER=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --docker) WITH_DOCKER=1 ;;
    --keep) KEEP=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC_DIR="$REPO_ROOT/docs/decisions"
PRIV_DIR="$REPO_ROOT/apps/platform/priv/adr_decisions"
TMP_DIR=""
FAILURES=0

cleanup() {
  [ "$KEEP" -eq 1 ] && return 0
  # Only ever removes the seeded copy and our own mktemp dir, both by
  # absolute path. Nothing here matches on process names.
  [ -d "$PRIV_DIR" ] && rm -rf "$PRIV_DIR"
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

[ -d "$SRC_DIR" ] || { echo "FAIL: no docs/decisions in $REPO_ROOT" >&2; exit 1; }

EXPECTED_TOTAL=$(find "$SRC_DIR" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
echo "corpus: $EXPECTED_TOTAL .md files in docs/decisions/"

# ── 1. mirror the Dockerfile's COPY ──────────────────────────────────────────
rm -rf "$PRIV_DIR"
cp -R "$SRC_DIR" "$PRIV_DIR"

# ── 2. build the release ─────────────────────────────────────────────────────
echo "building MIX_ENV=prod release…"
(cd "$REPO_ROOT/apps/platform" && MIX_ENV=prod mix release --overwrite >/dev/null)

REL_BIN="$REPO_ROOT/apps/platform/_build/prod/rel/platform/bin/platform"
[ -x "$REL_BIN" ] || { echo "FAIL: no release binary at $REL_BIN" >&2; exit 1; }

# ── 3. run it from a directory with no docs/decisions ancestor ───────────────
# The ancestor walk gives up after a bounded number of parents; a mktemp dir
# has no `docs/decisions` at any depth, so if the index still resolves it
# resolved from the release, not from this checkout.
TMP_DIR=$(mktemp -d)
ANCESTOR="$TMP_DIR"
i=0
while [ "$i" -lt 8 ]; do
  if [ -d "$ANCESTOR/docs/decisions" ]; then
    fail "assertion 0 (isolated cwd): $ANCESTOR/docs/decisions exists above the probe cwd"
    break
  fi
  ANCESTOR=$(dirname "$ANCESTOR")
  i=$((i + 1))
done

EVAL_SRC='
alias Platform.Responsibilities.ContextProviders
{:ok, %{adr_index: idx}} = ContextProviders.gather_context(:adr_index, %{})
entry =
  idx
  |> Map.get(:entries, [])
  |> Enum.filter(&(&1[:superseded_by] not in [nil, []]))
  |> Enum.sort_by(& &1[:file])
  |> List.first()

IO.puts("PROBE adr_dir=" <> inspect(ContextProviders.adr_dir()))
IO.puts("PROBE available=" <> inspect(idx[:available?]))
IO.puts("PROBE reason=" <> inspect(idx[:reason]))
IO.puts("PROBE dir=" <> to_string(idx[:dir]))
IO.puts("PROBE total=" <> to_string(idx[:total]))
IO.puts("PROBE oldest_superseded=" <> inspect(entry))
'

# `bin/platform eval` runs the release's config providers, and runtime.exs
# raises on several missing production variables before it ever reaches the
# ADR block. These are throwaway values for a process that starts no
# application, opens no socket and reads no database — they exist so config
# evaluation gets far enough to run the block under test.
#
# ADR_DIR is deliberately NOT set: it overrides the packaged path, which
# would make assertion 2 pass for a reason that has nothing to do with the
# release.
probe_env() {
  env -u ADR_DIR \
    VAULT_MASTER_KEY="$(printf 'adr-corpus-probe-vault-key-000000' | base64)" \
    DATABASE_URL="ecto://probe:probe@127.0.0.1/probe" \
    SECRET_KEY_BASE="adr-corpus-probe-secret-key-base-0000000000000000000000000000000000000000000000000000000000000000" \
    ATTACHMENT_SIGNING_KEY="adr-corpus-probe-attachment-key" \
    MEETING_GUEST_SIGNING_KEY="adr-corpus-probe-guest-key" \
    MEETING_CALENDAR_SIGNING_KEY="adr-corpus-probe-calendar-key" \
    "$@"
}

echo "running the release from $TMP_DIR (no docs/decisions ancestor)…"
OUT=$(cd "$TMP_DIR" && probe_env "$REL_BIN" eval "$EVAL_SRC")
echo "$OUT"

probe_field() {
  printf '%s\n' "$OUT" | sed -n "s/^PROBE $1=//p" | head -1
}

AVAILABLE=$(probe_field available)
REASON=$(probe_field reason)
DIR=$(probe_field dir)
TOTAL=$(probe_field total)
SUPERSEDED=$(probe_field oldest_superseded)

# ── 4. the assertions ────────────────────────────────────────────────────────
[ "$AVAILABLE" = "true" ] ||
  fail "assertion 1 (available?): expected true, got '$AVAILABLE' (reason=$REASON)"

# THE DISCRIMINATOR. Both halves are required: `/lib/platform-` proves the
# path is inside the release's own lib tree, the suffix proves it is the
# packaged corpus. Without the runtime.exs key this comes back as the
# checkout's docs/decisions and fails here while everything else passes.
case "$DIR" in
  */lib/platform-*) ;;
  *) fail "assertion 2a (dir inside the release): '$DIR' does not contain /lib/platform-" ;;
esac
case "$DIR" in
  */priv/adr_decisions) ;;
  *) fail "assertion 2b (dir is the packaged corpus): '$DIR' does not end in priv/adr_decisions" ;;
esac

[ "$TOTAL" = "$EXPECTED_TOTAL" ] ||
  fail "assertion 3 (total): expected $EXPECTED_TOTAL, got '$TOTAL'"

# Non-emptiness is necessary and not sufficient; the corpus must still carry
# its supersession edges through the release's parse.
case "$SUPERSEDED" in
  nil|"") fail "assertion 4 (supersession): no superseded ADR in the packaged corpus" ;;
esac

# ── 5. optional: the real image ──────────────────────────────────────────────
if [ "$WITH_DOCKER" -eq 1 ]; then
  echo "building the container image from the repo root…"
  (cd "$REPO_ROOT" && docker build -f apps/platform/Dockerfile -t adr-probe:local . >/dev/null)
  COUT=$(docker run --rm adr-probe:local /app/bin/platform eval "$EVAL_SRC")
  echo "$COUT"

  CDIR=$(printf '%s\n' "$COUT" | sed -n 's/^PROBE dir=//p' | head -1)
  CAVAIL=$(printf '%s\n' "$COUT" | sed -n 's/^PROBE available=//p' | head -1)
  CTOTAL=$(printf '%s\n' "$COUT" | sed -n 's/^PROBE total=//p' | head -1)

  [ "$CAVAIL" = "true" ] || fail "container assertion 1 (available?): got '$CAVAIL'"
  case "$CDIR" in
    */lib/platform-*) ;;
    *) fail "container assertion 2a: '$CDIR' does not contain /lib/platform-" ;;
  esac
  case "$CDIR" in
    */priv/adr_decisions) ;;
    *) fail "container assertion 2b: '$CDIR' does not end in priv/adr_decisions" ;;
  esac
  [ "$CTOTAL" = "$EXPECTED_TOTAL" ] ||
    fail "container assertion 3 (total): expected $EXPECTED_TOTAL, got '$CTOTAL'"
else
  echo
  echo "NOTE: ran the release-tarball proxy only. The Dockerfile COPY, the"
  echo "      repo-root build context and .dockerignore were NOT exercised."
  echo "      Re-run with --docker for evidence about the shipped image."
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES assertion(s) failed" >&2
  exit 1
fi

echo "OK: the ADR corpus resolved from the release at $DIR ($TOTAL ADRs)"
