#!/usr/bin/env bash
# Start the Suite dev server with the env expected by local integrations.
#
# Usage:
#   scripts/dev.sh                 # bind to localhost only
#   PHX_BIND_IP=0.0.0.0 scripts/dev.sh    # LAN-reachable
#
# Optional env (override externally or via shell rc):
#   DATABASE_URL          defaults to local postgres
#   LIVEKIT_URL           LiveKit server this instance talks to
#   LIVEKIT_API_KEY       LiveKit API key
#   LIVEKIT_API_SECRET    LiveKit API secret
#   MEETING_AGENT_TOKEN   Shared secret the meeting-transcriber uses
#                         when POSTing to /api/meetings/segments
#
# The token and LiveKit creds live in your local shell/keychain, not here.
# This script only enforces defaults and routing; secrets are passed through.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root/apps/platform"

: "${DATABASE_URL:=postgres://postgres:postgres@127.0.0.1/platform_dev}"
: "${PHX_BIND_IP:=0.0.0.0}"

export DATABASE_URL PHX_BIND_IP
[[ -n "${LIVEKIT_URL:-}" ]] && export LIVEKIT_URL
[[ -n "${LIVEKIT_API_KEY:-}" ]] && export LIVEKIT_API_KEY
[[ -n "${LIVEKIT_API_SECRET:-}" ]] && export LIVEKIT_API_SECRET
[[ -n "${MEETING_AGENT_TOKEN:-}" ]] && export MEETING_AGENT_TOKEN

missing=()
[[ -z "${LIVEKIT_URL:-}" ]] && missing+=("LIVEKIT_URL")
[[ -z "${LIVEKIT_API_KEY:-}" ]] && missing+=("LIVEKIT_API_KEY")
[[ -z "${LIVEKIT_API_SECRET:-}" ]] && missing+=("LIVEKIT_API_SECRET")
[[ -z "${MEETING_AGENT_TOKEN:-}" ]] && missing+=("MEETING_AGENT_TOKEN")

if ((${#missing[@]} > 0)); then
  echo "warning: the following env vars are unset — meeting/LiveKit integrations will not work:"
  printf '  - %s\n' "${missing[@]}"
  echo
fi

exec mix phx.server
