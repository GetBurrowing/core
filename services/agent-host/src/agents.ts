/**
 * Starting, stopping and observing native agents.
 *
 * On every start, in this order (files.ts writes step 5):
 *   1. the agent's OS user (users.ts), idempotently;
 *   2. AS THAT UID: burrow-cli's connection record for the work dir and its
 *      credentials file (0600) carrying the runtime token core minted for
 *      this start, in burrow-cli's per-folder format
 *      (`~/.config/burrow/agents/<key>.json` + `<key>.credentials.json`), and
 *      the token refreshed in the burrow MCP entries `~/.claude.json` already
 *      holds for the work dir (see {@link writeConnection});
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
  userName,
  workDir,
} from "./ids.ts";
import { dropIn, templateUnit } from "./units.ts";
import { ensureAgentUser, type AgentUser } from "./users.ts";
import {
  detectDrift,
  isFileKey,
  parseFiles,
  readApplied,
  readShas,
  recordApplied,
  recordShas,
  writeAgentFiles,
  type AgentFile,
  type FilesShas,
} from "./files.ts";
import { loadBurrowConventions, renderUserMemory, writeUserMemory } from "./conventions.ts";

export type ObservedState = "starting" | "running" | "stopped" | "crashed" | "needs_login";

export interface Observation {
  agent_id: string;
  state: ObservedState;
  detail: string | null;
  files_applied: unknown;
  /** Keys the agent changed on disk since the host wrote them. Absent: not checked. */
  files_drifted?: string[];
  /**
   * Only for needs_login: the step suite-cli's status file named, and nothing
   * else. Never a login URL or code (core task 01a17b10): Burrow does not
   * relay a Claude login; a human logs in at the agent's own pane.
   */
  login?: { step: string };
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
  /** Drifted keys core says to overwrite (the owner resolved them). */
  force_keys: string[];
}

export interface AgentsDeps {
  runner: Runner;
  secrets: SecretRegistry;
  /** The command the unit execs as the agent. */
  runnerCommand: string[];
  log(line: string): void;
  /** suite-cli's conventions text, or null. Defaults to {@link loadBurrowConventions}. */
  conventions?: () => Promise<string | null>;
}

/** Harnesses this host can run. Codex waits for `suite codex` support here. */
export const SUPPORTED_HARNESSES = new Set(["claude_code"]);

