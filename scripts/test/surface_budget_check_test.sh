#!/bin/sh
# Self-test for scripts/check-surface-budget.sh.
#
# Proves the ratchet in BOTH directions:
#   1. under budget            -> exit 0
#   2. one file over budget    -> exit 1, names that file
#   3. lines SHUFFLED between the two files so each is individually under
#      budget but the combined total is over -> exit 1 via the SUM line.
#
# Case 3 is the one that matters: without it, the ratchet is defeatable by
# moving code from the .ex into the .heex.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scripts_dir=$(dirname "$script_dir")
CHECK="$scripts_dir/check-surface-budget.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0

gen() { # gen <path> <lines>
  mkdir -p "$(dirname "$tmp/$1")"
  i=0
  : > "$tmp/$1"
  while [ "$i" -lt "$2" ]; do
    echo "line $i" >> "$tmp/$1"
    i=$((i + 1))
  done
}

budgets() { # budgets <a_max> <b_max> <sum_max>
  cat > "$tmp/budgets.txt" <<EOF
# fixture
a.ex $1
b.heex $2
SUM:fixture $3
EOF
}

run() {
  SURFACE_BUDGET_ROOT="$tmp" SURFACE_BUDGET_FILE="$tmp/budgets.txt" "$CHECK" 2>&1
}

expect() { # expect <name> <want_status> [must_contain]
  set +e
  out=$(run)
  status=$?
  set -e
  if [ "$status" -ne "$2" ]; then
    echo "FAIL: $1 -- expected exit $2, got $status"
    echo "$out" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  if [ "$#" -ge 3 ] && ! printf '%s\n' "$out" | grep -q "$3"; then
    echo "FAIL: $1 -- output missing '$3'"
    echo "$out" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  echo "PASS: $1 (exit $status)"
}

# 1. Both under budget, sum under budget.
budgets 100 100 200
gen a.ex 50
gen b.heex 50
expect "under budget passes" 0 "All surface budgets satisfied"

# 2. a.ex over its own budget.
gen a.ex 101
expect "single file over budget fails" 1 "Surface budget exceeded for a.ex: budget 100 lines, actual 101 lines"

# 3. Shuffle: each file individually under budget, combined over budget.
budgets 150 150 200
gen a.ex 120
gen b.heex 120
expect "shuffled lines still trip the SUM line" 1 "Surface budget exceeded for fixture (combined): budget 200 lines, actual 240 lines"

# 4. A budgeted file that does not exist is an error, not a silent pass.
budgets 100 100 200
rm -f "$tmp/b.heex"
gen a.ex 10
expect "missing budgeted file fails" 1 "Budgeted file missing: b.heex"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed."
  exit 1
fi

echo "surface_budget_check_test.sh: all checks passed."
