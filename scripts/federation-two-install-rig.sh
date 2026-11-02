#!/usr/bin/env bash
# federation-two-install-rig.sh — task 01a199b2 (ADR 0054): two real Suite
# installs on the test rig's podman `dev` network, so install-to-install
# federation can be driven end to end through the real protocol entry points.
#
#   federation-two-install-rig.sh up <src_a> <src_b>
#   federation-two-install-rig.sh stop <a|b>
#   federation-two-install-rig.sh start <a|b>
#   federation-two-install-rig.sh rpc <a|b> <file.exs> [args...]
#   federation-two-install-rig.sh down
#
#   <src_a> <src_b>  core checkouts (may be the same path). Each is copied to
#                    $RIG_OUT/src-<x>: every install needs its own _build and
#                    deps, and the copy is what the container mounts at /app.
#
# up:    starts dev-fed-a-01a199b2 and dev-fed-b-01a199b2 (MIX_ENV=dev, image
#        $RIG_IMAGE) on network `dev`, each with its own database on
#        dev-postgres (fed_a_01a199b2, fed_b_01a199b2), PEER_FEDERATION_ENABLED,
#        PEER_FEDERATION_ALLOW_HTTP and PEER_FEDERATION_BASE_URL=
#        http://dev-fed-<x>-01a199b2:4000. VAULT_MASTER_KEY comes from a
#        per-install podman secret: outside prod runtime.exs generates a RANDOM
#        vault key on every boot, and the install's Ed25519 signing key lives
#        in Platform.Vault, so an unpinned install cannot sign after a restart.
#        Waits for /.well-known/burrow-federation to answer 200 on both (and
#        across the network), then prints each fingerprint (via the
#        platform.gen_install_identity task, over rpc) and identity.exs.
#        On exit, pass or fail, `up` runs `down` unless RIG_KEEP=1.
# stop/start: podman stop/start of one install; same DB, secrets and source
#        copy, so it comes back as the same install with the same key.
# rpc:   evaluates scripts/federation_rig/<file.exs> ON the running server
#        node (`elixir --sname ctl.. --rpc-eval fed_<x>@<host>`), so PubSub
#        broadcasts reach that node's PeerConnection. A `mix run` would boot a
#        second app and is never used. Args reach the script as `args` (a list
#        of strings). Erlang distribution here is operator control INSIDE one
#        container; the two installs never talk to each other over it.
# down:  removes both containers, drops both databases, removes the secrets,
#        the uploads volumes and the source copies, then prints the listings
#        (all empty) as proof.
#
# TEST-RIG ONLY: it boots two dev BEAMs. It never talks to a production
# install, and it adds no bypass a production install could reach: plain http
# and private peer addresses are honoured only because MIX_ENV=dev
# (Platform.Federation.Peers.Config.allow_http?/0 is false in :prod).
# RIG_HOST (required, no default) is the test-rig host's short hostname; the
# script refuses to run anywhere else.
# RIG_PG_PASSWORD_FILE (required for up and down, no default) is the env file
# holding DEV_PG_PASS. Secret values are generated per run, written 0600 only
# long enough to hand to `podman secret create`, and never printed. The log
# is $RIG_OUT/rig.log (default ~/testruns/rig-01a199b2).
set -euo pipefail

usage() { sed -n '2,47p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
CMD="$1"; shift

TAG=01a199b2
HERE="$(cd "$(dirname "$0")" && pwd)"
RIG_SCRIPTS="$HERE/federation_rig"
NETWORK=dev
PG_CONTAINER=dev-postgres
IMAGE="${RIG_IMAGE:-docker.io/library/elixir:1.20.4-otp-28}"
OUT="${RIG_OUT:-$HOME/testruns/rig-$TAG}"
BOOT_TIMEOUT="${RIG_BOOT_TIMEOUT:-2400}"

container() { echo "dev-fed-$1-$TAG"; }
db() { echo "fed_$1_$TAG"; }
vault_secret() { echo "fed-vault-$1-$TAG"; }
cookie_secret() { echo "fed-cookie-$1-$TAG"; }
uploads_volume() { echo "fed-uploads-$1-$TAG"; }
node_name() { echo "fed_$1"; }
CONTAINER_RE="^dev-fed-[ab]-$TAG\$"
VOLUME_RE="^fed-uploads-[ab]-$TAG\$"
SECRET_RE="^fed-(vault|cookie)-[ab]-$TAG\$"
DB_RE="^fed_[ab]_$TAG\$"

mkdir -p "$OUT"; chmod 700 "$OUT"
LOG="$OUT/rig.log"
exec > >(tee -a "$LOG") 2>&1

say() { echo "$(date -u +%H:%M:%S) [fed-rig $CMD $$] $*"; }
fail() { say "FAIL: $*"; exit 1; }

[ -n "${RIG_HOST:-}" ] || fail "RIG_HOST is required (no default): the test-rig host's short hostname"
[ "$(hostname -s)" = "$RIG_HOST" ] || fail "test-rig only: this boots two dev BEAMs and must run on the test-rig host (RIG_HOST=$RIG_HOST)"
command -v podman >/dev/null || fail "podman not found"
podman container exists "$PG_CONTAINER" || fail "no $PG_CONTAINER container: this rig runs on the test rig's dev services"

install_arg() {
  case "${1:-}" in
    a|b) echo "$1" ;;
    *) usage ;;
  esac
}

