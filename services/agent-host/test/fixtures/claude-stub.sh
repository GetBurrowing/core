#!/bin/sh
# A stand-in for Claude Code 2.1.295's `claude auth ...`, shaped like the
# measured transcript (claude-auth-login-2.1.295.txt). Test only.
#
# The login child's env is built from nothing (claude_login.ts `env -i`), so
# the stub is configured by files under $HOME/.stub/, never by env:
#   good_sha  sha256 of the one code that logs in (the code itself is never
#             written anywhere, so a scan of HOME for it means a leak)
#   plan      subscriptionType written on a good code (default max)
#   mode      normal | hang (never ends after reading a code) | nourl |
#             badurl (prints a non-claude sign-in URL)
set -u
STUB="$HOME/.stub"
AUTH="$HOME/.claude/stub-auth.json"
mode=$(cat "$STUB/mode" 2>/dev/null || echo normal)
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

case "${1:-} ${2:-}" in
"auth login")
  echo "stub-stderr-transcript-marker" >&2
  if [ "$mode" = nourl ]; then sleep 60; exit 1; fi
  echo "Opening browser to sign in…"
  if [ "$mode" = badurl ]; then
    echo "If the browser didn't open, visit: https://claude.com.attacker.invalid/cai/oauth/authorize?code=true&state=STUBSTATE"
  else
    echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=stub-client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=STUBCHALLENGE&code_challenge_method=S256&state=STUBSTATE"
  fi
  while :; do
    printf 'Paste code here if prompted > '
    IFS= read -r line || { sleep 60; exit 1; }
    case "$line" in
    *'#'*) ;;
    *) echo "Invalid code. Please make sure the full code was copied."; continue ;;
    esac
    if [ "$mode" = hang ]; then sleep 60; exit 1; fi
    if [ "$(printf '%s' "$line" | sha)" = "$(cat "$STUB/good_sha" 2>/dev/null)" ]; then
      mkdir -p "$HOME/.claude"
      plan=$(cat "$STUB/plan" 2>/dev/null || echo max)
      printf '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"owner@example.com","subscriptionType":"%s"}\n' "$plan" > "$AUTH"
      echo "Login successful."
      exit 0
    fi
    echo "Login failed: Request failed with status code 400"
    exit 1
  done
  ;;
"auth status")
  if [ -f "$AUTH" ]; then cat "$AUTH"; exit 0; fi
  printf '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}\n'
  exit 1
  ;;
"auth logout")
  rm -f "$AUTH"
  echo "Successfully logged out from your Anthropic account."
  exit 0
  ;;
esac
echo "stub: unsupported: $*" >&2
exit 2
