#!/usr/bin/env bash
# switcher_rig/rig.sh — the web install switcher's local dev rig (task
# 01a1ccd4 stage 4). Three real installs and two real OIDC providers on one
# machine, so carry-over sign-in and the cross-install unread can be walked
# in a real browser with real OIDC (never /dev/login).
#
#   rig.sh up            start everything (idempotent) and print the URLs
#   rig.sh down          stop the installs and the IdPs, drop the rig DBs
#   rig.sh status        what is running
#   rig.sh login-link <idp1|idp2>
#                        mint a one-time sign-in link for the rig user on that
#                        IdP (a credential: written to $STATE/login-<idp>.url,
#                        0600, never printed)
#   rig.sh rpc <a|b|c> <file.exs> [args...]
#                        evaluate scripts/switcher_rig/<file.exs> on that
#                        install's running node (seeding, e.g. seed_unread.exs)
#   rig.sh hostile       start the hostile install D (hostile_install.py)
#
# Layout (hostnames only; *.localhost resolves to loopback in Chrome and in
# the BEAM, so nothing needs /etc/hosts):
#
#   IdP-1   http://idp1.localhost:9411   Pocket ID (docker), clients switch-a, switch-b
#   IdP-2   http://idp2.localhost:9412   Pocket ID (docker), client switch-c
#   A       http://a.localhost:4201      DB platform_dev_switch_a, IdP-1
#   B       http://b.localhost:4202      DB platform_dev_switch_b, IdP-1
#   C       http://c.localhost:4203      DB platform_dev_switch_c, IdP-2
#   D       http://d.localhost:4204-4207 hostile_install.py (HTML, 5 MB body,
#                                        extra fields, 30 s delay)
#
# Each install is a `mix phx.server` (MIX_ENV=dev) of THIS checkout on its own
# port, its own database and its own OIDC client. Session cookies are
# host-only (`_platform_session`, no SESSION_COOKIE_DOMAIN), so a, b and c
# keep separate sessions even though cookies ignore ports.
#
# Secrets (Pocket ID STATIC_API_KEY / ENCRYPTION_KEY, the OIDC client
# secrets) are generated on the first `up`, kept in $STATE/secrets.env (0600)
# and never printed. Nothing here talks to a real host.
#
# Needs: docker, a Postgres reachable as postgres/postgres on localhost:5432
# (PG_CONTAINER, default suite-dev-postgres, is used with `docker exec` for
# psql), elixir/mix, python3, curl, openssl.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/../.." && pwd)"
STATE="${RIG_STATE:-${TMPDIR:-/tmp}/burrow-switcher-rig}"
PG_CONTAINER="${PG_CONTAINER:-suite-dev-postgres}"
POCKET_ID_IMAGE="${POCKET_ID_IMAGE:-ghcr.io/pocket-id/pocket-id:v2.18.0}"
RIG_EMAIL="${RIG_EMAIL:-rig.user@example.com}"
RIG_USERNAME="${RIG_USERNAME:-riguser}"

mkdir -p "$STATE"; chmod 700 "$STATE"

say() { echo "[switcher-rig] $*" >&2; }
fail() { say "FAIL: $*"; exit 1; }

idp_port() { case "$1" in idp1) echo 9411 ;; idp2) echo 9412 ;; *) fail "unknown idp $1" ;; esac; }
idp_url() { echo "http://$1.localhost:$(idp_port "$1")"; }
idp_container() { echo "switcher-rig-$1"; }
install_port() { case "$1" in a) echo 4201 ;; b) echo 4202 ;; c) echo 4203 ;; *) fail "unknown install $1" ;; esac; }
install_idp() { case "$1" in a|b) echo idp1 ;; c) echo idp2 ;; esac; }
install_url() { echo "http://$1.localhost:$(install_port "$1")"; }
install_db() { echo "platform_dev_switch_$1"; }
install_name() { case "$1" in a) echo "Install A" ;; b) echo "Install B" ;; c) echo "Install C" ;; esac; }

secret() {
  # secret NAME: read NAME from secrets.env, generating it on first use.
  local name="$1" f="$STATE/secrets.env" v
  touch "$f"; chmod 600 "$f"
  v=$(grep "^$name=" "$f" | cut -d= -f2- || true)
  if [ -z "$v" ]; then
    v=$(openssl rand -hex 24)
    echo "$name=$v" >> "$f"
  fi
  printf '%s' "$v"
}