PG_PASS=""
load_pg_pass() {
  local f="${RIG_PG_PASSWORD_FILE:-}"
  [ -n "$f" ] || fail "RIG_PG_PASSWORD_FILE is required (no default): the env file holding DEV_PG_PASS on the test rig"
  [ -r "$f" ] || fail "cannot read $f"
  PG_PASS=$(grep '^DEV_PG_PASS=' "$f" | cut -d= -f2-)
  [ -n "$PG_PASS" ] || fail "DEV_PG_PASS is empty in $f"
}

psql_rig() {
  podman exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" \
    psql -U postgres -v ON_ERROR_STOP=1 -qtA "$@"
}

# The well-known status as seen from inside <from>'s container.
well_known() {
  local from="$1" host="$2"
  podman exec "$(container "$from")" \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://$host:4000/.well-known/burrow-federation" 2>/dev/null || true
}

wait_ready() {
  local x="$1" c deadline code
  c=$(container "$x")
  deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  while :; do
    code=$(well_known "$x" 127.0.0.1)
    if [ "$code" = 200 ]; then
      say "$c: /.well-known/burrow-federation -> 200"
      return 0
    fi
    if [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
      podman logs --tail 60 "$c" 2>&1 || true
      fail "$c exited before /.well-known/burrow-federation answered"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      podman logs --tail 60 "$c" 2>&1 || true
      fail "$c: no 200 within ${BOOT_TIMEOUT}s (last status '${code:-none}')"
    }
    sleep 10
  done
}

# rpc_eval <x> <elixir expr>: evaluate on the install's running server node.
# Its output is the rpc group leader's, which also carries the dev install's
# :debug Ecto lines (measured: they come from processes that inherit the rpc
# group leader, so Logger.put_process_level on the rpc process does not stop
# them). Callers therefore keep only the lines they asked for.
rpc_eval() {
  local x="$1" expr="$2"
  podman exec "$(container "$x")" sh -c \
    'exec elixir --sname "$1" --rpc-eval "$2@$(hostname -s)" "$3"' \
    sh "ctl_$$_$RANDOM" "$(node_name "$x")" "$expr"
}

rpc_file() {
  local x="$1" file="$2"; shift 2
  file=$(basename "$file")
  [[ "$file" =~ ^[a-z0-9_]+\.exs$ ]] || fail "rpc: '$file' is not a scripts/federation_rig/*.exs name"
  [ -f "$RIG_SCRIPTS/$file" ] || fail "rpc: no $RIG_SCRIPTS/$file"
  local encoded=() a full rc=0
  for a in "$@"; do encoded+=("$(printf '%s' "$a" | base64 | tr -d '\n')"); done
  # Rig scripts print their result as lines starting `RIG `; everything else
  # (the install's debug log) goes to $OUT/rpc-<x>.log, and is shown only
  # when the eval fails.
  full=$(mktemp "$OUT/.rpc.XXXXXX")
  rpc_eval "$x" "args = Enum.map(~w(${encoded[*]:-}), &Base.decode64!/1); Code.eval_string(File.read!(\"/rig/$file\"), [args: args], file: \"/rig/$file\")" > "$full" 2>&1 || rc=$?
  cat "$full" >> "$OUT/rpc-$x.log"
  grep '^RIG ' "$full" || true
  if [ "$rc" -ne 0 ]; then
    tail -n 40 "$full"
    rm -f "$full"
    fail "rpc $x $file exited $rc (full output in $OUT/rpc-$x.log)"
  fi
  rm -f "$full"
}

