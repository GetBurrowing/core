#!/bin/bash
# Public-IP watcher for LiveKit media (task 01a0d6ab stage 4). Meetings with
# [meetings] media_reach = "public" only; run every 5 minutes by a user
# LaunchAgent that `burrow_install setup run ddns` installs.
#
# Usage: ip-watch.sh <install dir> <zone id|-> <media host|-> <token ref|->
#   token ref: file:<path of a 0600 file> | keychain:<service>:<item>
#
# On a change of this network's public IP it:
# 1. restarts the livekit container: LiveKit learns its external IP by STUN
#    only at boot, so this is the load-bearing half;
# 2. if a media host is given, points that DNS-only (grey-cloud) A record at
#    the new IP through Cloudflare's API.
# The web, auth and signalling hostnames need none of this: they ride the
# outbound tunnel. The token never reaches a command line: curl reads its
# Authorization header from a config on stdin (-K -).
set -euo pipefail

install_dir=${1:?install dir}
zone_id=${2:--}
media_host=${3:--}
token_ref=${4:--}
state_file="$install_dir/.setup/public-ip"
api="https://api.cloudflare.com/client/v4"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ip=$(curl -fsS --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' || true)
if [ -z "$ip" ]; then
  echo "$(ts) no public IP (offline?); nothing changed"
  exit 0
fi
old=$(cat "$state_file" 2>/dev/null || true)
if [ "$ip" = "$old" ]; then
  exit 0
fi
mkdir -p "$(dirname "$state_file")"
echo "$(ts) public IP changed (${old:-none} -> $ip)"

if [ -n "$old" ]; then
  docker compose --project-directory "$install_dir" -f "$install_dir/compose.yaml" restart livekit
  echo "$(ts) restarted livekit"
fi

if [ "$media_host" != "-" ] && [ "$zone_id" != "-" ] && [ "$token_ref" != "-" ]; then
  case "$token_ref" in
    file:*) token=$(cat "${token_ref#file:}") ;;
    keychain:*)
      rest=${token_ref#keychain:}
      token=$(security find-generic-password -s "${rest%%:*}" -a "${rest#*:}" -w)
      ;;
    *) echo "$(ts) unknown token ref kind" >&2; exit 1 ;;
  esac
  cf() { printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS --max-time 20 -K - "$@"; }
  record_id=$(cf "$api/zones/$zone_id/dns_records?type=A&name=$media_host" |
    grep -o '"id":"[0-9a-f]\{32\}"' | head -1 | cut -d'"' -f4 || true)
  body="{\"type\":\"A\",\"name\":\"$media_host\",\"content\":\"$ip\",\"proxied\":false,\"ttl\":60}"
  if [ -n "$record_id" ]; then
    cf -X PUT -H 'Content-Type: application/json' --data "$body" \
      "$api/zones/$zone_id/dns_records/$record_id" >/dev/null
    echo "$(ts) updated A $media_host"
  else
    cf -X POST -H 'Content-Type: application/json' --data "$body" \
      "$api/zones/$zone_id/dns_records" >/dev/null
    echo "$(ts) created A $media_host"
  fi
fi
printf '%s\n' "$ip" >"$state_file"
