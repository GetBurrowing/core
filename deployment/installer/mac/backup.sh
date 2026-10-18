#!/bin/bash
# Burrow install backup (task 01a0d6ab stage 4): pg_dump every database of the
# bundled postgres into <backup dir>/<db>-<utc>.dump, check each dump with
# `pg_restore --list`, keep the newest <keep> per database.
#
# Usage: backup.sh <install dir> <backup dir> [keep=14] [postgres user=core_platform]
#
# Installed by `burrow_install setup run backup` as a user LaunchAgent (daily
# 03:15, no sudo). Dumping to plain files means Time Machine captures
# consistent dumps instead of a live database inside the runtime's VM disk.
# The dumps cover core, memory AND pocket-id (sign-in): all three live in the
# one core-postgres container on the mac target.
#
# Output contract (parsed by the setup step): one `dump <db> <path>` and one
# `verified <db> <entries>` line per database. Never prints a secret: pg_dump
# runs inside the container over its local socket (trust), no password.
set -euo pipefail

install_dir=${1:?install dir}
backup_dir=${2:?backup dir}
keep=${3:-14}
pg_user=${4:-core_platform}

compose=(docker compose --project-directory "$install_dir" -f "$install_dir/compose.yaml")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
echo "backup start $stamp"

dbs=$("${compose[@]}" exec -T core-postgres psql -U "$pg_user" -d postgres -Atc \
  "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")

status=0
for db in $dbs; do
  out="$backup_dir/$db-$stamp.dump"
  "${compose[@]}" exec -T core-postgres pg_dump -U "$pg_user" -Fc "$db" >"$out.partial"
  mv "$out.partial" "$out"
  chmod 600 "$out"
  echo "dump $db $out"
  entries=$("${compose[@]}" exec -T core-postgres pg_restore --list <"$out" | grep -cv '^;' || true)
  if [ "${entries:-0}" -gt 0 ]; then
    echo "verified $db $entries"
  else
    echo "error: $db: pg_restore --list read no entries from $out" >&2
    status=1
  fi
  # Oldest first: the UTC stamp sorts lexically.
  shopt -s nullglob
  files=("$backup_dir/$db-"*.dump)
  shopt -u nullglob
  excess=$((${#files[@]} - keep))
  for ((i = 0; i < excess; i++)); do
    rm -f -- "${files[$i]}"
    echo "rotated $db ${files[$i]}"
  done
done
echo "backup end status=$status"
exit "$status"
