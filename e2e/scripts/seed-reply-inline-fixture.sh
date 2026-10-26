#!/usr/bin/env bash
# Seed the reply-inline e2e fixture (task 01a174f5 stage 3) into the REVIEW
# server's database. Run AFTER visiting /dev/login on that server once (the
# dev user must exist). See seed-reply-inline-fixture.exs for what it creates.
#
# Usage:
#   PLATFORM_DEV_DATABASE=<the review server's db> \
#     e2e/scripts/seed-reply-inline-fixture.sh [--reset] [<credentials-file>]
#
# --reset soft-deletes the channel's messages first (a clean log for another
# review pass; the thread case leaves a real thread on 'A: status one').
#
# The credentials file defaults to $TMPDIR/reply-inline-e2e-runtimes.json. It
# holds runtime tokens: it is written 0600, never tracked, never printed.
# Then (re)start: node e2e/scripts/echo-runtime.mjs --url http://localhost:<port>
# Every seed run rotates the runtime tokens, so restart the echo runtime after it.
set -euo pipefail

if [ -z "${PLATFORM_DEV_DATABASE:-}" ]; then
  echo "seed-reply-inline-fixture: set PLATFORM_DEV_DATABASE to the review server's database" >&2
  exit 2
fi
case "$PLATFORM_DEV_DATABASE" in
  platform_dev|*prod*)
    echo "seed-reply-inline-fixture: refusing database '$PLATFORM_DEV_DATABASE'; use a per-review dev database" >&2
    exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
platform="$(cd "$here/../../apps/platform" && pwd)"
reset=()
if [ "${1:-}" = "--reset" ]; then reset=(--reset); shift; fi
out="${1:-${TMPDIR:-/tmp}/reply-inline-e2e-runtimes.json}"

cd "$platform"
MIX_ENV=dev mix run "$here/seed-reply-inline-fixture.exs" ${reset[@]+"${reset[@]}"} "$out"
