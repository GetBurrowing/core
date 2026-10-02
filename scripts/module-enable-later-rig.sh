#!/usr/bin/env bash
# module-enable-later-rig.sh — ADR 0055 stage 4 (task 01a0ee08): prove that a
# build-time module can be enabled LATER on a database an install already
# has, and that the two image flavours agree with a database the pre-module
# build migrated. Runs the real release images with their own CMD
# (`Platform.Release.migrate()` then `start`), against a private database.
#
#   module-enable-later-rig.sh enable-later <core image> <play image>
#   module-enable-later-rig.sh prod-like    <base image> <core image> <play image>
#
#   <core image>  the WITHOUT-modules image (apps/platform/Dockerfile)
#   <play image>  the WITH-Play image (apps/suite_release/Dockerfile)
#   <base image>  a build of origin/main from BEFORE the module moved, whose
#                 migrations path still holds Play's two migrations
#
# enable-later:
#   1. fresh database; boot the core image (its CMD migrates);
#   2. create a project, a task and an experiment through core;
#   3. boot the play image on the SAME database (GAME_STREAM_ENABLED=true:
#      Play still gates inside the module until installs are repointed,
#      ADR 0055 § 9) and let its CMD migrate;
#   4. assert exactly Play's two versions ran, nothing else ran, no error;
#   5. drive a play session to `live` (scripts/module_rig/play_session.exs):
#      MCP over HTTP for the agent, a fake host over a real WebSocket;
#   6. drop the database.
# prod-like:
#   1. fresh database; boot the base image; insert one game_stream_sessions
#      row (the state every moon install is in: both Play versions applied
#      from the OLD path);
#   2. boot the play image (GAME_STREAM_ENABLED unset, as on Milhouse and Red
#      Star): zero migrations run, every version over its paths is `up` with
#      no `** FILE NOT FOUND **`, and a play-granted runtime gets exactly the
#      answer the base image gave it (no play tools listed; a call refused as
#      disabled);
#   3. boot the core image: migrates without error, runs nothing, and the
#      table, the row and both versions are intact;
#   4. boot the play image again: still a no-op;
#   5. drop the database.
#
# MOON ONLY, never hive (it boots three BEAMs). It talks to moon's dev rig:
# podman network `dev` and the `dev-postgres` container, never a production
# database. Every container is named core-test-task_01a0ee08-c2ec-7001-89d2-
# c888d6a7b73e-rig-<case>-<pid>-<phase>, every database rig_01a0ee08_<case>_<pid>,
# and both are removed on exit, pass or fail. Logs and the per-phase release
# logs go to $RIG_OUT (default ~/testruns/rig-01a0ee08-<case>-<pid>).
set -euo pipefail

usage() { sed -n '2,40p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
CASE="$1"; shift
case "$CASE" in
  enable-later) [ $# -eq 2 ] || usage; CORE_IMAGE="$1"; PLAY_IMAGE="$2" ;;
  prod-like) [ $# -eq 3 ] || usage; BASE_IMAGE="$1"; CORE_IMAGE="$2"; PLAY_IMAGE="$3" ;;
  *) usage ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
RIG_SCRIPTS="$HERE/module_rig"
NETWORK="${RIG_NETWORK:-dev}"
PG_CONTAINER="${RIG_PG_CONTAINER:-dev-postgres}"
PG_PASSWORD_FILE="${RIG_PG_PASSWORD_FILE:-$HOME/dev-from-hive/.env-dev-postgres}"
PREFIX="core-test-task_01a0ee08-c2ec-7001-89d2-c888d6a7b73e-rig-$CASE-$$"
DB="rig_01a0ee08_${CASE//-/_}_$$"
OUT="${RIG_OUT:-$HOME/testruns/rig-01a0ee08-$CASE-$$}"
PLAY_VERSIONS="20260926030000 20260928200000"

mkdir -p "$OUT"; chmod 700 "$OUT"
LOG="$OUT/rig.log"
exec > >(tee -a "$LOG") 2>&1

say() { echo "$(date -u +%H:%M:%S) [rig $CASE $$] $*"; }
fail() { say "FAIL: $*"; exit 1; }

