/**
 * Adopting the agents a pre-rename host runs as `suite-agent@<id>` (core task
 * 01a14dd8 stage 2). Runs once at daemon start, before the command loop.
 *
 * A legacy agent is one whose drop-in
 * `/etc/systemd/system/suite-agent@<id>.service.d/10-agent.conf` exists. For
 * each one, in this order:
 *   1. write the burrow drop-in (`burrow-agent@<id>.service.d/10-agent.conf`)
 *      unless it already exists, and the burrow template;
 *   2. move `/etc/suite-agents/<id>.env` (and the `<id>.files.json` record
 *      beside it) into `/etc/burrow-agents/`, keeping mode and owner;
 *   3. ONE `systemctl daemon-reload` for every agent together;
 *   4. stop and disable `suite-agent@<id>`, then enable and start
 *      `burrow-agent@<id>`, and remove the legacy drop-in.
 *
 * Before any of that, an OS group `suite-agents` with no `burrow-agents`
 * beside it is renamed (`groupmod -n`), which keeps its gid, so file ownership
 * is unchanged.
 *
 * Idempotent: step 4 removes the legacy drop-in, so a second start finds
 * nothing to adopt and runs no command at all.
 */
import { chmodSync, chownSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Runner } from "./exec.ts";
import { appliedFile } from "./files.ts";
import { AGENTS_GROUP, ENV_DIR, RUN_DIR, UNIT_DIR, UNIT_TEMPLATE, dropInDir, envFile, isAgentId, runDir, unitName, userName } from "./ids.ts";
import { dropIn, templateUnit } from "./units.ts";

export const LEGACY_GROUP = "suite-agents";
export const LEGACY_ENV_DIR = "/etc/suite-agents";
const LEGACY_UNIT_PREFIX = "suite-agent@";
const DROP_IN_SUFFIX = ".service.d";
const GROUP_FILE = "/etc/group";

export function legacyUnitName(agentId: string): string {
  return `${LEGACY_UNIT_PREFIX}${agentId}.service`;
}

export function legacyDropInDir(agentId: string): string {
  return `${UNIT_DIR}/${legacyUnitName(agentId)}.d`;
}

/** The file operations adoption needs, so a test can run it against a fake. */
export interface LegacyFs {
  /** Entry names, or [] when the directory does not exist. */
  readdir(path: string): string[];
  exists(path: string): boolean;
  readFile(path: string): string;
  /** Creates missing parent directories (0755). */
  writeFile(path: string, content: string, mode: number): void;
  stat(path: string): { mode: number; uid: number; gid: number };
  mkdir(path: string, mode: number): void;
  rename(from: string, to: string): void;
  chown(path: string, uid: number, gid: number): void;
  chmod(path: string, mode: number): void;
  /** Recursive; no error when absent. */
  remove(path: string): void;
}

export interface LegacyDeps {
  runner: Runner;
  fs: LegacyFs;
  /** The command the unit execs as the agent (see units.ts). */
  runnerCommand: string[];
  log(line: string): void;
}

export const liveLegacyFs: LegacyFs = {
  readdir: (path) => (existsSync(path) ? readdirSync(path) : []),
  exists: (path) => existsSync(path),
  readFile: (path) => readFileSync(path, "utf8"),
  writeFile(path, content, mode) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o755 });
    writeFileSync(path, content, { mode });
    chmodSync(path, mode);
  },
  stat(path) {
    const s = statSync(path);
    return { mode: s.mode & 0o7777, uid: s.uid, gid: s.gid };
  },
  mkdir: (path, mode) => void mkdirSync(path, { recursive: true, mode }),
  rename: (from, to) => renameSync(from, to),
  chown: (path, uid, gid) => chownSync(path, uid, gid),
  chmod: (path, mode) => chmodSync(path, mode),
  remove: (path) => rmSync(path, { recursive: true, force: true }),
};

