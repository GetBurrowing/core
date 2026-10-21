#!/usr/bin/env bash
# Task 01a15cfd: print the runner host's load and PSI as a GitHub notice and a
# step-summary line. The CI job container sees the host's /proc, so a
# first-pass mix test failure can be read against the runner host's load from
# the run alone. Usage: host-pressure.sh <label>, e.g. "before mix test".
# Informational only: always exits 0, and callers also append `|| true`.
#
# HOST_PRESSURE_PROC overrides the /proc root; it exists so the output can be
# checked against canned input. CI never sets it.
label="${1:-unlabelled}"
proc="${HOST_PRESSURE_PROC:-/proc}"
{
  psi() {
    local kind avg rest out=unavailable
    if [ -r "$proc/pressure/$1" ]; then
      while read -r kind avg rest; do
        [ "$kind" = some ] && out="${avg#avg10=}"
      done <"$proc/pressure/$1"
    fi
    echo "$out"
  }
  load1=unavailable
  [ -r "$proc/loadavg" ] && read -r load1 _ <"$proc/loadavg"
  line="load1=$load1 cpu_some10=$(psi cpu) io_some10=$(psi io) mem_some10=$(psi memory)"
  echo "::notice title=host pressure ($label)::$line"
  echo "host pressure ($label): $line" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
} || true
exit 0
