/**
 * Starting, stopping and observing native agents.
 *
 * On every start, in this order (files.ts writes step 5):
 *   1. the agent's OS user (users.ts), idempotently;
 *   2. AS THAT UID: suite-cli's connection record for the work dir and its
 *      credentials file (0600) carrying the runtime token core minted for
 *      this start — suite-cli 0.7.1+'s per-folder format
 *      (`~/.config/suite/agents/<key>.json` + `<key>.credentials.json`);
 *   3. the agent's env file, /etc/burrow-agents/<id>.env, 0600, owned by the
 *      agent, holding only that agent's values;
 *   4. the unit drop-in;
 *   5. AS THAT UID: the agent's own files (CLAUDE.md, .claude/settings.json,
 *      ...) into its work dir, and a root-owned record of their versions;
 *   6. AS THAT UID: Burrow's conventions as the agent's USER memory,
 *      `~/.claude/CLAUDE.md` (conventions.ts), which the owner's files cannot
 *      replace;
 *   7. `systemctl restart burrow-agent@<id>`.
 *
 * Files in an agent's home are written by a child running as the agent
 * (`runuser`), so a symlink the agent left in its own home can never redirect
 * a root write. Secrets reach that child on stdin, never in argv.
 */
import { chmodSync, chownSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Runner, SecretRegistry } from "./exec.ts";
import {
  ENV_DIR,
  UNIT_DIR,
  UNIT_TEMPLATE,
  connectionKey,
  dropInDir,
  envFile,
  isAgentEnvName,
  isAgentId,
  isRuntimeId,
  statusFile,
  unitName,
} from "./ids.ts";
import { dropIn, templateUnit } from "./units.ts";
import { ensureAgentUser, type AgentUser } from "./users.ts";
import { parseFiles, readApplied, recordApplied, writeAgentFiles, type AgentFile } from "./files.ts";
import { loadSuiteConventions, renderUserMemory, writeUserMemory } from "./conventions.ts";

export type ObservedState = "starting" | "running" | "stopped" | "crashed" | "needs_login";

export interface Observation {
  agent_id: string;
  state: ObservedState;
  detail: string | null;
  files_applied: unknown;
  /** Only for needs_login: what suite-cli's status file reported. */
  login?: { step: string; url?: string };
}

export interface StartCommand {
  agent_id: string;
  runtime_id: string;
  runtime_token: string;
  harness: string;
  core_url: string;
  env: Record<string, string>;
  /** The agent's own files, written into its work dir before the unit starts. Null: core sent none. */
  files: AgentFile[] | null;
}

export interface AgentsDeps {
  runner: Runner;
  secrets: SecretRegistry;
  /** The command the unit execs as the agent. */
  runnerCommand: string[];
  log(line: string): void;
  /** suite-cli's conventions text, or null. Defaults to {@link loadSuiteConventions}. */
  conventions?: () => Promise<string | null>;
}

/** Harnesses this host can run. Codex waits for `suite codex` support here. */
export const SUPPORTED_HARNESSES = new Set(["claude_code"]);

