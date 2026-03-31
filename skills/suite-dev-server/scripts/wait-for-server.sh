#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-}"

if [ -z "$PORT" ]; then
  echo "Usage: $0 <port>" >&2
  exit 1
fi

URL="http://localhost:$PORT/dev/login"
ATTEMPTS=30

for _ in $(seq 1 "$ATTEMPTS"); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)"
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo >&2
    exit 0
  fi

  printf '.' >&2
  sleep 2
done

echo >&2
echo "Timed out waiting for $URL (see /tmp/suite-dev-$PORT.log)" >&2
exit 1
