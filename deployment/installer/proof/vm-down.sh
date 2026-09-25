#!/usr/bin/env bash
# vm-down.sh: remove everything vm-up.sh created for <id> and print the evidence.
#
#   vm-down.sh --name <id> --workdir <dir> [--https-port <p> --ssh-port <p>] [--dry-run]
#
# The evidence block runs TWICE: before removal (the positive control: each
# check should hit while the VM exists) and after (each should be empty).
# Exits non-zero if anything is left after removal.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

name="" workdir="" https_port="" ssh_port="" dry_run=0
while (($#)); do
  case "$1" in
  --name) name=$2; shift 2 ;;
  --workdir) workdir=$2; shift 2 ;;
  --https-port) https_port=$2; shift 2 ;;
  --ssh-port) ssh_port=$2; shift 2 ;;
  --dry-run) dry_run=1; shift ;;
  -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
  *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$name" && -n "$workdir" ]] || die "--name and --workdir are required"
check_name "$name"
check_workdir "$name" "$workdir"
if [[ -z "$https_port" || -z "$ssh_port" ]] && [[ -r "$(state_file "$workdir")" ]]; then
  load_state "$workdir"
  https_port=${https_port:-$HTTPS_PORT}
  ssh_port=${ssh_port:-$SSH_PORT}
fi

container="vm-$name" prep="vmprep-$name" tag="localhost/vmhost-$name"

if ((dry_run)); then
  show podman rm -f --ignore "$container" "$prep"
  show podman rmi --ignore "$tag"
  show rm -rf -- "$workdir"
  exit 0
fi

# Prints one labelled block per check; returns the number of checks that hit.
evidence() {
  local hits=0 out p
  check() {
    local label=$1
    shift
    out=$("$@" 2>/dev/null || true)
    echo "\$ $label"
    if [[ -n "$out" ]]; then
      echo "$out"
      hits=$((hits + 1))
    else
      echo "(empty)"
    fi
  }
  check "podman ps -a --filter name=$name" podman ps -a --noheading --filter "name=$name"
  check "podman images --filter reference='*$name*'" \
    podman images --noheading --filter "reference=*$name*"
  check "ls -d $workdir" ls -d "$workdir"
  for p in $https_port $ssh_port; do
    check "ss -ltnH 'sport = :$p'" ss -ltnH "sport = :$p"
  done
  # This script's own command line carries the id; drop it and its callers.
  check "pgrep -af $name (excluding vm-down.sh)" \
    sh -c "pgrep -af -- '$name' | grep -v -e 'vm-down.sh' -e 'pgrep -af'"
  return "$hits"
}

echo "== before removal (positive control: expect hits)"
evidence && before=0 || before=$?
echo "checks that hit: $before"

echo "== removing"
podman rm -f --ignore "$container" "$prep" >/dev/null
podman rmi --ignore "$tag" >/dev/null
rm -rf -- "$workdir"

echo "== after removal (expect every check empty)"
evidence && after=0 || after=$?
echo "checks that hit: $after"
((after == 0)) || die "$after check(s) still hit after teardown"
echo "vm-down: nothing named $name remains"