export function parseStart(payload: Record<string, unknown>): StartCommand | string {
  const { agent_id, runtime_id, runtime_token, harness, core_url, env, files } = payload;
  if (!isAgentId(agent_id)) return "agent_id is not an agent id";
  if (!isRuntimeId(runtime_id)) return "runtime_id is not a runtime id";
  if (typeof runtime_token !== "string" || runtime_token.length < 16) return "runtime_token missing";
  if (typeof harness !== "string") return "harness missing";
  if (typeof core_url !== "string" || !/^https?:\/\//.test(core_url)) return "core_url is not an http(s) URL";
  const cleanEnv: Record<string, string> = {};
  if (env !== undefined && env !== null) {
    if (typeof env !== "object" || Array.isArray(env)) return "env is not an object";
    for (const [k, v] of Object.entries(env as Record<string, unknown>)) {
      if (!isAgentEnvName(k)) return `env name ${k} is not allowed`;
      if (typeof v !== "string" || /[\n\r\0]/.test(v)) return `env ${k} is not a single-line string`;
      cleanEnv[k] = v;
    }
  }
  const parsedFiles = parseFiles(files);
  if (typeof parsedFiles === "string") return parsedFiles;
  return { agent_id, runtime_id, runtime_token, harness, core_url, env: cleanEnv, files: parsedFiles };
}

/** Write `content` to `path` as `user`, via a temp file and a rename. Content travels on stdin. */
export async function writeAsUser(runner: Runner, user: AgentUser, path: string, content: string, mode: string): Promise<void> {
  const script =
    'set -e; umask 077; mkdir -p "$(dirname "$1")"; tmp="$1.tmp.$$"; cat > "$tmp"; chmod "$2" "$tmp"; mv -f "$tmp" "$1"';
  const r = await runner.run(["runuser", "-u", user.name, "--", "/bin/sh", "-c", script, "sh", path, mode], { stdin: content });
  if (r.exitCode !== 0) throw new Error(`writing ${path} as ${user.name} failed: ${r.stderr.trim()}`);
}

/** `KEY=value` lines for systemd's EnvironmentFile. Values are single-quoted. */
export function renderEnvFile(agentId: string, env: Record<string, string>): string {
  const lines = ["# Managed by Suite's agent host. This agent's values only."];
  lines.push(`BURROW_AGENT_ID=${agentId}`);
  lines.push(`SUITE_AGENT_ID=${agentId}`);
  for (const [k, v] of Object.entries(env)) {
    lines.push(`${k}='${v.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`);
  }
  return `${lines.join("\n")}\n`;
}

/**
 * Root-owned directory, so the write cannot be redirected: temp file opened
 * exclusively, chowned to the agent, mode 0600, renamed into place.
 */
export function writeEnvFile(user: AgentUser, agentId: string, content: string): void {
  mkdirSync(ENV_DIR, { recursive: true, mode: 0o711 });
  chmodSync(ENV_DIR, 0o711);
  const path = envFile(agentId);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, content, { mode: 0o600, flag: "wx" });
  chownSync(tmp, user.uid, user.gid);
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

function writeIfChanged(path: string, content: string, mode: number): boolean {
  if (existsSync(path) && readFileSync(path, "utf8") === content) return false;
  mkdirSync(dirname(path), { recursive: true, mode: 0o755 });
  writeFileSync(path, content, { mode });
  chmodSync(path, mode);
  return true;
}

export async function installUnits(deps: AgentsDeps, agentId: string): Promise<void> {
  const changedTemplate = writeIfChanged(`${UNIT_DIR}/${UNIT_TEMPLATE}`, templateUnit(deps.runnerCommand), 0o644);
  const changedDropIn = writeIfChanged(`${dropInDir(agentId)}/10-agent.conf`, dropIn(agentId), 0o644);
  if (changedTemplate || changedDropIn) {
    const r = await deps.runner.run(["systemctl", "daemon-reload"]);
    if (r.exitCode !== 0) throw new Error(`systemctl daemon-reload failed: ${r.stderr.trim()}`);
  }
}

/** Stage everything an agent needs, as described above. Does not start the unit. */
export async function prepareAgent(deps: AgentsDeps, cmd: StartCommand): Promise<AgentUser> {
  deps.secrets.add(cmd.runtime_token);
  for (const v of Object.values(cmd.env)) deps.secrets.add(v);

  const user = await ensureAgentUser(deps.runner, cmd.agent_id);
  const key = connectionKey(user.work);
  const agentsDir = `${user.home}/.config/suite/agents`;
  const record = { dir: user.work, suiteUrl: cmd.core_url, runtimeId: cmd.runtime_id, headerNames: [] as string[] };
  await writeAsUser(deps.runner, user, `${agentsDir}/${key}.json`, `${JSON.stringify(record, null, 2)}\n`, "0600");
  await writeAsUser(
    deps.runner,
    user,
    `${agentsDir}/${key}.credentials.json`,
    `${JSON.stringify({ token: cmd.runtime_token, headers: {} }, null, 2)}\n`,
    "0600",
  );
  writeEnvFile(user, cmd.agent_id, renderEnvFile(cmd.agent_id, cmd.env));
  await installUnits(deps, cmd.agent_id);
  return user;
}

export async function startAgent(deps: AgentsDeps, cmd: StartCommand): Promise<void> {
  const user = await prepareAgent(deps, cmd);
  // The agent's files, as the agent, BEFORE the unit (and `suite claude`)
  // starts: the stored copy wins, and suite-cli writes CLAUDE.md only when
  // it is absent.
  if (cmd.files !== null) {
    const { applied, rejected } = await writeAgentFiles(deps.runner, user, cmd.files);
    for (const r of rejected) deps.log(`agent ${cmd.agent_id}: file ${JSON.stringify(r.key)} refused: ${r.reason}`);
    recordApplied(cmd.agent_id, applied);
  }
  await writeConventions(deps, user, cmd.agent_id);
  // restart, not start: a start command for a running agent carries a new
  // token, which only a fresh process picks up.
  const r = await deps.runner.run(["systemctl", "restart", unitName(cmd.agent_id)]);
  if (r.exitCode !== 0) throw new Error(`systemctl restart failed: ${r.stderr.trim()}`);
}

/**
 * Step 6: the conventions as user memory, on every start, whatever the owner's
 * files are (conventions.ts). claude_code is the only harness this host runs
 * (SUPPORTED_HARNESSES), and it reads `~/.claude/CLAUDE.md`.
 */
export async function writeConventions(deps: AgentsDeps, user: AgentUser, agentId: string): Promise<void> {
  const text = await (deps.conventions ?? loadSuiteConventions)();
  if (text === null) {
    deps.log(`agent ${agentId}: suite-cli's conventions could not be loaded; wrote the reply rule only`);
  }
  await writeUserMemory(deps.runner, user, renderUserMemory(text));
}

export async function stopAgent(deps: AgentsDeps, agentId: string): Promise<void> {
  await deps.runner.run(["systemctl", "stop", unitName(agentId)]);
  // A failed unit stays "failed" after a stop; clear it so it reads stopped.
  await deps.runner.run(["systemctl", "reset-failed", unitName(agentId)]);
}

export async function agentLogs(deps: AgentsDeps, agentId: string, lines: number): Promise<string[]> {
  const n = Math.max(1, Math.min(2000, Math.floor(lines)));
  const r = await deps.runner.run(["journalctl", "--unit", unitName(agentId), "--lines", String(n), "--no-pager", "--output", "cat"]);
  return r.stdout.split("\n").filter((l) => l !== "");
}

/** Agents this host knows: one env file each. */
export function knownAgents(): string[] {
  if (!existsSync(ENV_DIR)) return [];
  return readdirSync(ENV_DIR)
    .filter((f) => f.endsWith(".env"))
    .map((f) => f.slice(0, -".env".length))
    .filter(isAgentId);
}

interface UnitState {
  active: string;
  sub: string;
}

export function parseShow(stdout: string): UnitState {
  const m = new Map(stdout.split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)] as const));
  return { active: m.get("ActiveState") ?? "unknown", sub: m.get("SubState") ?? "" };
}

