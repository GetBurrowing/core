#!/bin/sh
# A stand-in for the harness CLIs `agent.oneshot` runs (oneshot.ts): Claude
# Code's `auth status --json` and `-p --output-format json`, and Codex's
# `login status`. Test only.
#
# The child's env is built from nothing (`env -i`), so the stub is configured
# by files under $HOME/.stub/ and records what it saw under
# $HOME/.stub/record/:
#   auth          what `claude auth status --json` prints (default: logged in, claude.ai, max)
#   mode          normal | slow (sleeps 30 s) | not_logged_in (an is_error result)
#   codex_login   what `codex login status` prints (exit 1 when it says Not logged in)
#   record/argv   one argument per line, record/env, record/stdin, record/cwd
set -u
STUB="$HOME/.stub"
REC="$STUB/record"
mkdir -p "$REC"
mode=$(cat "$STUB/mode" 2>/dev/null || echo normal)

case "${1:-} ${2:-}" in
"auth status")
  if [ -f "$STUB/auth" ]; then
    cat "$STUB/auth"
    grep -q '"loggedIn":false' "$STUB/auth" && exit 1
    exit 0
  fi
  printf '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"owner@example.com","subscriptionType":"max"}\n'
  exit 0
  ;;
"login status")
  out=$(cat "$STUB/codex_login" 2>/dev/null || echo "Not logged in")
  echo "$out"
  case "$out" in *"Not logged in"*) exit 1 ;; esac
  exit 0
  ;;
esac

if [ "${1:-}" = "-p" ]; then
  : > "$REC/argv"
  for a in "$@"; do printf '%s\n' "$a" >> "$REC/argv"; done
  env > "$REC/env"
  cat > "$REC/stdin"
  pwd > "$REC/cwd"
  persist=yes
  for a in "$@"; do [ "$a" = "--no-session-persistence" ] && persist=no; done
  if [ "$persist" = yes ]; then
    mkdir -p "$HOME/.claude/projects/stub"
    echo '{"session":"stub"}' > "$HOME/.claude/projects/stub/session.jsonl"
  fi
  echo "scratch" > ./scratch-file
  if [ "$mode" = slow ]; then sleep 30; fi
  if [ "$mode" = not_logged_in ]; then
    printf '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}\n'
    exit 1
  fi
  printf '{"type":"result","subtype":"success","is_error":false,"result":"{\\"ok\\":true}","usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":7}}\n'
  exit 0
fi
echo "stub: unsupported: $*" >&2
exit 2
