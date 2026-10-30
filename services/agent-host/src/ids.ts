/**
 * Names derived from an agent id. Pure.
 *
 * WHY THE SHORT ID IS THE TAIL, NOT THE HEAD. Agent ids are UUIDv7: the first
 * 12 hex digits are a millisecond clock. Two agents created a minute apart
 * share their first 8 hex digits, so `agent-<first 8>` would name the SAME OS
 * user for both, which is exactly the crossing per-agent users exist to stop.
 * The last 12 hex digits are random.
 */
import { createHash } from "node:crypto";
import { basename } from "node:path";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isAgentId(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

/** The random tail of the id: 12 hex digits. */
export function shortId(agentId: string): string {
  if (!isAgentId(agentId)) throw new Error("not an agent id");
  return agentId.slice(-12);
}

/** `agent-<12 hex>`: 18 characters, inside Linux's 32-character limit. */
export function userName(agentId: string): string {
  return `agent-${shortId(agentId)}`;
}

export const AGENTS_GROUP = "burrow-agents";
export const HOME_ROOT = "/home";
export const ENV_DIR = "/etc/burrow-agents";
export const RUN_DIR = "/run/burrow-agents";
export const UNIT_DIR = "/etc/systemd/system";
export const UNIT_TEMPLATE = "burrow-agent@.service";

/**
 * The tmux session `suite claude` is told to use. suite-cli owns this name, so
 * it stays until core pins a 0.9 CLI (docs/runbooks/burrow-rename-deferred.md).
 */
export const SESSION = "suite-agent";

export function homeDir(agentId: string): string {
  return `${HOME_ROOT}/${userName(agentId)}`;
}

export function workDir(agentId: string): string {
  return `${homeDir(agentId)}/work`;
}

export function envFile(agentId: string): string {
  return `${ENV_DIR}/${agentId}.env`;
}

/** The agent's private runtime dir, 0700: its tmux server's socket lives under it. */
export function runDir(agentId: string): string {
  return `${RUN_DIR}/${agentId}`;
}

export function unitName(agentId: string): string {
  return `burrow-agent@${agentId}.service`;
}

export function dropInDir(agentId: string): string {
  return `${UNIT_DIR}/${unitName(agentId)}.d`;
}

/** What burrow-cli's status file for this agent's session is called (`<state>/burrow/sessions`, 0.10.1+). */
export function statusFile(agentId: string): string {
  return `${homeDir(agentId)}/.local/state/burrow/sessions/${SESSION}.status.json`;
}

/**
 * suite-cli's per-folder connection key (src/agent_connections.ts `agentKey`):
 * `<sanitized basename>-<sha256(canonical dir)[0:16]>`, with tmux's session
 * sanitising (src/tmux.ts `sanitizeSessionName`). The work dir is created
 * before this is used and contains no symlink, so its canonical form is
 * itself.
 */
export function connectionKey(dir: string): string {
  const cleaned = basename(dir)
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
  const name = cleaned === "" ? "session" : cleaned;
  return `${name}-${createHash("sha256").update(dir).digest("hex").slice(0, 16)}`;
}

const RUNTIME_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;

export function isRuntimeId(value: unknown): value is string {
  return typeof value === "string" && RUNTIME_ID.test(value);
}

const ENV_NAME = /^[A-Z_][A-Z0-9_]{0,63}$/;

/** Names core may set in an agent's env file. A reserved name is refused. */
export function isAgentEnvName(value: unknown): value is string {
  return typeof value === "string" && ENV_NAME.test(value) && !RESERVED_ENV.has(value);
}

// The unit sets BURROW_AGENT_ID, BURROW_AGENT_SESSION and BURROW_UNATTENDED,
// and systemd lets EnvironmentFile= override Environment=, so an
// owner-supplied entry would win. Reserve all three.
const RESERVED_ENV = new Set([
  "HOME",
  "USER",
  "PATH",
  "SHELL",
  "TMUX",
  "TMUX_TMPDIR",
  "BURROW_AGENT_ID",
  "BURROW_AGENT_SESSION",
  "BURROW_UNATTENDED",
  "LD_PRELOAD",
  "LD_LIBRARY_PATH",
]);