export interface PaneStatus {
  state?: string;
  login?: { step?: unknown; url?: unknown };
  dialog?: string;
  title?: string;
  reason?: string;
}

function readStatus(agentId: string): PaneStatus | null {
  try {
    // The file is in the agent's home: only a plain file is read, never
    // whatever a symlink there points at.
    if (!lstatSync(statusFile(agentId)).isFile()) return null;
    return JSON.parse(readFileSync(statusFile(agentId), "utf8")) as PaneStatus;
  } catch {
    return null;
  }
}

/**
 * True when suite-cli's status file says the agent is at a login SCREEN, so
 * its pane is withheld. A failed turn (`auth_error`, Claude's input box with
 * "Invalid API key" under the turn) is not a login screen: that pane is shown,
 * scrubbed like any other.
 */
export function statusSaysLogin(agentId: string): boolean {
  return loginScreenStatus(readStatus(agentId));
}

export function loginScreenStatus(status: PaneStatus | null): boolean {
  return status?.state === "needs_login" && status.login?.step !== "auth_error";
}

/**
 * The observed state, from the unit and suite-cli's status file:
 *
 *   unit failed                            crashed (it kept exiting without a stop)
 *   unit inactive                          stopped
 *   unit activating / auto-restart         starting
 *   unit active, status needs_login        needs_login
 *   unit active, status ready              running
 *   unit active, status stuck              crashed ("stuck: <what is on screen>")
 *   unit active, anything else             starting
 *
 * `stuck` is suite-cli's: its launch poll gave up without seeing Claude's
 * input box and the pane is still not usable (stage 7). It is terminal for
 * the person, so it reads as crashed, whose action is Restart, rather than
 * the `starting` it would otherwise be forever.
 */
export function observe(
  agentId: string,
  unit: UnitState,
  status: PaneStatus | null,
  filesApplied: Record<string, number> | null = null,
): Observation {
  const base = { agent_id: agentId, detail: null, files_applied: filesApplied };
  if (unit.active === "failed") return { ...base, state: "crashed", detail: "the agent kept exiting" };
  if (unit.active === "inactive" || unit.active === "unknown") return { ...base, state: "stopped" };
  if (unit.active !== "active") return { ...base, state: "starting", detail: unit.sub || null };
  if (status?.state === "needs_login") {
    const step = typeof status.login?.step === "string" ? status.login.step : "login";
    const url = typeof status.login?.url === "string" ? status.login.url : undefined;
    return { ...base, state: "needs_login", detail: step, login: url === undefined ? { step } : { step, url } };
  }
  if (status?.state === "ready") return { ...base, state: "running" };
  if (status?.state === "stuck") {
    const what = typeof status.reason === "string" && status.reason !== "" ? status.reason : "Claude's input box did not appear";
    return { ...base, state: "crashed", detail: `stuck: ${what}`.slice(0, 300) };
  }
  if (status?.state === "unknown_dialog") {
    return { ...base, state: "starting", detail: `waiting at an unrecognised screen: ${status.title ?? ""}`.trim() };
  }
  return { ...base, state: "starting", detail: status?.state ?? null };
}

export async function observeAgent(deps: AgentsDeps, agentId: string): Promise<Observation> {
  const r = await deps.runner.run(["systemctl", "show", unitName(agentId), "--property=ActiveState,SubState"]);
  return observe(agentId, parseShow(r.stdout), readStatus(agentId), readApplied(agentId));
}