psql_rig() { docker exec -e PGPASSWORD=postgres "$PG_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qtA "$@"; }

# --- IdPs ---------------------------------------------------------------

idp_api() {
  # idp_api <idp> <method> <path> [json body]
  local idp="$1" method="$2" path="$3" body="${4:-}" key
  key=$(secret "STATIC_API_KEY_$idp")
  if [ -n "$body" ]; then
    curl -sS -X "$method" -H "X-API-Key: $key" -H 'Content-Type: application/json' \
      --data "$body" "$(idp_url "$idp")$path"
  else
    curl -sS -X "$method" -H "X-API-Key: $key" "$(idp_url "$idp")$path"
  fi
}

json_get() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]) if d else "")' "$1"; }

start_idp() {
  local idp="$1" c port
  c=$(idp_container "$idp"); port=$(idp_port "$idp")
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" != true ]; then
    docker rm -f "$c" >/dev/null 2>&1 || true
    say "starting $c on $(idp_url "$idp")"
    # LOG_LEVEL=error: Pocket ID logs request paths, and one-time sign-in
    # codes travel in them.
    docker run -d --name "$c" -p "127.0.0.1:$port:1411" \
      -e APP_URL="$(idp_url "$idp")" \
      -e ENCRYPTION_KEY="$(secret "ENCRYPTION_KEY_$idp")" \
      -e STATIC_API_KEY="$(secret "STATIC_API_KEY_$idp")" \
      -e ANALYTICS_DISABLED=true -e LOG_LEVEL=error \
      "$POCKET_ID_IMAGE" >/dev/null
  fi
  local i code
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$(idp_url "$idp")/.well-known/openid-configuration" || true)
    [ "$code" = 200 ] && break
    sleep 1
  done
  [ "$code" = 200 ] || fail "$c did not answer discovery"

  # The rig user (same email on both IdPs: a person with two accounts).
  local uid
  uid=$(idp_api "$idp" GET "/api/users?search=$RIG_USERNAME" | json_get '["data"][0]["id"]' 2>/dev/null || true)
  if [ -z "$uid" ]; then
    idp_api "$idp" POST /api/users "{\"username\":\"$RIG_USERNAME\",\"email\":\"$RIG_EMAIL\",\"emailVerified\":true,\"firstName\":\"Rig\",\"lastName\":\"User\",\"displayName\":\"Rig User\",\"isAdmin\":false}" >/dev/null
    say "$idp: created user $RIG_USERNAME"
  fi
}

ensure_client() {
  # ensure_client <install>: the install's own OIDC client on its own IdP.
  local x="$1" idp id status created sid
  idp=$(install_idp "$x"); id="switch-$x"
  status=$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $(secret "STATIC_API_KEY_$idp")" "$(idp_url "$idp")/api/oidc/clients/$id")
  if [ "$status" = 404 ]; then
    created=$(idp_api "$idp" POST /api/oidc/clients "{\"id\":\"$id\",\"name\":\"$(install_name "$x")\",\"callbackURLs\":[\"$(install_url "$x")/auth/oidc/callback\"],\"logoutCallbackURLs\":[\"$(install_url "$x")\"],\"isPublic\":false,\"pkceEnabled\":true}")
    # Pocket ID generates a secret on create; replace it with ours.
    sid=$(printf '%s' "$created" | json_get '.get("createdSecret",{}).get("id","")' || true)
    [ -n "$sid" ] && idp_api "$idp" DELETE "/api/oidc/clients/$id/secrets/$sid" >/dev/null || true
    idp_api "$idp" POST "/api/oidc/clients/$id/secrets" "{\"secret\":\"$(secret "OIDC_SECRET_$x")\"}" >/dev/null
    say "$idp: created client $id"
  fi
}

login_link() {
  local idp="$1" uid token out
  uid=$(idp_api "$idp" GET "/api/users?search=$RIG_USERNAME" | json_get '["data"][0]["id"]')
  token=$(idp_api "$idp" POST "/api/users/$uid/one-time-access-token" '{"ttl":"30m"}' | json_get '["token"]')
  [ -n "$token" ] || fail "no one-time token from $idp"
  out="$STATE/login-$idp.url"
  (umask 077; printf '%s/lc/%s\n' "$(idp_url "$idp")" "$token" > "$out")
  say "one-time sign-in link for $idp written to $out"
}

# --- installs -----------------------------------------------------------

pidfile() { echo "$STATE/install-$1.pid"; }

