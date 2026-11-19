/**
 * VENDORED, VERBATIM: burrow-cli's own agent-record reader and writer at
 * BURROW_CLI_REF 9314fc38a9f6025db98340486b5fadf18e892513 (0.19.0), so
 * test/runner_terminal.test.ts can read the record agent-host writes back the
 * way burrow-cli does. agent-host's tests run without a burrow-cli checkout
 * (CI's bun:1 container), so the reader cannot be imported; it is copied.
 *
 * Each block below is the named line range of `git show <ref>:<file>`, byte
 * for byte, with nothing else changed. VENDORED_REF must equal versions.env
 * BURROW_CLI_REF: a test fails on a bump until this file is re-vendored from
 * the new ref, so the two formats cannot drift unnoticed.
 *
 *   src/agent_connections.ts  49-70    AgentRecord
 *   src/agent_connections.ts  93-106   canonicalDir, agentKey
 *   src/agent_connections.ts  156-220  isEnvName, isRefString, serializeAgentRecord, parseAgentRecord
 *   src/legacy_names.ts       60-61    URL_KEY, LEGACY_URL_KEY
 *   src/legacy_names.ts       80-100   LegacyNameConflict, Json, isObject, has
 *   src/legacy_names.ts       105-116  configUrl
 *   src/tmux.ts               47-52    SAFE_NAME, sanitizeSessionName
 */
import { realpathSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, resolve } from "node:path";

export const VENDORED_REF = "9314fc38a9f6025db98340486b5fadf18e892513";

// src/tmux.ts 47-52
const SAFE_NAME = /[^A-Za-z0-9_-]+/g;

export function sanitizeSessionName(raw: string): string {
  const cleaned = raw.replace(SAFE_NAME, "-").replace(/-{2,}/g, "-").replace(/^-+|-+$/g, "");
  return cleaned === "" ? "session" : cleaned;
}

// src/legacy_names.ts 60-61
export const URL_KEY = "burrowUrl";
export const LEGACY_URL_KEY = "suiteUrl";

// src/legacy_names.ts 80-100
/** Something holds both an old and a new name. Nothing was renamed. */
export class LegacyNameConflict extends Error {
  constructor(
    readonly where: string,
    readonly oldName: string,
    readonly newName: string,
    /** The release that reads only the new name. */
    readonly since = "0.11.0",
  ) {
    super(
      `${where} holds both ${oldName} and ${newName}; burrow ${since} reads only ${newName}, ` +
        `so keep one (remove the other) and start the agent again`,
    );
    this.name = "LegacyNameConflict";
  }
}

type Json = Record<string, unknown>;

const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const has = (o: Json, k: string): boolean => Object.prototype.hasOwnProperty.call(o, k);

// src/legacy_names.ts 105-116

/**
 * The URL a raw config object (machine config, agent record, root identity)
 * carries: `burrowUrl`, else — an unmigrated file — `suiteUrl`, else undefined.
 * Throws {@link LegacyNameConflict} when it carries both. Never writes.
 */
export function configUrl(raw: Json, where = "the config"): unknown {
  const fresh = has(raw, URL_KEY);
  const legacy = has(raw, LEGACY_URL_KEY);
  if (fresh && legacy) throw new LegacyNameConflict(where, LEGACY_URL_KEY, URL_KEY);
  return fresh ? raw[URL_KEY] : raw[LEGACY_URL_KEY];
}

// src/agent_connections.ts 49-70
export interface AgentRecord {
  /** The canonical folder this record belongs to. */
  dir: string;
  suiteUrl: string;
  runtimeId: string;
  headerNames: string[];
  tokenEnv?: string;
  tokenRef?: string;
  keychainService?: string;
  /**
   * Who may edit this agent's config files from the Burrow install
   * (src/host/access.ts). Absent reads as "off". Not a secret.
   */
  configAccess?: "owner_only" | "admins";
  /**
   * The agent session this folder's remote terminal is switched on for
   * (src/terminal/host.ts). Set by `burrow claude --remote-terminal`, cleared
   * when that session ends or the next launch has no flag. Absent is off. Not a
   * secret.
   */
  remoteTerminal?: string;
}

