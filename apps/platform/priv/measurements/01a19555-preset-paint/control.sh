#!/usr/bin/env bash
# The positive control: diff a paint.mjs output directory against the
# committed fixtures, comment lines (`#`) excepted. Prints each diff and a
# per-fixture count of differing lines; exits 1 if any fixture differs.
#
#   control.sh <paint output dir>
set -uo pipefail

out=${1:?usage: control.sh <paint output dir>}
fixtures="$(cd "$(dirname "$0")/../../../test/support/fixtures" && pwd)"
status=0

for pair in \
  "painted_glass/chrome151.csv chrome151.csv" \
  "painted_glass/chrome147.csv chrome147.csv" \
  "painted_glass/underlay_chrome151.csv underlay_chrome151.csv" \
  "painted_glass/underlay_chrome147.csv underlay_chrome147.csv" \
  "painted_glass/focus_ring.csv focus_ring.csv" \
  "painted_mix/chrome151_tokens.csv chrome151_tokens.csv" \
  "painted_mix/chrome147_tokens.csv chrome147_tokens.csv"; do
  read -r fixture painted <<<"$pair"
  if [ ! -f "$out/$painted" ]; then
    echo "== $fixture: NOT PAINTED ($out/$painted missing)"
    status=1
    continue
  fi
  d=$(diff <(grep -v '^#' "$fixtures/$fixture") <(grep -v '^#' "$out/$painted"))
  rows=$(grep -vc '^#' "$fixtures/$fixture")
  n=$(printf '%s' "$d" | grep -c '^[<>]')
  echo "== $fixture: $rows lines, $n differing lines"
  if [ -n "$d" ]; then
    printf '%s\n' "$d"
    status=1
  fi
done
exit $status
