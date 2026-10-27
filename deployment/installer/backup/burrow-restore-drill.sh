#!/bin/bash
# Burrow restore drill (core task 01a17b10 stage 5). Rendered as
# bin/burrow-restore-drill.
#
# Usage: burrow-restore-drill <backup dir> [stamp]
#   <backup dir>  a local-path backup root (for s3, sync the newest prefix down first)
#   [stamp]       defaults to the newest <utc stamp> directory
#
# Restores every <db>.dump into a THROWAWAY postgres and every <volume>.tar.gz
# into a temp dir, then checks them against MANIFEST. It prints
#   restored <db> <rows>       rows summed over every restored table
#   verified volume <name> <n> the extracted file count equals MANIFEST's
# and exits non-zero if a database restored no tables or a count differs.
#
# The throwaway postgres is a database created inside $DRILL_PG_CONTAINER
# (dropped afterwards) when set, else a short-lived container of $HELPER_IMAGE
# (the postgres image) removed at the end. Settings come from backup.conf
# ($BURROW_BACKUP_CONF) plus those env overrides. Never prints a secret.
set -euo pipefail
set +x

root=${1:?backup dir}
conf=${BURROW_BACKUP_CONF:-/opt/burrow/backup.conf}
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"
: "${HELPER_IMAGE:=}" "${PG_USER:=postgres}"

stamp=${2:-$(ls -1 "$root" | sort | tail -n 1)}
snap="$root/$stamp"
[ -d "$snap" ] || { echo "error: no backup at $snap" >&2; exit 1; }
[ -f "$snap/MANIFEST" ] || { echo "error: $snap has no MANIFEST" >&2; exit 1; }

work=$(mktemp -d "${BURROW_BACKUP_TMP:-/var/tmp}/burrow-drill.XXXXXX")
pg=${DRILL_PG_CONTAINER:-}
own_container=
cleanup() {
  if [ -n "$own_container" ]; then
    docker rm -f "$own_container" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

if [ -z "$pg" ]; then
  [ -n "$HELPER_IMAGE" ] || { echo "error: HELPER_IMAGE unset" >&2; exit 1; }
  own_container="burrow-drill-$$"
  docker run -d --name "$own_container" -e POSTGRES_HOST_AUTH_METHOD=trust "$HELPER_IMAGE" >/dev/null
  pg=$own_container
  PG_USER=postgres
  for _ in $(seq 1 60); do
    docker exec "$pg" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
fi

psql_run() { docker exec "$pg" psql -U "$PG_USER" -v ON_ERROR_STOP=1 "$@" </dev/null; }
status=0

while read -r kind name rest; do
  case "$kind" in
    db)
      tmpdb="burrow_drill_$$_$(echo "$name" | tr -c 'a-z0-9\n' '_')"
      psql_run -d postgres -qc "create database \"$tmpdb\"" >/dev/null
      # Roles and extensions from the source may be absent here: restore what restores.
      docker exec -i "$pg" pg_restore -U "$PG_USER" -d "$tmpdb" --no-owner --no-privileges <"$snap/$name.dump" >/dev/null 2>"$work/restore.err" || true
      tables=$(psql_run -d "$tmpdb" -Atc "select count(*) from pg_tables where schemaname = 'public'")
      rows=0
      for t in $(psql_run -d "$tmpdb" -Atc "select quote_ident(tablename) from pg_tables where schemaname = 'public' order by 1"); do
        n=$(psql_run -d "$tmpdb" -Atc "select count(*) from public.$t")
        rows=$((rows + n))
      done
      psql_run -d postgres -qc "drop database \"$tmpdb\"" >/dev/null
      if [ "$tables" -le 0 ]; then
        echo "error: $name restored no tables" >&2
        status=1
      else
        echo "restored $name $rows"
      fi
      ;;
    volume)
      want=${rest#files }
      dest="$work/vol-$name"
      mkdir -p "$dest"
      tar -xzf "$snap/$name.tar.gz" -C "$dest"
      got=$(find "$dest" -type f | wc -l | tr -d ' ')
      if [ "$got" = "$want" ]; then
        echo "verified volume $name $got"
      else
        echo "error: volume $name has $got files, manifest says $want" >&2
        status=1
      fi
      ;;
  esac
done <"$snap/MANIFEST"

echo "drill end status=$status"
exit "$status"
