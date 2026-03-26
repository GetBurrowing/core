#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/platform"
RUN_DIR="${RUN_DIR:-${TMPDIR:-/tmp}/startup-suite-task-lifecycle-proof}"
PHOENIX_LOG="$RUN_DIR/phoenix.log"
GATEWAY_LOG="$RUN_DIR/gateway.log"
PHOENIX_PID_FILE="$RUN_DIR/phoenix.pid"
GATEWAY_PID_FILE="$RUN_DIR/gateway.pid"

DATABASE_URL="${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1/platform_dev}"
APP_URL="${APP_URL:-http://127.0.0.1:4000}"
PORT="${PORT:-4000}"
PHX_BIND_IP="${PHX_BIND_IP:-127.0.0.1}"
AGENT_WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$HOME/.openclaw}"
PROOF_OPENCLAW_PROFILE="${PROOF_OPENCLAW_PROFILE:-suite-dev}"
PROOF_OPENCLAW_CONFIG_PATH="${PROOF_OPENCLAW_CONFIG_PATH:-$HOME/.openclaw-${PROOF_OPENCLAW_PROFILE}/openclaw.json}"
PROOF_OPENCLAW_GATEWAY_PORT="${PROOF_OPENCLAW_GATEWAY_PORT:-19001}"
PROOF_AGENT_AUTH_PATH="${PROOF_AGENT_AUTH_PATH:-$HOME/.openclaw-${PROOF_OPENCLAW_PROFILE}/agents/main/agent/auth-profiles.json}"

mkdir -p "$RUN_DIR"

log() {
  printf '[task-lifecycle-proof] %s\n' "$*"
}

require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$bin" >&2
    exit 1
  fi
}

is_listening() {
  local port="$1"
  /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"

  for _ in $(seq 1 "$attempts"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_log_line() {
  local file="$1"
  local pattern="$2"
  local attempts="${3:-60}"

  for _ in $(seq 1 "$attempts"); do
    if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

read_gateway_token() {
  python3 - "$PROOF_OPENCLAW_CONFIG_PATH" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data['gateway']['auth']['token'])
PY
}

normalize_proof_agent_model() {
  python3 - "$PROOF_OPENCLAW_CONFIG_PATH" "$PROOF_AGENT_AUTH_PATH" <<'PY'
import json, os, sys

config_path, auth_path = sys.argv[1], sys.argv[2]

with open(config_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

agents = data.setdefault('agents', {}).setdefault('list', [])
main_agent = next((agent for agent in agents if agent.get('id') == 'main'), None)
if main_agent is None:
    print('no-main-agent')
    raise SystemExit(0)

model = main_agent.setdefault('model', {})
primary = model.get('primary')
fallbacks = model.setdefault('fallbacks', [])

auth_profiles = {}
if os.path.exists(auth_path):
    try:
        with open(auth_path, 'r', encoding='utf-8') as f:
            auth_profiles = json.load(f)
    except Exception:
        auth_profiles = {}

providers = set()
for profile_name in (auth_profiles.get('profiles') or {}).keys():
    providers.add(str(profile_name).split(':', 1)[0])

if 'anthropic' in providers or not str(primary).startswith('anthropic/'):
    print('unchanged')
    raise SystemExit(0)

filtered_fallbacks = [m for m in fallbacks if not str(m).startswith('anthropic/')]
if 'openai-codex/gpt-5.4' not in filtered_fallbacks:
    filtered_fallbacks.insert(0, 'openai-codex/gpt-5.4')

model['primary'] = 'openai-codex/gpt-5.4'
model['fallbacks'] = filtered_fallbacks

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print('patched-codex-primary')
PY
}

require_bin python3
require_bin curl
require_bin openclaw
require_bin mix

if [[ ! -f "$PROOF_OPENCLAW_CONFIG_PATH" ]]; then
  printf 'OpenClaw config not found: %s\n' "$PROOF_OPENCLAW_CONFIG_PATH" >&2
  exit 1
fi

PROOF_MODEL_NORMALIZATION="$(normalize_proof_agent_model)"
case "$PROOF_MODEL_NORMALIZATION" in
  patched-codex-primary)
    log "Patched $PROOF_OPENCLAW_PROFILE main agent to Codex-first for local proof (no Anthropic auth found)"
    ;;
  unchanged)
    ;;
  no-main-agent)
    log "No main agent found in $PROOF_OPENCLAW_CONFIG_PATH; leaving model config untouched"
    ;;
  *)
    log "Model preflight result: $PROOF_MODEL_NORMALIZATION"
    ;;
esac

GATEWAY_TOKEN="$(read_gateway_token)"

if is_listening "$PORT"; then
  log "Phoenix already listening on :$PORT; leaving it alone"
else
  log "Starting Phoenix dev server on :$PORT"
  (
    cd "$APP_DIR"
    env \
      DATABASE_URL="$DATABASE_URL" \
      AGENT_WORKSPACE_PATH="$AGENT_WORKSPACE_PATH" \
      APP_URL="$APP_URL" \
      PORT="$PORT" \
      PHX_BIND_IP="$PHX_BIND_IP" \
      MIX_ENV=dev \
      nohup mix phx.server >"$PHOENIX_LOG" 2>&1 &
    echo $! >"$PHOENIX_PID_FILE"
  )
fi

if ! wait_for_http "$APP_URL" 90; then
  log "Phoenix failed to become ready. See $PHOENIX_LOG"
  exit 1
fi

if is_listening "$PROOF_OPENCLAW_GATEWAY_PORT"; then
  log "Isolated gateway already listening on :$PROOF_OPENCLAW_GATEWAY_PORT; leaving it alone"
else
  log "Starting isolated OpenClaw gateway on :$PROOF_OPENCLAW_GATEWAY_PORT (profile=$PROOF_OPENCLAW_PROFILE)"
  nohup \
    openclaw --profile "$PROOF_OPENCLAW_PROFILE" gateway run \
      --port "$PROOF_OPENCLAW_GATEWAY_PORT" \
      --token "$GATEWAY_TOKEN" \
      --verbose >"$GATEWAY_LOG" 2>&1 &
  echo $! >"$GATEWAY_PID_FILE"
fi

if ! wait_for_log_line "$GATEWAY_LOG" 'Joined runtime:' 90; then
  log "Gateway did not report a Suite runtime join. See $GATEWAY_LOG"
  exit 1
fi

log "Local proof stack is ready"
log "Phoenix: $APP_URL"
log "Gateway: ws://127.0.0.1:$PROOF_OPENCLAW_GATEWAY_PORT"
log "Phoenix log: $PHOENIX_LOG"
log "Gateway log: $GATEWAY_LOG"