command -v podman >/dev/null || fail "podman not found: this rig runs on moon"
podman container exists "$PG_CONTAINER" || fail "no $PG_CONTAINER container: this rig runs on moon's dev rig"
[ -r "$PG_PASSWORD_FILE" ] || fail "cannot read $PG_PASSWORD_FILE"
PG_PASS=$(grep '^DEV_PG_PASS=' "$PG_PASSWORD_FILE" | cut -d= -f2-)
[ -n "$PG_PASS" ] || fail "DEV_PG_PASS is empty in $PG_PASSWORD_FILE"

psql_rig() {
  podman exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" \
    psql -U postgres -v ON_ERROR_STOP=1 -qtA "$@"
}

# Secrets for the throwaway releases: generated per run, written 0600, never
# printed. The values are random; only their names matter to runtime.exs.
ENV_FILE="$OUT/release.env"
rand() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }
umask 077
cat > "$ENV_FILE" <<EOF
DATABASE_URL=ecto://postgres:${PG_PASS}@${PG_CONTAINER}:5432/${DB}
SECRET_KEY_BASE=$(rand 64)
VAULT_MASTER_KEY=$(rand 32)
ATTACHMENT_SIGNING_KEY=$(rand 48)
MEETING_GUEST_SIGNING_KEY=$(rand 48)
MEETING_CALENDAR_SIGNING_KEY=$(rand 48)
OIDC_ISSUER=https://auth.rig-01a0ee08.invalid
OIDC_CLIENT_ID=rig-01a0ee08
OIDC_CLIENT_SECRET=$(rand 32)
APP_URL=http://localhost:4000
PHX_HOST=localhost
PHX_SERVER=true
PORT=4000
POOL_SIZE=5
EOF
umask 022

cleanup() {
  local rc=$?
  for c in $(podman ps -a --format '{{.Names}}' | grep -F "$PREFIX" || true); do
    podman rm -f "$c" >/dev/null 2>&1 || true
  done
  psql_rig -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
  if psql_rig -c "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
    say "WARNING: database $DB still exists after cleanup"
  else
    say "cleanup: containers removed, database $DB dropped"
  fi
  say "exit $rc; log $LOG"
}
trap cleanup EXIT

versions() { psql_rig -d "$DB" -c "SELECT version FROM schema_migrations ORDER BY 1"; }

# boot <phase> <image> [extra podman args...]: start the image with its own
# CMD (migrate, then start) and wait for /health. Leaves it running.
boot() {
  local phase="$1" image="$2"; shift 2
  local name="$PREFIX-$phase"
  say "boot $phase: $image"
  podman run -d --name "$name" --network "$NETWORK" --env-file "$ENV_FILE" \
    -v "$RIG_SCRIPTS:/rig:ro,z" "$@" "$image" >/dev/null
  for _ in $(seq 1 120); do
    if podman exec "$name" wget -qO- http://127.0.0.1:4000/health >/dev/null 2>&1; then
      # The CMD migrates before it starts, so the migrate log is complete
      # once /health answers; stop/1 rewrites this file with the full log.
      podman logs "$name" > "$OUT/$phase.log" 2>&1 || true
      say "boot $phase: healthy"
      return 0
    fi
    if [ "$(podman inspect -f '{{.State.Running}}' "$name")" != "true" ]; then
      podman logs "$name" > "$OUT/$phase.log" 2>&1 || true
      tail -n 40 "$OUT/$phase.log"
      fail "boot $phase: the container exited before /health answered"
    fi
    sleep 2
  done
  podman logs "$name" > "$OUT/$phase.log" 2>&1 || true
  fail "boot $phase: /health did not answer within 240 s"
}

stop() {
  local phase="$1" name="$PREFIX-$1"
  podman logs "$name" > "$OUT/$phase.log" 2>&1 || true
  # The image's CMD is `/bin/sh -c "... && bin/platform start"`, and that sh
  # does not forward SIGTERM to the release, so a stop always ends in SIGKILL
  # after the grace period (as it does for the production containers). The
  # rig only needs the container gone; a short grace keeps it quick.
  podman stop -t 5 "$name" >/dev/null 2>&1
  podman rm "$name" >/dev/null
  say "stop $phase: log $OUT/$phase.log"
}

