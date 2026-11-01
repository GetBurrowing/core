#!/usr/bin/env bash
# Start the two pinned headless-shell containers on a podman host, tunnel
# their CDP ports here, run paint.mjs against both, and tear everything down.
#
#   run.sh <out dir> <variant>... | all        (extra paint.mjs flags via PAINT_FLAGS)
#
# PODMAN_HOST  ssh destination with podman (default rocks@moon.local)
# PORT151/147  ports used on both ends (default 19551 / 19547)
#
# The pins and the raster flag are the instrument; README.md says why each
# build runs the way it does. Change one and the positive control must be
# re-run before any row is trusted.
set -euo pipefail

IMG151=docker.io/chromedp/headless-shell@sha256:2d349b544a1ea6b5b5fd7c0fe99215ff662339c57407ee2e8c0a11af93516b04 # 151.0.7922.109
IMG147=docker.io/chromedp/headless-shell@sha256:69e8a5a1fb39e8029683fb33f41a4a470e1ac183fe431a6a40631b977f6d62f3 # 147.0.7727.15

out=${1:?usage: run.sh <out dir> <variant>... | all}
shift
[ $# -gt 0 ] || { echo "name variants or all" >&2; exit 2; }

host=${PODMAN_HOST:-rocks@moon.local}
p151=${PORT151:-19551}
p147=${PORT147:-19547}
tag="paint-$$"
here="$(cd "$(dirname "$0")" && pwd)"
tunnel=""

cleanup() {
  [ -n "$tunnel" ] && kill "$tunnel" 2>/dev/null || true
  ssh "$host" "podman rm -f $tag-151 $tag-147 >/dev/null 2>&1 || true"
}
trap cleanup EXIT INT TERM HUP

# --shm-size: a full-page capture is larger than podman's 64 MB /dev/shm,
# and the GPU process dies copying it out (VALIDATION_ERROR_DESERIALIZATION_FAILED).
ssh "$host" "podman run -d --rm --shm-size=1g --name $tag-151 -p 127.0.0.1:$p151:9222 $IMG151 >/dev/null &&
             podman run -d --rm --shm-size=1g --name $tag-147 -p 127.0.0.1:$p147:9222 $IMG147 --disable-gpu >/dev/null"

ssh -N -o ExitOnForwardFailure=yes -L "$p151:127.0.0.1:$p151" -L "$p147:127.0.0.1:$p147" "$host" &
tunnel=$!

for port in "$p151" "$p147"; do
  for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$port/json/version" >/dev/null && break
    sleep 0.2
  done
done

node "$here/paint.mjs" --out "$out" \
  --build "chrome151=127.0.0.1:$p151" --build "chrome147=127.0.0.1:$p147" \
  ${PAINT_FLAGS:-} "$@"
