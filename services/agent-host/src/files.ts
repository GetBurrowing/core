/**
 * An agent's own files (CLAUDE.md, .claude/settings.json, ...), written into
 * its work dir on every start (task 01a10322 stage 5).
 *
 * Core stores each agent's files (Agent Resources edits them, owner or admin
 * only) and sends them in `agent.start` / `agent.restart` as
 * `files: [{key, content, version}]`. The host writes them BEFORE the unit
 * restarts, so the stored copy wins over anything `suite claude` would write
 * (suite-cli writes CLAUDE.md only when it is absent).
 *
 * THE RULES, each enforced here and not only in core:
 *
 *   - a key is relative: no leading "/" or "~", no "." or ".." component, no
 *     empty component, at most 3 components, printable characters only
 *     ({@link isFileKey}, the same rule as core's `valid_file_key?/1`);
 *   - every write runs AS THE AGENT (`runuser`), so the file is the agent's
 *     own and a symlink the agent planted can never redirect a ROOT write;
 *   - the directory each file lands in is walked one component at a time
 *     with `cd -P`, and the walk stops if any real path leaves the work dir,
 *     so a symlinked `.claude` pointing at `~/.ssh` is refused, not followed;
 *   - a key whose final component is a symlink is refused, as is one that
 *     names a directory;
 *   - temp file in the same directory, mode 0644, then `mv -T` over the key.
 *
 * What was applied is recorded in a root-owned file next to the agent's env
 * file, so `files_applied` survives a host restart and core can tell a
 * running agent that has not picked up a later save ("Restart to apply").
 */
import { existsSync, readFileSync, renameSync, writeFileSync, chmodSync, mkdirSync } from "node:fs";
import type { Runner } from "./exec.ts";
import { ENV_DIR, isAgentId } from "./ids.ts";
import type { AgentUser } from "./users.ts";

export interface AgentFile {
  key: string;
  content: string;
  version: number;
}

/** Key → version the host last wrote into the agent's work dir. */
export type FilesApplied = Record<string, number>;

export const MAX_FILE_DEPTH = 3;
export const MAX_FILE_BYTES = 512 * 1024;

const COMPONENT = /^[A-Za-z0-9_][A-Za-z0-9._@+-]*$|^\.[A-Za-z0-9_][A-Za-z0-9._@+-]*$/;

/**
 * A key the host will write: relative, at most {@link MAX_FILE_DEPTH}
 * components, none of them "", "." or "..", no leading "/" or "~". Each
 * component is letters, digits and `._@+-`, so no control character, space,
 * backslash or glob ever reaches a path.
 */
export function isFileKey(key: unknown): key is string {
  if (typeof key !== "string" || key === "" || key.length > 255) return false;
  if (key.startsWith("/") || key.startsWith("~")) return false;
  const parts = key.split("/");
  if (parts.length > MAX_FILE_DEPTH) return false;
  return parts.every((p) => p !== "" && p !== "." && p !== ".." && COMPONENT.test(p));
}

/**
 * Validate the `files` field of a start command. Absent is null: a core that
 * sends no files leaves the work dir, and the applied record, as they are.
 */
export function parseFiles(value: unknown): AgentFile[] | null | string {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) return "files is not a list";
  const out: AgentFile[] = [];
  for (const f of value) {
    if (typeof f !== "object" || f === null) return "a file is not an object";
    const { key, content, version } = f as Record<string, unknown>;
    if (typeof key !== "string") return "a file has no key";
    if (typeof content !== "string") return `file ${key} has no content`;
    if (Buffer.byteLength(content, "utf8") > MAX_FILE_BYTES) return `file ${key} is too large`;
    if (typeof version !== "number" || !Number.isInteger(version)) return `file ${key} has no version`;
    // An invalid key is kept here and refused by the writer, so it is
    // reported as not applied instead of failing the whole start.
    out.push({ key, content, version });
  }
  return out;
}

/**
 * The script the agent's own shell runs for one file. Arguments: work dir,
 * key's directory part ("" for none), key's base name, mode. Content on stdin.
 * Exit 3 means the key escaped the work dir.
 */
export const WRITE_SCRIPT = [
  "set -eu",
  'work="$1"; dir="$2"; base="$3"; mode="$4"',
  '[ -L "$work" ] && { echo "work dir is a symlink" >&2; exit 3; }',
  'cd -P -- "$work"',
  'real_work="$(pwd -P)"',
  'if [ -n "$dir" ]; then',
  "  set -f; IFS=/",
  "  for c in $dir; do",
  '    if [ ! -e "$c" ] && [ ! -L "$c" ]; then mkdir -m 0755 -- "$c"; fi',
  '    cd -P -- "$c"',
  '    case "$(pwd -P)/" in "$real_work"/*) ;; *) echo "escapes the work dir" >&2; exit 3 ;; esac',
  "  done",
  "fi",
  '[ -L "$base" ] && { echo "is a symlink" >&2; exit 3; }',
  '[ -d "$base" ] && { echo "is a directory" >&2; exit 3; }',
  'tmp="$(mktemp -- ".$base.XXXXXX")"',
  'trap \'rm -f -- "$tmp"\' EXIT',
  'cat > "$tmp"',
  'chmod "$mode" "$tmp"',
  'mv -fT -- "$tmp" "$base"',
  "trap - EXIT",
].join("\n");

export interface WriteResult {
  applied: FilesApplied;
  rejected: { key: string; reason: string }[];
}

/**
 * Write every file into `user.work` as `user`. A refused key is skipped and
 * reported; it never stops the others or the start.
 */
export async function writeAgentFiles(runner: Runner, user: AgentUser, files: AgentFile[]): Promise<WriteResult> {
  const applied: FilesApplied = {};
  const rejected: { key: string; reason: string }[] = [];
  for (const f of files) {
    if (!isFileKey(f.key)) {
      rejected.push({ key: f.key, reason: "not a valid file key" });
      continue;
    }
    const slash = f.key.lastIndexOf("/");
    const dir = slash === -1 ? "" : f.key.slice(0, slash);
    const base = slash === -1 ? f.key : f.key.slice(slash + 1);
    const r = await runner.run(
      ["runuser", "-u", user.name, "--", "/bin/sh", "-c", WRITE_SCRIPT, "sh", user.work, dir, base, "0644"],
      { stdin: f.content },
    );
    if (r.exitCode === 0) applied[f.key] = f.version;
    else rejected.push({ key: f.key, reason: r.stderr.trim() || `exit ${r.exitCode}` });
  }
  return { applied, rejected };
}

/** Where the host records what it last applied for an agent. Root-owned. */
export function appliedFile(agentId: string): string {
  return `${ENV_DIR}/${agentId}.files.json`;
}

export function recordApplied(agentId: string, applied: FilesApplied): void {
  if (!isAgentId(agentId)) throw new Error("not an agent id");
  mkdirSync(ENV_DIR, { recursive: true, mode: 0o711 });
  const path = appliedFile(agentId);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(applied)}\n`, { mode: 0o600, flag: "w" });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

/** What was last applied, or null when nothing is recorded (or it is unreadable). */
export function readApplied(agentId: string): FilesApplied | null {
  const path = appliedFile(agentId);
  if (!existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
    const out: FilesApplied = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === "number" && Number.isInteger(v)) out[k] = v;
    }
    return out;
  } catch {
    return null;
  }
}