# The boot command. It re-runs on `start`: deps, ecto.create and migrate are
# no-ops on a warm copy. The cookie is copied from its secret mount; neither
# secret value is ever echoed.
# shellcheck disable=SC2016 # expanded inside the container, not here
BOOT='set -e
install -m 400 "/run/secrets/$RIG_COOKIE_SECRET" "$HOME/.erlang.cookie"
mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null
# Both installs fetch every hex package cold at once. Measured on the test rig (task
# 01a199b2): 2 of 10 cold install boots died here on one registry or tarball
# fetch (llm_db, ex_mcp-1.5.0.tar :timeout). Retry, with a longer timeout.
for try in 1 2 3; do
  HEX_HTTP_TIMEOUT=120 HEX_HTTP_CONCURRENCY=4 mix deps.get >/dev/null && break
  [ "$try" = 3 ] && exit 1
  echo "deps.get failed (try $try of 3); retrying in 15s" >&2; sleep 15
done
mix ecto.create
mix ecto.migrate
exec elixir --sname "$RIG_NODE" -S mix phx.server'

secret_from_random() {
  local name="$1" kind="$2" f
  podman secret exists "$name" && podman secret rm "$name" >/dev/null
  f=$(umask 077; mktemp "$OUT/.secret.XXXXXX")
  chmod 600 "$f"
  case "$kind" in
    vault) openssl rand -base64 32 | tr -d '\n' > "$f" ;;
    cookie) openssl rand -hex 32 | tr -d '\n' > "$f" ;;
  esac
  podman secret create "$name" "$f" >/dev/null
  rm -f "$f"
}

start_install() {
  local x="$1" src="$2" c
  c=$(container "$x")
  say "$c: copying $src -> $OUT/src-$x"
  mkdir -p "$OUT/src-$x"
  rsync -a --delete --exclude _build --exclude deps --exclude node_modules \
    --exclude .elixir_ls "$src/" "$OUT/src-$x/"
  secret_from_random "$(vault_secret "$x")" vault
  secret_from_random "$(cookie_secret "$x")" cookie
  podman volume create "$(uploads_volume "$x")" >/dev/null
  say "$c: starting ($IMAGE, database $(db "$x"))"
  PGPASSWORD="$PG_PASS" podman run -d --name "$c" --hostname "$c" --network "$NETWORK" \
    -v "$OUT/src-$x:/app:z" \
    -v "$RIG_SCRIPTS:/rig:ro,z" \
    -v "$(uploads_volume "$x"):/data/platform/chat_uploads:z" \
    -w /app/apps/platform \
    -e MIX_ENV=dev -e PGHOST="$PG_CONTAINER" -e PGUSER=postgres -e PGPASSWORD \
    -e PLATFORM_DEV_DATABASE="$(db "$x")" \
    -e PHX_BIND_IP=0.0.0.0 -e PORT=4000 \
    -e PEER_FEDERATION_ENABLED=true -e PEER_FEDERATION_ALLOW_HTTP=true \
    -e PEER_FEDERATION_BASE_URL="http://$c:4000" \
    -e RIG_NODE="$(node_name "$x")" -e RIG_COOKIE_SECRET="$(cookie_secret "$x")" \
    --secret "$(vault_secret "$x"),type=env,target=VAULT_MASTER_KEY" \
    --secret "$(cookie_secret "$x")" \
    "$IMAGE" bash -c "$BOOT" >/dev/null
}