rpc() {
  local phase="$1" expr="$2"
  podman exec "$PREFIX-$phase" /app/bin/platform rpc "$expr" 2>&1 | tee -a "$OUT/$phase.rpc"
}

# The versions the release's own migrate ran, from its log.
# Empty when it ran nothing: `|| true`, because a no-match grep under pipefail
# would otherwise abort the rig at exactly the result the prod-like case wants.
ran() { { grep -oE '== Running [0-9]+' "$OUT/$1.log" || true; } | awk '{print $3}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

errors_in() { grep -cE '\*\* \(|\[error\]' "$OUT/$1.log" || true; }

psql_rig -c "CREATE DATABASE \"$DB\"" >/dev/null
say "database $DB created"

if [ "$CASE" = enable-later ]; then
  boot core "$CORE_IMAGE"
  out=$(rpc core 'Code.eval_file("/rig/exercise_core.exs")')
  task_id=$(sed -n 's/^RIG task_id=//p' <<<"$out")
  experiment_id=$(sed -n 's/^RIG experiment_id=//p' <<<"$out")
  [ -n "$task_id" ] && [ -n "$experiment_id" ] || fail "exercise_core printed no ids"
  stop core
  core_ran=$(ran core | wc -w)
  [ "$core_ran" -gt 100 ] || fail "the core image's migrate ran only $core_ran versions on a fresh DB"
  versions > "$OUT/versions-core.txt"
  for v in $PLAY_VERSIONS; do
    ! grep -qx "$v" "$OUT/versions-core.txt" || fail "the core image applied Play's $v"
  done
  say "core: migrate ran $core_ran versions, none of Play's; task $task_id, experiment $experiment_id"

  boot play "$PLAY_IMAGE" -e GAME_STREAM_ENABLED=true
  play_ran=$(ran play)
  say "play: migrate ran [$play_ran]"
  [ "$play_ran" = "$PLAY_VERSIONS" ] || fail "expected exactly [$PLAY_VERSIONS], the play image's migrate ran [$play_ran]"
  versions > "$OUT/versions-play.txt"
  added=$(comm -13 "$OUT/versions-core.txt" "$OUT/versions-play.txt" | tr '\n' ' ' | sed 's/ $//')
  removed=$(comm -23 "$OUT/versions-core.txt" "$OUT/versions-play.txt" | wc -l)
  [ "$added" = "$PLAY_VERSIONS" ] || fail "schema_migrations gained [$added]"
  [ "$removed" -eq 0 ] || fail "schema_migrations lost $removed versions"
  newest_core=$(tail -n1 "$OUT/versions-core.txt")
  say "play: schema_migrations gained exactly [$added], lost none; newest core version $newest_core (Play's are older: applied out of order)"

  out=$(rpc play "Code.eval_string(File.read!(\"/rig/verify_core.exs\"), task_id: \"$task_id\", experiment_id: \"$experiment_id\")")
  grep -qx 'RIG task_intact=true' <<<"$out" || fail "the task did not survive the switch"
  grep -qx 'RIG experiment_intact=true' <<<"$out" || fail "the experiment did not survive the switch"
  fks=$(psql_rig -d "$DB" -c "SELECT string_agg(DISTINCT ccu.table_name, ',' ORDER BY ccu.table_name) FROM information_schema.table_constraints tc JOIN information_schema.constraint_column_usage ccu USING (constraint_name) WHERE tc.table_name = 'game_stream_sessions' AND tc.constraint_type = 'FOREIGN KEY'")
  say "play: game_stream_sessions references -> $fks (encoder and roster experiments, and the task)"
  [ "$fks" = "experiments,tasks" ] || fail "unexpected foreign keys: $fks"

  out=$(rpc play 'Code.eval_file("/rig/play_session.exs")')
  grep -qx 'RIG status_state=live' <<<"$out" || fail "the play session never reached live"
  grep -qx 'RIG session_rows=1' <<<"$out" || fail "ending the session wrote no game_stream_sessions row"
  stop play
  play_errors=$(errors_in play)
  say "play: [error] or crash lines in the release log: $play_errors"
  say "PASS enable-later"
fi

if [ "$CASE" = prod-like ]; then
  boot base "$BASE_IMAGE"
  out=$(rpc base 'Code.eval_file("/rig/insert_session_row.exs")')
  row_id=$(sed -n 's/^RIG session_row_id=//p' <<<"$out")
  [ -n "$row_id" ] || fail "insert_session_row printed no id"
  # Main's answer with GAME_STREAM_ENABLED unset: the reference the with-Play
  # image is compared against below.
  base_flag=$(rpc base 'Code.eval_file("/rig/flag_unset.exs")' | grep '^RIG flag_unset_')
  grep -q 'game_stream is disabled' <<<"$base_flag" || fail "base: unexpected flag-unset answer: $base_flag"
  say "base: flag unset -> $(tr '\n' ';' <<<"$base_flag")"
  stop base
  versions > "$OUT/versions-base.txt"
  for v in $PLAY_VERSIONS; do
    grep -qx "$v" "$OUT/versions-base.txt" || fail "the base image did not apply Play's $v; it is not a pre-module build"
  done
  say "base: $(wc -l < "$OUT/versions-base.txt") versions incl. both of Play's; session row $row_id"

  for phase in play core play2; do
    image="$PLAY_IMAGE"; [ "$phase" = core ] && image="$CORE_IMAGE"
    boot "$phase" "$image"
    if [ "$phase" != core ]; then
      out=$(rpc "$phase" 'Code.eval_file("/rig/migration_status.exs")')
      if grep -q 'FILE NOT FOUND' <<<"$out"; then
        grep 'FILE NOT FOUND' <<<"$out"
        fail "$phase: a version is applied whose file this build lacks"
      fi
      for v in $PLAY_VERSIONS; do
        grep -qE "^RIG migration up $v " <<<"$out" || fail "$phase: Play's $v is not listed up"
      done
      down=$(grep -cE '^RIG migration down ' <<<"$out" || true)
      [ "$down" -eq 0 ] || fail "$phase: $down versions are down"
      say "$phase: every version up over $(sed -n 's/^RIG paths=//p' <<<"$out" | tr ',' '\n' | wc -l) paths, no FILE NOT FOUND"
      # GAME_STREAM_ENABLED is unset here, as on Milhouse and Red Star after
      # the merge: Play must look exactly as main does with the flag unset.
      flag=$(rpc "$phase" 'Code.eval_file("/rig/flag_unset.exs")' | grep '^RIG flag_unset_')
      grep -qx 'RIG flag_unset_play_tools=0' <<<"$flag" || fail "$phase: play tools are listed with the flag unset"
      [ "$flag" = "$base_flag" ] || fail "$phase: flag-unset answer differs from main's: [$flag] vs [$base_flag]"
      say "$phase: flag unset -> identical to main's: $(tr '\n' ';' <<<"$flag")"
    else
      out=$(rpc core 'Code.eval_file("/rig/migration_status.exs")')
      missing=$(grep -c 'FILE NOT FOUND' <<<"$out" || true)
      say "core: $missing applied versions have no file in this build (expected: Play's 2, harmless; Ecto reads them as applied and runs nothing)"
    fi
    stop "$phase"
    r=$(ran "$phase")
    [ -z "$r" ] || fail "$phase: migrate ran [$r] on a database that already has every version"
    rows=$(psql_rig -d "$DB" -c "SELECT count(*) FROM game_stream_sessions WHERE id = '$row_id'")
    [ "$rows" = 1 ] || fail "$phase: the session row is gone"
    versions > "$OUT/versions-$phase.txt"
    cmp -s "$OUT/versions-base.txt" "$OUT/versions-$phase.txt" || fail "$phase: schema_migrations changed"
    say "$phase: migrate ran nothing; row and versions intact; release log [error]/crash lines: $(errors_in "$phase")"
  done
  say "PASS prod-like"
fi