start_install() {
  local x="$1" port db idp log
  port=$(install_port "$x"); db=$(install_db "$x"); idp=$(install_idp "$x")
  log="$STATE/install-$x.log"
  if [ -f "$(pidfile "$x")" ] && kill -0 "$(cat "$(pidfile "$x")")" 2>/dev/null; then
    say "install $x already running ($(install_url "$x"))"; return 0
  fi
  psql_rig -c "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 \
    || psql_rig -c "CREATE DATABASE $db" >/dev/null
  (
    cd "$PLATFORM"
    export MIX_ENV=dev PORT="$port" PHX_BIND_IP=127.0.0.1 \
      PLATFORM_DEV_DATABASE="$db" APP_URL="$(install_url "$x")" \
      OIDC_ISSUER="$(idp_url "$idp")" OIDC_CLIENT_ID="switch-$x" \
      OIDC_CLIENT_SECRET="$(secret "OIDC_SECRET_$x")" OIDC_PKCE_ENABLED=true
    mix ecto.migrate >"$log.migrate" 2>&1 || { tail -30 "$log.migrate" >&2; exit 1; }
    nohup elixir --sname "switch_$x@localhost" -S mix phx.server >"$log" 2>&1 &
    echo $! > "$(pidfile "$x")"
  )
  local i code
  for i in $(seq 1 180); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$(install_url "$x")/auth/login" || true)
    case "$code" in 302|200) break ;; esac
    sleep 2
  done
  case "$code" in 302|200) say "install $x up at $(install_url "$x") (IdP $(idp_url "$idp"))" ;;
    *) tail -40 "$log" >&2; fail "install $x did not answer /auth/login" ;; esac
}

stop_install() {
  local x="$1" f pid
  f=$(pidfile "$x")
  [ -f "$f" ] || return 0
  pid=$(cat "$f")
  if kill -0 "$pid" 2>/dev/null; then
    # The pid is the `elixir` launcher; stop the BEAM under it too.
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    say "stopped install $x (pid $pid)"
  fi
  rm -f "$f"
}

rpc() {
  local x="$1" file="$2"; shift 2
  [[ "$file" =~ ^[a-z0-9_]+\.exs$ ]] || fail "rpc: $file is not a switcher_rig/*.exs name"
  [ -f "$HERE/$file" ] || fail "rpc: no $HERE/$file"
  local enc="" a
  for a in "$@"; do enc="$enc $(printf '%s' "$a" | base64 | tr -d '\n')"; done
  elixir --sname "ctl_$$@localhost" --rpc-eval "switch_$x@localhost" \
    "args = Enum.map(~w(${enc# }), &Base.decode64!/1); Code.eval_string(File.read!(\"$HERE/$file\"), [args: args], file: \"$file\")" 2>&1 \
    | grep '^RIG ' || fail "rpc $x $file printed no RIG line"
}

case "${1:-}" in
  up)
    command -v docker >/dev/null || fail "docker not found"
    start_idp idp1; start_idp idp2
    for x in a b c; do ensure_client "$x"; done
    (cd "$PLATFORM" && MIX_ENV=dev mix compile >/dev/null)
    for x in a b c; do start_install "$x"; done
    say "up. IdP-1 $(idp_url idp1), IdP-2 $(idp_url idp2); A $(install_url a), B $(install_url b), C $(install_url c)"
    say "sign the rig user in: rig.sh login-link idp1 (then open the link in the browser)"
    ;;
  down)
    for x in a b c; do stop_install "$x"; done
    pkill -f "hostile_install.py" 2>/dev/null || true
    for idp in idp1 idp2; do docker rm -f "$(idp_container "$idp")" >/dev/null 2>&1 || true; done
    if [ "${RIG_KEEP_DB:-0}" != 1 ]; then
      for x in a b c; do psql_rig -c "DROP DATABASE IF EXISTS $(install_db "$x") WITH (FORCE)" >/dev/null || true; done
    fi
    rm -f "$STATE/secrets.env" "$STATE"/login-*.url
    say "down"
    ;;
  status)
    for idp in idp1 idp2; do echo "$idp $(docker inspect -f '{{.State.Status}}' "$(idp_container "$idp")" 2>/dev/null || echo absent)"; done
    for x in a b c; do
      if [ -f "$(pidfile "$x")" ] && kill -0 "$(cat "$(pidfile "$x")")" 2>/dev/null; then echo "$x running $(install_url "$x")"; else echo "$x stopped"; fi
    done
    ;;
  login-link) login_link "${2:?idp1 or idp2}" ;;
  rpc) shift; rpc "$@" ;;
  hostile)
    nohup python3 -I "$HERE/hostile_install.py" >"$STATE/hostile.log" 2>&1 &
    say "hostile install D on http://d.localhost:4204 (html) :4205 (5 MB) :4206 (extra fields) :4207 (30 s delay)"
    ;;
  *) sed -n '2,40p' "$0"; exit 2 ;;
esac
