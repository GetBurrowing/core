#!/usr/bin/env bash
# Run lighthouse a11y audit against the three routes touched by task 019e0d4a.
# Authenticates via /dev/login first and forwards the resulting session cookie
# so lighthouse's spawned Chrome lands on the real LV pages instead of the
# login redirect.
#
# Usage:
#   PORT=4003 ./scripts/run-lighthouse-a11y.sh
#   AUDIT_DIR=/path/to/audit PORT=4003 ./scripts/run-lighthouse-a11y.sh
#
# Exits non-zero on the first route that scores < 90 on the a11y category.

set -euo pipefail

PORT="${PORT:-4000}"
SLUG="${SLUG:-alice}"
AUDIT_DIR="${AUDIT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/audit/2026-05-08-ui-ux}"
BASE="http://localhost:${PORT}"

mkdir -p "$AUDIT_DIR"

# Pull the session cookie. /dev/login?as=<slug> sets _platform_session and 302s
# to /chat — we only care about the Set-Cookie header.
COOKIE_HEADER=$(curl -sSI "${BASE}/dev/login?as=${SLUG}" \
  | awk -F': ' 'tolower($1)=="set-cookie" { sub(/;.*/,"",$2); print $2; exit }')

if [[ -z "$COOKIE_HEADER" ]]; then
  echo "ERROR: failed to obtain _platform_session cookie from ${BASE}/dev/login?as=${SLUG}" >&2
  exit 1
fi

EXTRA_HEADERS=$(printf '{"Cookie":"%s"}' "$COOKIE_HEADER")

declare -a ROUTES=("chat:/chat/general" "tasks:/tasks" "activity:/activity")
declare -a FAILED=()

for entry in "${ROUTES[@]}"; do
  label="${entry%%:*}"
  path="${entry#*:}"
  out="${AUDIT_DIR}/post-fix-lighthouse-${label}.json"
  echo "==> lighthouse ${BASE}${path} -> ${out}"
  npx --no-install lighthouse "${BASE}${path}" \
    --quiet \
    --only-categories=accessibility \
    --output=json \
    --output-path="$out" \
    --chrome-flags="--headless=new --no-sandbox --disable-dev-shm-usage" \
    --extra-headers="$EXTRA_HEADERS"

  score=$(node -e "process.stdout.write(String(Math.round(JSON.parse(require('fs').readFileSync('${out}','utf8')).categories.accessibility.score * 100)))")
  echo "    a11y score: ${score}"
  if [[ "$score" -lt 90 ]]; then
    FAILED+=("${label}=${score}")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAIL: routes scored < 90 on a11y: ${FAILED[*]}" >&2
  exit 2
fi

echo "OK: all routes ≥ 90 on lighthouse a11y."