// src/agent_connections.ts 93-106
/** The folder as the store keys it: symlinks resolved when it exists, else just absolute. */
export function canonicalDir(dir: string): string {
  const abs = resolve(dir);
  try {
    return realpathSync(abs);
  } catch {
    return abs;
  }
}

export function agentKey(dir: string): string {
  const canon = canonicalDir(dir);
  return `${sanitizeSessionName(basename(canon))}-${createHash("sha256").update(canon).digest("hex").slice(0, 16)}`;
}

// src/agent_connections.ts 156-220
const isEnvName = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(v);
const isRefString = (v: unknown): v is string =>
  typeof v === "string" && (v.startsWith("file:") || v.startsWith("keychain:"));

/** The exact bytes of a record. Pure. */
export function serializeAgentRecord(record: AgentRecord): string {
  const out: Record<string, unknown> = {
    dir: record.dir,
    [URL_KEY]: record.suiteUrl,
    runtimeId: record.runtimeId,
    headerNames: [...record.headerNames].map((n) => n.trim()).filter((n) => n !== ""),
  };
  if (record.tokenEnv !== undefined) {
    if (!isEnvName(record.tokenEnv)) throw new Error("agent record tokenEnv must be an environment variable name");
    out.tokenEnv = record.tokenEnv;
  }
  if (record.tokenRef !== undefined) {
    if (!isRefString(record.tokenRef)) throw new Error("agent record tokenRef must be a file: or keychain: ref");
    out.tokenRef = record.tokenRef;
  }
  if (record.keychainService !== undefined && record.keychainService !== "") out.keychainService = record.keychainService;
  if (record.configAccess === "owner_only" || record.configAccess === "admins") out.configAccess = record.configAccess;
  if (typeof record.remoteTerminal === "string" && record.remoteTerminal !== "") out.remoteTerminal = record.remoteTerminal;
  return `${JSON.stringify(out, null, 2)}\n`;
}

/**
 * Parse a record, or null when it is not one. Never throws. A record holding
 * only the pre-0.11.0 `suiteUrl` key reads the same (it is renamed at the
 * agent's next start); one holding both `suiteUrl` and `burrowUrl` is not a
 * record — the start refuses it by name (legacy_names.ts).
 */
export function parseAgentRecord(text: string): AgentRecord | null {
  let raw: Record<string, unknown>;
  try {
    const parsed = JSON.parse(text) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
    raw = parsed as Record<string, unknown>;
  } catch {
    return null;
  }
  if (typeof raw.dir !== "string" || raw.dir === "") return null;
  let url: unknown;
  try {
    url = configUrl(raw);
  } catch (e) {
    if (e instanceof LegacyNameConflict) return null;
    throw e;
  }
  if (typeof url !== "string" || typeof raw.runtimeId !== "string") return null;
  const names = Array.isArray(raw.headerNames) ? raw.headerNames.filter((n): n is string => typeof n === "string") : [];
  return {
    dir: raw.dir,
    suiteUrl: url,
    runtimeId: raw.runtimeId,
    headerNames: names,
    ...(isEnvName(raw.tokenEnv) ? { tokenEnv: raw.tokenEnv } : {}),
    ...(isRefString(raw.tokenRef) ? { tokenRef: raw.tokenRef } : {}),
    ...(typeof raw.keychainService === "string" && raw.keychainService !== ""
      ? { keychainService: raw.keychainService }
      : {}),
    ...(raw.configAccess === "owner_only" || raw.configAccess === "admins" ? { configAccess: raw.configAccess } : {}),
    ...(typeof raw.remoteTerminal === "string" && raw.remoteTerminal !== "" ? { remoteTerminal: raw.remoteTerminal } : {}),
  };
}
