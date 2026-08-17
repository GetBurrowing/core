#!/bin/sh
# Surface line-count ratchet.
#
# Reads scripts/surface-budgets.txt (override with SURFACE_BUDGET_FILE) and
# compares each listed file's line count against its budget. Lines whose path
# is of the form SUM:<name> budget the SUM of every file entry seen since the
# previous SUM line -- this stops a surface from passing by shuffling lines
# out of one budgeted file and into another.
#
# Paths are resolved relative to SURFACE_BUDGET_ROOT (default: repo root).
# Exits 1 with a ::error:: annotation naming file, budget and actual on breach.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$script_dir")

BUDGET_FILE=${SURFACE_BUDGET_FILE:-"$script_dir/surface-budgets.txt"}
ROOT=${SURFACE_BUDGET_ROOT:-$repo_root}

if [ ! -f "$BUDGET_FILE" ]; then
  echo "::error::Surface budget file not found: $BUDGET_FILE"
  exit 1
fi

failed=0
running=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac

  path=$(printf '%s\n' "$line" | awk '{print $1}')
  budget=$(printf '%s\n' "$line" | awk '{print $2}')

  if [ -z "$path" ] || [ -z "$budget" ]; then
    echo "::error::Malformed line in $BUDGET_FILE: $line"
    failed=1
    continue
  fi

  case "$path" in
    SUM:*)
      name=${path#SUM:}
      if [ "$running" -gt "$budget" ]; then
        echo "::error::Surface budget exceeded for $name (combined): budget $budget lines, actual $running lines. Extract code into a module, or raise the budget in scripts/surface-budgets.txt with a justification in the commit message."
        failed=1
      else
        echo "ok: $name (combined) $running/$budget"
      fi
      running=0
      ;;
    *)
      if [ ! -f "$ROOT/$path" ]; then
        echo "::error::Budgeted file missing: $path (looked in $ROOT)"
        failed=1
        continue
      fi
      actual=$(wc -l < "$ROOT/$path" | tr -d ' ')
      running=$((running + actual))
      if [ "$actual" -gt "$budget" ]; then
        echo "::error::Surface budget exceeded for $path: budget $budget lines, actual $actual lines. Extract code into a module, or raise the budget in scripts/surface-budgets.txt with a justification in the commit message."
        failed=1
      else
        echo "ok: $path $actual/$budget"
      fi
      ;;
  esac
done < "$BUDGET_FILE"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "All surface budgets satisfied."