/** Agent ids with a legacy drop-in, sorted. */
export function legacyAgents(fs: LegacyFs): string[] {
  return fs
    .readdir(UNIT_DIR)
    .filter((n) => n.startsWith(LEGACY_UNIT_PREFIX) && n.endsWith(DROP_IN_SUFFIX))
    .map((n) => n.slice(LEGACY_UNIT_PREFIX.length, -DROP_IN_SUFFIX.length))
    .filter((id) => isAgentId(id) && fs.exists(`${legacyDropInDir(id)}/10-agent.conf`))
    .sort();
}

/** Local group names. groupmod acts on /etc/group only, so that is what is read. */
function localGroups(fs: LegacyFs): Set<string> {
  if (!fs.exists(GROUP_FILE)) return new Set();
  return new Set(
    fs
      .readFile(GROUP_FILE)
      .split("\n")
      .map((l) => l.slice(0, l.indexOf(":")))
      .filter((n) => n !== ""),
  );
}

async function must(runner: Runner, argv: string[]): Promise<void> {
  const r = await runner.run(argv);
  if (r.exitCode !== 0) throw new Error(`${argv.join(" ")} failed (exit ${r.exitCode}): ${r.stderr.trim()}`);
}

/** Move `from` to `to` keeping mode and owner. A file already at `to` wins and `from` stays. */
function moveKeepingOwner(fs: LegacyFs, from: string, to: string): void {
  if (!fs.exists(from) || fs.exists(to)) return;
  const st = fs.stat(from);
  fs.mkdir(dirname(to), 0o711);
  fs.rename(from, to);
  fs.chown(to, st.uid, st.gid);
  fs.chmod(to, st.mode);
}

/** Adopt every legacy agent. Returns the ids adopted. */
export async function adoptLegacy(deps: LegacyDeps): Promise<string[]> {
  const { fs, runner, log } = deps;

  const groups = localGroups(fs);
  if (groups.has(LEGACY_GROUP) && !groups.has(AGENTS_GROUP)) {
    await must(runner, ["groupmod", "-n", AGENTS_GROUP, LEGACY_GROUP]);
    log(`renamed group ${LEGACY_GROUP} to ${AGENTS_GROUP} (gid kept)`);
  }

  const ids = legacyAgents(fs);
  if (ids.length === 0) return [];

  const template = `${UNIT_DIR}/${UNIT_TEMPLATE}`;
  const templateText = templateUnit(deps.runnerCommand);
  if (!fs.exists(template) || fs.readFile(template) !== templateText) fs.writeFile(template, templateText, 0o644);
  for (const id of ids) {
    const conf = `${dropInDir(id)}/10-agent.conf`;
    if (!fs.exists(conf)) fs.writeFile(conf, dropIn(id), 0o644);
    moveKeepingOwner(fs, `${LEGACY_ENV_DIR}/${id}.env`, envFile(id));
    moveKeepingOwner(fs, `${LEGACY_ENV_DIR}/${id}.files.json`, appliedFile(id));
  }
  await must(runner, ["systemctl", "daemon-reload"]);

  const adopted: string[] = [];
  for (const id of ids) {
    try {
      await runner.run(["systemctl", "stop", legacyUnitName(id)]);
      await runner.run(["systemctl", "disable", legacyUnitName(id)]);
      // /run is a tmpfs and the drop-in points tmux here; users.ts makes it on a start.
      await must(runner, ["install", "-d", "-m", "0711", "-o", "root", "-g", "root", RUN_DIR]);
      await must(runner, ["install", "-d", "-m", "0700", "-o", userName(id), "-g", AGENTS_GROUP, runDir(id)]);
      await must(runner, ["systemctl", "enable", "--now", unitName(id)]);
      fs.remove(legacyDropInDir(id));
      adopted.push(id);
      log(`adopted legacy agent ${id}: ${legacyUnitName(id)} -> ${unitName(id)}`);
    } catch (error) {
      log(`adopting legacy agent ${id} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return adopted;
}
