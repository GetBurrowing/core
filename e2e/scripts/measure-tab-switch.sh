#!/usr/bin/env bash
# Runner for measure-tab-switch.mjs (task 01a17b00 stage 1). Measures
# tab-switch time-to-interactive, join-reply bytes and wire bytes per app tab.
#
# LOCAL (dev server on this machine, seeded with
# apps/platform/priv/scripts/seed_tab_switch_fixture.exs). Start the server as
# a named node so the dev-only probe can be loaded into it:
#
#   cd apps/platform
#   PLATFORM_DEV_DATABASE=platform_dev_<task> PORT=<port> MIX_ENV=dev \
#     elixir --name <node>@127.0.0.1 --cookie "$(cat <cookie-file>)" -S mix phx.server
#
#   e2e/scripts/measure-tab-switch.sh --base-url http://localhost:<port> \
#     --login-as tabswitch --node <node>@127.0.0.1 --cookie-file <cookie-file> \
#     --out <results.json> [--tabs chat,tasks] [--taps 10] [--tasks-scenario S1]
#
# EXP (TLS, an account a human provided): no proxy and no probe. Sign in once
# with that account to produce a Playwright storage-state file, then:
#
#   e2e/scripts/measure-tab-switch.sh --base-url https://<exp> --no-proxy \
#     --auth-state <state.json> --label exp --out <results.json>
#
# Wire bytes on exp are an ESTIMATE (deflate of the captured frames), and
# server time is reported as unavailable.
#
# Exit codes: 0 ok, 1 harness failure, 2 usage, 3 rig fault (server or
# assets not answering; not a measurement).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
e2e="$(dirname "$here")"

base_url=""; pass=(); timebox_s=3900
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) base_url="${2:-}"; pass+=("$1" "${2:-}"); shift 2 ;;
    --node) pass+=(--probe-node "${2:-}"); shift 2 ;;
    --timebox-s) timebox_s="${2:-}"; shift 2 ;;
    --no-proxy|--headed) pass+=("$1"); shift ;;
    --out|--auth-state|--cookie-file)
      # The driver runs from e2e/, so a relative path is resolved here.
      p="${2:-}"; case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
      pass+=("$1" "$p"); shift 2 ;;
    --login-as|--tabs|--taps|--viewport|--chrome-port|--busy-slug|--label|--tasks-scenario|--server-log-level)
      pass+=("$1" "${2:-}"); shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 2 ;;
    *) echo "measure-tab-switch: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$base_url" ] || { echo "measure-tab-switch: --base-url is required" >&2; exit 2; }
base_url="${base_url%/}"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$base_url/assets/js/app.js" || echo 000)"
if [ "$code" != "200" ]; then
  echo "measure-tab-switch: rig fault: $base_url/assets/js/app.js returned $code; not a measurement" >&2
  exit 3
fi

[ -d "$e2e/node_modules/playwright" ] || { echo "measure-tab-switch: run 'npm ci' in e2e/ first" >&2; exit 3; }

cd "$e2e"
# macOS has no coreutils `timeout`; perl's alarm is the portable timebox.
perl -e 'alarm shift; exec @ARGV' "$timebox_s" node "$here/measure-tab-switch.mjs" "${pass[@]}"
status=$?
[ $status -eq 142 ] && echo "measure-tab-switch: timebox of ${timebox_s}s reached" >&2
exit $status
