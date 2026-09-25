# shellcheck shell=bash
# Shared helpers for the throwaway-VM proof scripts (ADR 0053). Sourced, not run.
#
# Naming rule: every resource these scripts create carries the --name id, and
# the workdir path must contain it too, so one filter (`--filter name=<id>`)
# finds all of it and vm-down.sh can never remove a directory it did not make.

# Used by vm-exec.sh, which sources this file.
# shellcheck disable=SC2034
PROOF_GUEST_USER=ubuntu

die() {
  echo "error: $*" >&2
  exit 2
}

check_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{3,40}$ ]] || die "--name must match [a-z0-9][a-z0-9-]{3,40}: '$1'"
}

check_workdir() {
  local name=$1 workdir=$2
  [[ "$workdir" == /* ]] || die "--workdir must be absolute: '$workdir'"
  [[ "$workdir" == *"$name"* ]] || die "--workdir must contain the --name id '$name': '$workdir'"
}

check_port() {
  if ! [[ "$1" =~ ^[0-9]+$ ]] || (($1 < 1024 || $1 > 65535)); then
    die "port must be 1024-65535: '$1'"
  fi
}

# Print a command line, shell-quoted, prefixed with '+ '.
show() {
  local out="+" arg
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=,@+%*|\>-]+$ ]]; then out+=" $arg"; else out+=" $(printf '%q' "$arg")"; fi
  done
  echo "$out"
}

# state.env holds only non-secret run parameters (name, ports, tags).
state_file() { echo "$1/state.env"; }

load_state() {
  local file
  file=$(state_file "$1")
  [[ -r "$file" ]] || die "no state file $file (was vm-up.sh run with this --workdir?)"
  # shellcheck disable=SC1090
  source "$file"
}
