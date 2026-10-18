#!/bin/bash
# Run the agent host's tests on test-host: typecheck and unit tests in a plain bun
# container, then the isolation test inside a throwaway systemd container.
# Usage (on test-host): run.sh <checkout of services/agent-host>
# Every container and image name carries the task id; all are removed on exit.
set -euo pipefail
SRC="$(cd "$1" && pwd)"
ID=01a10322-e24f-7001-8356-98259d347cbe
IMG="localhost/agent-host-isolation-$ID:latest"
CTR="agent-host-isolation-$ID"
cleanup() { podman rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

podman build -q -t "$IMG" "$SRC/test/isolation" >/dev/null
podman run -d --name "$CTR" --systemd=always --tmpfs /run --tmpfs /tmp \
  -v "$SRC:/app:z,ro" "$IMG" >/dev/null
for _ in $(seq 1 60); do
  state="$(podman exec "$CTR" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break ;; esac
  sleep 1
done
echo "systemd: $state"
podman exec "$CTR" sh -c 'cp -r /app /src && cd /src && rm -rf node_modules && bun install --frozen-lockfile >/dev/null && bunx tsc --noEmit && echo TSC_OK && AGENT_HOST_ISOLATION=1 bun test 2>&1'