export function parseStart(payload: Record<string, unknown>): StartCommand | string {
  const { agent_id, runtime_id, runtime_token, harness, core_url, env, files, force_keys } = payload;
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
  let forceKeys: string[] = [];
  if (force_keys !== undefined && force_keys !== null) {
    if (!Array.isArray(force_keys) || !force_keys.every(isFileKey)) return "force_keys is not a list of file keys";
    forceKeys = force_keys as string[];
  }
  return { agent_id, runtime_id, runtime_token, harness, core_url, env: cleanEnv, files: parsedFiles, force_keys: forceKeys };
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

/**
 * Where burrow-cli (0.9.0+) reads an agent folder's connection:
 * `<config>/burrow/agents`. The pre-0.9.0 `<config>/suite/agents` is read by
 * burrow-cli only until its one-shot migration has run, so a record written
 * there afterwards is never read, and the token core rotated on every start
 * after the first never reached the agent. Nothing here writes the old dir.
 */
export function burrowAgentsDir(user: Pick<AgentUser, "home">): string {
  return `${user.home}/.config/burrow/agents`;
}

/** burrow-cli's MCP server ids (init.ts CHANNEL_SERVER, TOOLS_SERVER), registered at local scope. */
export const CHANNEL_SERVER = "burrow-channel";
export const TOOLS_SERVER = "burrow";

/** Record fields burrow-cli sets itself and a start keeps (agent_connections.ts AgentRecord). */
const KEPT_RECORD_FIELDS = ["configAccess", "remoteTerminal"] as const;

/**
 * The record burrow-cli reads (agent_connections.ts serializeAgentRecord):
 * `{dir, burrowUrl, runtimeId, headerNames}`, keeping only the fields
 * burrow-cli itself sets on the folder. Never `suiteUrl` (a record holding
 * both is refused by name) and never `tokenEnv`/`tokenRef`/`keychainService`,
 * which would make burrow-cli read the token from somewhere other than the
 * credentials file written beside it.
 */
export function renderAgentRecord(existing: string | null, dir: string, burrowUrl: string, runtimeId: string): string {
  const out: Record<string, unknown> = { dir, burrowUrl, runtimeId, headerNames: [] };
  const prior = parseObject(existing);
  if (prior !== null && prior.dir === dir) {
    for (const f of KEPT_RECORD_FIELDS) if (typeof prior[f] === "string" && prior[f] !== "") out[f] = prior[f];
  }
  return `${JSON.stringify(out, null, 2)}\n`;
}

function parseObject(text: string | null): Record<string, unknown> | null {
  if (text === null) return null;
  try {
    const v = JSON.parse(text) as unknown;
    return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** `sh -c READ_HOME_FILE sh PATH`: the file's bytes; exit 4 when absent, 3 when a symlink or not a plain file. */
const READ_HOME_FILE =
  'set -eu; if [ -L "$1" ]; then echo "is a symlink" >&2; exit 3; fi; [ -e "$1" ] || exit 4; [ -f "$1" ] || { echo "not a file" >&2; exit 3; }; cat -- "$1"';

/** A file in the agent's home, read AS THE AGENT. Null when absent; throws when it cannot be read. */
export async function readAsUser(runner: Runner, user: Pick<AgentUser, "name">, path: string): Promise<string | null> {
  const r = await runner.run(["runuser", "-u", user.name, "--", "/bin/sh", "-c", READ_HOME_FILE, "sh", path]);
  if (r.exitCode === 0) return r.stdout;
  if (r.exitCode === 4) return null;
  throw new Error(`reading ${path} as ${user.name} failed: ${r.stderr.trim() || `exit ${r.exitCode}`}`);
}

const ENV_REFERENCE = /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/;

/** True when `key` is `work` or one of its ancestors: the project keys Claude can file a folder's local entries under. */
function coversWork(key: string, work: string): boolean {
  if (key === work) return true;
  const base = key.endsWith("/") ? key : `${key}/`;
  return work.startsWith(base);
}

/**
 * `~/.claude.json` with the runtime token in burrow-cli's two local-scope
 * entries for `work` set to `token`, or null when nothing changes (or the
 * file is not JSON). Touches ONLY `burrow-channel`'s `*_TOKEN` env values and
 * `burrow`'s `Authorization` header, under project keys covering `work`; an
 * env reference (`${VAR}`) is left as it is. An entry that is absent stays
 * absent: burrow-cli adds it, with the token from the credentials file.
 */
export function refreshedClaudeJson(text: string, work: string, token: string): string | null {
  const raw = parseObject(text);
  if (raw === null) return null;
  const projects = raw.projects;
  if (typeof projects !== "object" || projects === null || Array.isArray(projects)) return null;
  let changed = false;
  for (const [key, project] of Object.entries(projects as Record<string, unknown>)) {
    if (!coversWork(key, work)) continue;
    const servers = (project as { mcpServers?: unknown } | null)?.mcpServers;
    if (typeof servers !== "object" || servers === null) continue;
    const channel = (servers as Record<string, unknown>)[CHANNEL_SERVER] as { env?: Record<string, unknown> } | undefined;
    if (channel?.env !== undefined && typeof channel.env === "object" && channel.env !== null) {
      for (const name of ["BURROW_TOKEN"]) {
        const v = channel.env[name];
        if (typeof v === "string" && !ENV_REFERENCE.test(v) && v !== token) {
          channel.env[name] = token;
          changed = true;
        }
      }
    }
    const tools = (servers as Record<string, unknown>)[TOOLS_SERVER] as { headers?: Record<string, unknown> } | undefined;
    if (tools?.headers !== undefined && typeof tools.headers === "object" && tools.headers !== null) {
      const auth = tools.headers.Authorization;
      const want = `Bearer ${token}`;
      if (typeof auth === "string" && auth.startsWith("Bearer ") && !ENV_REFERENCE.test(auth.slice(7)) && auth !== want) {
        tools.headers.Authorization = want;
        changed = true;
      }
    }
  }
  return changed ? `${JSON.stringify(raw, null, 2)}\n` : null;
}

/**
 * Step 2. The record and credentials go to burrow-cli's agents dir; then the
 * token in the burrow MCP entries `~/.claude.json` already holds is set to
 * the new one, so an entry carrying a rotated-out token cannot outlive the
 * start. Everything runs as the agent; the token travels on stdin only.
 */
export async function writeConnection(deps: Pick<AgentsDeps, "runner" | "log">, user: AgentUser, cmd: Pick<StartCommand, "agent_id" | "runtime_id" | "runtime_token" | "core_url">): Promise<void> {
  const dir = burrowAgentsDir(user);
  const key = connectionKey(user.work);
  const recordPath = `${dir}/${key}.json`;
  let existing: string | null = null;
  try {
    existing = await readAsUser(deps.runner, user, recordPath);
  } catch (e) {
    deps.log(`agent ${cmd.agent_id}: existing connection record not read (${(e as Error).message}); writing a fresh one`);
  }
  await writeAsUser(deps.runner, user, recordPath, renderAgentRecord(existing, user.work, cmd.core_url, cmd.runtime_id), "0600");
  await writeAsUser(
    deps.runner,
    user,
    `${dir}/${key}.credentials.json`,
    `${JSON.stringify({ token: cmd.runtime_token, headers: {} }, null, 2)}\n`,
    "0600",
  );
  await refreshMcpEntries(deps, user, cmd.agent_id, cmd.runtime_token);
}

/** The {@link refreshedClaudeJson} edit, read and written as the agent (0600, as Claude Code keeps it). */
export async function refreshMcpEntries(deps: Pick<AgentsDeps, "runner" | "log">, user: AgentUser, agentId: string, token: string): Promise<void> {
  const path = `${user.home}/.claude.json`;
  let text: string | null;
  try {
    text = await readAsUser(deps.runner, user, path);
  } catch (e) {
    deps.log(`agent ${agentId}: ${path} not read (${(e as Error).message}); its MCP entries were not refreshed`);
    return;
  }
  if (text === null) return;
  const next = refreshedClaudeJson(text, user.work, token);
  if (next === null) return;
  await writeAsUser(deps.runner, user, path, next, "0600");
  deps.log(`agent ${agentId}: refreshed the runtime token in its burrow MCP entries`);
}

/** Stage everything an agent needs, as described above. Does not start the unit. */
export async function prepareAgent(deps: AgentsDeps, cmd: StartCommand): Promise<AgentUser> {
  deps.secrets.add(cmd.runtime_token);
  for (const v of Object.values(cmd.env)) deps.secrets.add(v);

  const user = await ensureAgentUser(deps.runner, cmd.agent_id);
  await writeConnection(deps, user, cmd);
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
    // A key the agent edited since the last write is left alone unless core
    // names it in force_keys: nothing the agent wrote is lost silently.
    const priorShas = readShas(cmd.agent_id) ?? {};
    const previousApplied = readApplied(cmd.agent_id) ?? {};
    const { applied, rejected, shas, drifted } = await writeAgentFiles(deps.runner, user, cmd.files, {
      priorShas,
      force: new Set(cmd.force_keys),
    });
    for (const r of rejected) deps.log(`agent ${cmd.agent_id}: file ${JSON.stringify(r.key)} refused: ${r.reason}`);
    for (const k of drifted) deps.log(`agent ${cmd.agent_id}: file ${JSON.stringify(k)} changed on disk; not overwritten`);
    const keptShas: FilesShas = { ...shas };
    const keptApplied = { ...applied };
    for (const k of drifted) {
      const sha = priorShas[k];
      if (sha !== undefined) keptShas[k] = sha;
      const version = previousApplied[k];
      if (version !== undefined) keptApplied[k] = version;
    }
    recordApplied(cmd.agent_id, keptApplied);
    recordShas(cmd.agent_id, keptShas);
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
  const text = await (deps.conventions ?? loadBurrowConventions)();
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
  // suite-cli may write more under `login` (a URL); only `step` is read.
  login?: { step?: unknown };
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
    // The step only: whatever else suite-cli reported (a login URL) is not
    // copied, so it never leaves this host (core task 01a17b10).
    return { ...base, state: "needs_login", detail: step, login: { step } };
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
  const obs = observe(agentId, parseShow(r.stdout), readStatus(agentId), readApplied(agentId));
  const shas = readShas(agentId);
  if (shas === null) return obs;
  const files_drifted = await detectDrift(deps.runner, { name: userName(agentId), work: workDir(agentId) }, shas);
  return { ...obs, files_drifted };
}
