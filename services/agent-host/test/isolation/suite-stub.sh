#!/bin/bash
# A stand-in for suite-cli in the isolation test container: it starts a tmux
# session the way `suite claude` does and answers `pane-status` the way
# suite-cli does, writing the same status file. Real Claude Code is not run.
#   /tmp/suite-stub-fail   `suite claude` creates no session (a crash loop)
#   /tmp/suite-stub-login  pane-status reports needs_login with a login URL
set -u
verb="${1:-}"
case "$verb" in
  claude)
    session=suite-agent
    if [ "${2:-}" = "--session" ]; then session="$3"; fi
    [ -e /tmp/suite-stub-fail ] && exit 0
    tmux new-session -d -s "$session" "sleep infinity"
    # The real verb ends by attaching, which fails without a terminal.
    exit 1
    ;;
  pane-status)
    session="$3"
    dir="$HOME/.local/state/suite/sessions"
    mkdir -p "$dir"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! tmux has-session -t "=$session" 2>/dev/null; then
      doc="{\"version\":1,\"session\":\"$session\",\"state\":\"gone\",\"observed_at\":\"$now\"}"
      code=1
    elif [ -e /tmp/suite-stub-login ]; then
      doc="{\"version\":1,\"session\":\"$session\",\"state\":\"needs_login\",\"login\":{\"step\":\"login_url\",\"url\":\"https://claude.com/cai/oauth/authorize?stub=1\"},\"observed_at\":\"$now\"}"
      code=0
    else
      doc="{\"version\":1,\"session\":\"$session\",\"state\":\"ready\",\"observed_at\":\"$now\"}"
      code=0
    fi
    umask 077
    printf '%s\n' "$doc" > "$dir/$session.status.json.tmp" && mv -f "$dir/$session.status.json.tmp" "$dir/$session.status.json"
    printf '%s\n' "$doc"
    exit "$code"
    ;;
  *)
    echo "suite-stub: unknown verb $verb" >&2
    exit 2
    ;;
esac
