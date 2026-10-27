#!/bin/bash
# Burrow single-host backup (core task 01a17b10 stage 5). Rendered into an
# install as bin/burrow-backup and run nightly by burrow-backup.timer.
#
# One run writes <dest>/<utc stamp>/ holding
#   <db>.dump         pg_dump -Fc of every database in the postgres container
#   <volume>.tar.gz   a snapshot of each named volume (and host dir) in the conf
#   MANIFEST          `db <name>`, `volume <name> files <n>` lines the restore
#                     drill checks against
# then keeps the newest KEEP stamp directories and deletes the rest.
#
# Configuration is backup.conf (KEY=value, rendered by burrow_install), path in
# $BURROW_BACKUP_CONF. It names secret REFS only (ACCESS_KEY_REF and
# SECRET_KEY_REF are env var names); the values come from the environment,
# which the systemd unit fills from customer-secrets.env (0600 root). This
# script never prints a secret and never puts one on a command line.
set -euo pipefail
set +x

conf=${BURROW_BACKUP_CONF:-/opt/burrow/backup.conf}
# shellcheck disable=SC1090
. "$conf"

: "${TARGET:?}" "${KEEP:=14}" "${PG_CONTAINER:=core-postgres}" "${PG_USER:?}"
: "${HELPER_IMAGE:?}" "${VOLUMES:=}" "${HOST_DIRS:=}" "${DATABASES:=}"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
stage=$(mktemp -d "${BURROW_BACKUP_TMP:-/var/tmp}/burrow-backup.XXXXXX")
trap 'rm -rf "$stage"' EXIT
chmod 700 "$stage"
snap="$stage/$stamp"
mkdir -p "$snap"
echo "backup start $stamp target=$TARGET"

dbs=$DATABASES
if [ -z "$dbs" ]; then
  dbs=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -Atc \
    "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")
fi

for db in $dbs; do
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc "$db" >"$snap/$db.dump"
  entries=$(docker exec -i "$PG_CONTAINER" pg_restore --list <"$snap/$db.dump" | grep -cv '^;' || true)
  if [ "${entries:-0}" -le 0 ]; then
    echo "error: $db: pg_restore --list read no entries" >&2
    exit 1
  fi
  echo "db $db" >>"$snap/MANIFEST"
  echo "dump $db entries=$entries"
done

for vol in $VOLUMES; do
  docker run --rm -v "$vol:/src:ro" --entrypoint tar "$HELPER_IMAGE" -C /src -czf - . >"$snap/$vol.tar.gz"
  files=$(tar -tzf "$snap/$vol.tar.gz" | grep -vc '/$' || true)
  echo "volume $vol files ${files:-0}" >>"$snap/MANIFEST"
  echo "volume $vol files=${files:-0}"
done

for dir in $HOST_DIRS; do
  name=host$(echo "$dir" | tr '/' '-')
  tar -C "$dir" -czf "$snap/$name.tar.gz" .
  files=$(tar -tzf "$snap/$name.tar.gz" | grep -vc '/$' || true)
  echo "volume $name files ${files:-0}" >>"$snap/MANIFEST"
  echo "volume $name files=${files:-0}"
done

size=0
for f in "$snap"/*; do
  n=$(wc -c <"$f")
  size=$((size + n))
done

oldest_over_keep() {
  awk -v keep="$KEEP" '{ a[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print a[i] }'
}

aws_run() {
  docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    -v "$stage:/stage:ro" "$AWS_CLI_IMAGE" --endpoint-url "$ENDPOINT" "$@"
}

case "$TARGET" in
  local-path)
    mkdir -p "$DEST_PATH"
    chmod 700 "$DEST_PATH"
    mv "$snap" "$DEST_PATH/$stamp"
    # The UTC stamp sorts lexically: oldest first.
    old=$(ls -1 "$DEST_PATH" | sort | oldest_over_keep || true)
    for d in $old; do
      rm -rf "${DEST_PATH:?}/$d"
      echo "rotated $d"
    done
    ;;
  s3-compatible)
    AWS_ACCESS_KEY_ID=${!ACCESS_KEY_REF:?access key ref is unset}
    AWS_SECRET_ACCESS_KEY=${!SECRET_KEY_REF:?secret key ref is unset}
    AWS_DEFAULT_REGION=${REGION:-us-east-1}
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    aws_run s3 cp --recursive --only-show-errors "/stage/$stamp" "s3://$BUCKET/$stamp"
    old=$(aws_run s3 ls "s3://$BUCKET/" | awk '$1 == "PRE" {print $2}' | tr -d '/' | sort | oldest_over_keep || true)
    for d in $old; do
      aws_run s3 rm --recursive --only-show-errors "s3://$BUCKET/$d/"
      echo "rotated $d"
    done
    ;;
  *)
    echo "error: unknown target" >&2
    exit 1
    ;;
esac

# Status for admin_health: time and size only, no paths, no secrets.
status=$(printf '{"last_success_at":"%s","size_bytes":%s,"target":"%s","databases":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$size" "$TARGET" "$(echo "$dbs" | wc -w | tr -d ' ')")
if [ -n "${BURROW_BACKUP_STATUS_FILE:-}" ]; then
  printf '%s' "$status" >"$BURROW_BACKUP_STATUS_FILE"
elif [ -n "${STATUS_VOLUME:-}" ]; then
  printf '%s' "$status" | docker run --rm -i -v "$STATUS_VOLUME:/d" --entrypoint sh "$HELPER_IMAGE" \
    -c 'cat > /d/backup-status.json && chmod 644 /d/backup-status.json'
fi
echo "backup end size=$size"
