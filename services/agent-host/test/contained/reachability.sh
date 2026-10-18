#!/bin/bash
# The `contained` profile's network reach, measured on podman (core task
# 01a10322 stage 3). Run on test-host, never on build-host:
#
#   reachability.sh <agent-host image> [strict|true|none]
#
# Builds a throwaway copy of test-host's topology, every name carrying the task id:
#   suite net   : a Postgres standing in for core-postgres, and core-platform
#   agents net  : core-platform (on BOTH nets) and the agent-host image
# core-platform is a stand-in HTTP server on :4000 (the reach is a property of
# the networks, not of core). The agents network is created with
# isolate=strict, as core-ops' agents.network does. `true` and `none` measure
# the same topology with the weaker settings: both let the agent host reach
# Postgres BY IP (measured 2026-10-09, podman 5.6.2 rootless on test-host), so each
# is the mutation under which the by-IP probes must go red. isolate=true only
# blocks traffic between networks that BOTH set it; strict blocks it to every
# other network.
#
# Prints one line per probe and exits non-zero if any expectation fails.
# Every container and network is removed on exit, and the filters are shown
# matching before teardown and empty after.
set -uo pipefail
IMG="${1:?usage: reachability.sh <agent-host image> [strict|true|none]}"
MODE="${2:-strict}"
ID=01a10322-s3
BURROW_NET="suite-$ID"
AGENTS_NET="agents-$ID"
PG="pg-$ID"
CORE="core-$ID"
AH="ah-$ID"
fail=0

inventory() {
  echo "--- $1: podman ps -a --filter name=$ID"
  podman ps -a --filter "name=$ID" --format '{{.Names}}'
  echo "--- $1: podman network ls --filter name=$ID"
  podman network ls --filter "name=$ID" --format '{{.Name}}'
}
cleanup() {
  inventory "before teardown"
  podman rm -f -t 0 "$AH" "$CORE" "$PG" >/dev/null 2>&1 || true
  podman network rm "$BURROW_NET" "$AGENTS_NET" >/dev/null 2>&1 || true
  inventory "after teardown"
}
trap cleanup EXIT

expect() { # expect <name> <want: ok|refused> <rc>
  local got=refused
  [ "$3" -eq 0 ] && got=ok
  if [ "$got" = "$2" ]; then echo "PASS $1: $got"; else echo "FAIL $1: got $got, want $2"; fail=1; fi
}

podman network create "$BURROW_NET" >/dev/null
case "$MODE" in
strict | true) podman network create --opt "isolate=$MODE" "$AGENTS_NET" >/dev/null ;;
none) podman network create "$AGENTS_NET" >/dev/null ;;
*) echo "unknown mode $MODE" >&2; exit 2 ;;
esac

# The password is generated here and never printed.
PGPW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
podman run -d --name "$PG" --network "$BURROW_NET:alias=core-postgres" \
  -e POSTGRES_PASSWORD="$PGPW" docker.io/library/postgres:16-alpine >/dev/null
podman run -d --name "$CORE" \
  --network "$BURROW_NET:alias=core-platform" --network "$AGENTS_NET:alias=core-platform" \
  docker.io/library/python:3.12-slim python3 -m http.server 4000 >/dev/null
TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
podman run -d --name "$AH" --systemd=always --network "$AGENTS_NET" \
  -e AGENT_HOST_TOKEN="$TOKEN" -e BURROW_CORE_URL=http://core-platform:4000 -e SUITE_CORE_URL=http://core-platform:4000 "$IMG" >/dev/null

for _ in $(seq 1 60); do
  state="$(podman exec "$AH" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break ;; esac
  sleep 1
done
echo "agent-host systemd: $state"
for _ in $(seq 1 30); do
  podman exec "$PG" pg_isready -q -h 127.0.0.1 && break
  sleep 1
done

PG_IP="$(podman inspect "$PG" --format "{{(index .NetworkSettings.Networks \"$BURROW_NET\").IPAddress}}")"
CORE_SUITE_IP="$(podman inspect "$CORE" --format "{{(index .NetworkSettings.Networks \"$BURROW_NET\").IPAddress}}")"
echo "core-postgres stand-in at $PG_IP on $BURROW_NET; agents network isolate: $MODE"

tcp_from_core() { podman exec "$CORE" python3 -c "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3)" "$1" "$2" >/dev/null 2>&1; }
tcp_from_ah() { podman exec "$AH" timeout 4 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }

# Positive control: core-platform's own reach to Postgres works.
tcp_from_core core-postgres 5432; expect "core-platform -> core-postgres:5432 (positive control)" ok $?
# The agent host reaches core-platform...
code="$(podman exec "$AH" curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://core-platform:4000/ 2>/dev/null)"
[ "$code" = "200" ]; expect "agent-host -> core-platform:4000 (HTTP $code)" ok $?
# ...and the internet...
podman exec "$AH" curl -s -o /dev/null --max-time 10 https://deb.debian.org/ >/dev/null 2>&1; expect "agent-host -> internet (https://deb.debian.org)" ok $?
# ...and not Postgres, by name or by address.
podman exec "$AH" getent hosts core-postgres >/dev/null 2>&1; expect "agent-host resolves core-postgres" refused $?
tcp_from_ah "$PG_IP" 5432; expect "agent-host -> core-postgres by IP $PG_IP:5432" refused $?
tcp_from_ah "$CORE_SUITE_IP" 4000; expect "agent-host -> core-platform's suite-net IP $CORE_SUITE_IP:4000" refused $?

# The daemon got its env through systemd (PassEnvironment), names only.
pid="$(podman exec "$AH" systemctl show -p MainPID --value suite-agent-host.service)"
names="$(podman exec "$AH" sh -c "tr '\\0' '\\n' < /proc/$pid/environ | cut -d= -f1 | grep -E '^(AGENT_HOST_TOKEN|AGENT_HOST_PROFILE|BURROW_CORE_URL|SUITE_CORE_URL)\$' | sort | tr '\\n' ' '")"
echo "agent-host daemon env names: $names"
[ "$names" = "AGENT_HOST_PROFILE AGENT_HOST_TOKEN BURROW_CORE_URL SUITE_CORE_URL " ]; expect "daemon received its four env names" ok $?
podman exec "$AH" journalctl -u suite-agent-host --no-pager -o cat | grep -m1 'dialling' || true
podman exec "$AH" journalctl -u suite-agent-host --no-pager -o cat | grep -q 'as profile contained'; expect "daemon reports profile contained" ok $?

echo "result: $([ $fail -eq 0 ] && echo ALL_EXPECTED || echo UNEXPECTED)"
exit $fail