teardown() {
  local x
  for x in a b; do
    podman rm -f -t 10 "$(container "$x")" >/dev/null 2>&1 || true
  done
  for x in a b; do
    psql_rig -c "DROP DATABASE IF EXISTS \"$(db "$x")\" WITH (FORCE)" >/dev/null || true
    podman secret rm "$(vault_secret "$x")" >/dev/null 2>&1 || true
    podman secret rm "$(cookie_secret "$x")" >/dev/null 2>&1 || true
    podman volume rm -f "$(uploads_volume "$x")" >/dev/null 2>&1 || true
    rm -rf "${OUT:?}/src-$x"
  done
  rm -f "$OUT"/.secret.* "$OUT"/.rpc.* 2>/dev/null || true

  # The proof matches the rig's OWN names only. A bare `01a199b2` also
  # matches this task's core-test containers and test databases (measured:
  # a concurrent core-test run made the first teardown report a leftover).
  say "proof: podman ps -a --filter name='$CONTAINER_RE'"
  podman ps -a --filter "name=$CONTAINER_RE"
  say "proof: podman volume ls --filter name='$VOLUME_RE'"
  podman volume ls --filter "name=$VOLUME_RE"
  say "proof: podman secret ls (names matching '$SECRET_RE')"
  podman secret ls --format '{{.Name}}' | { grep -E "$SECRET_RE" || true; }
  say "proof: psql \\l on $PG_CONTAINER (names matching '$DB_RE')"
  psql_rig -l | cut -d'|' -f1 | { grep -E "$DB_RE" || true; }
  say "proof: ls -A $OUT"
  ls -A "$OUT"

  local left=0
  [ -z "$(podman ps -a --format '{{.Names}}' | grep -E "$CONTAINER_RE" || true)" ] || left=1
  [ -z "$(podman volume ls --format '{{.Name}}' | grep -E "$VOLUME_RE" || true)" ] || left=1
  [ -z "$(podman secret ls --format '{{.Name}}' | grep -E "$SECRET_RE" || true)" ] || left=1
  [ -z "$(psql_rig -l | cut -d'|' -f1 | grep -E "$DB_RE" || true)" ] || left=1
  ! ls -d "$OUT"/src-* >/dev/null 2>&1 || left=1
  [ "$left" -eq 0 ] || fail "teardown left something behind (see the listings above)"
  say "teardown complete: every listing above is empty"
}

case "$CMD" in
  up)
    [ $# -eq 2 ] || usage
    SRC_A="$(cd "$1" && pwd)"; SRC_B="$(cd "$2" && pwd)"
    for s in "$SRC_A" "$SRC_B"; do
      [ -f "$s/apps/platform/mix.exs" ] || fail "$s is not a core checkout (no apps/platform/mix.exs)"
    done
    load_pg_pass
    command -v openssl >/dev/null || fail "openssl not found"
    for x in a b; do
      ! podman container exists "$(container "$x")" || fail "$(container "$x") already exists: run down first"
    done
    if [ "${RIG_KEEP:-}" = 1 ]; then
      say "RIG_KEEP=1: the installs stay up; run down to remove them"
    else
      # shellcheck disable=SC2154 # rc is assigned inside the trap string
      trap 'rc=$?; say "exit $rc: tearing down (RIG_KEEP=1 keeps the rig)"; teardown; say "log $LOG"' EXIT
    fi
    start_install a "$SRC_A"
    start_install b "$SRC_B"
    wait_ready a
    wait_ready b
    for pair in a:b b:a; do
      from=${pair%:*}; to=${pair#*:}
      code=$(well_known "$from" "$(container "$to")")
      [ "$code" = 200 ] || fail "$(container "$from") cannot reach $(container "$to") over $NETWORK (status '$code')"
      say "$(container "$from") -> http://$(container "$to"):4000/.well-known/burrow-federation: 200"
    done
    for x in a b; do
      fp=$(rpc_eval "$x" 'Mix.Tasks.Platform.GenInstallIdentity.run([])' | { grep -xE '[0-9a-f]{64}' || true; } | tail -n 1)
      [ -n "$fp" ] || fail "platform.gen_install_identity printed nothing on $x"
      say "fingerprint $x (platform.gen_install_identity): $fp"
      rpc_file "$x" identity.exs
    done
    say "up: both installs serve /.well-known/burrow-federation"
    ;;
  stop)
    x=$(install_arg "${1:-}")
    podman stop -t 30 "$(container "$x")" >/dev/null
    say "$(container "$x"): stopped (state $(podman inspect -f '{{.State.Status}}' "$(container "$x")"))"
    ;;
  start)
    x=$(install_arg "${1:-}")
    podman start "$(container "$x")" >/dev/null
    wait_ready "$x"
    ;;
  rpc)
    [ $# -ge 2 ] || usage
    x=$(install_arg "$1"); shift
    rpc_file "$x" "$@"
    ;;
  down)
    [ $# -eq 0 ] || usage
    load_pg_pass
    teardown
    ;;
  *)
    usage
    ;;
esac
