#!/usr/bin/env bash
# vm-exec.sh: run a command in the throwaway guest over ssh (key and port from
# the workdir vm-up.sh wrote). stdin is passed through, so files can be streamed:
#
#   vm-exec.sh --workdir <dir> -- <command...>
#   vm-exec.sh --workdir <dir> -- 'sudo docker load' < image.tar
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

workdir=""
while (($#)); do
  case "$1" in
  --workdir) workdir=$2; shift 2 ;;
  --) shift; break ;;
  -h | --help) sed -n '2,7p' "$0"; exit 0 ;;
  *) die "unknown argument '$1' (put the guest command after --)" ;;
  esac
done
[[ -n "$workdir" ]] || die "--workdir is required"
(($#)) || die "no guest command given"
load_state "$workdir"

exec ssh -q -i "$SSH_KEY" -p "$SSH_PORT" \
  -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$workdir/known_hosts" \
  "$PROOF_GUEST_USER@127.0.0.1" "$@"
