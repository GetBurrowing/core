/**
 * The tool snapshot for a native agent (task 01a17b1c stage 4): which external
 * MCP tools its Claude Code loads, taken before and after `agent.restart` and
 * returned with it as `agent.restarted`.
 *
 * Same rules as burrow-cli's src/host/tools.ts:
 *   - the servers are the APPROVED `.mcp.json` entries (named in
 *     `enabledMcpjsonServers`, or `enableAllProjectMcpServers`, in
 *     `.claude/settings.json` / `.claude/settings.local.json`, and not in
 *     `disabledMcpjsonServers`). Burrow's own tools are computed in core;
 *   - each server gets initialize + tools/list; one that does not answer is
 *     `unreachable:<server>`, never dropped;
 *   - only server and tool names leave the machine.
 *
 * AS THE AGENT. The config files are read with `readAgentFileRaw` (as the
 * agent's uid, no symlink out of the work dir), and a stdio server is started
 * by `runuser -u <agent>`, in the work dir, so a probe can do nothing the
 * agent could not. The child's environment is PATH, HOME, LANG and the server's
 * own `env`; nothing of this daemon's environment (its core token) is passed.
 * Server env values travel in the environment, never argv (exec.ts).
 *
 * The probe writes all three JSON-RPC messages up front and holds stdin open
 * for the timeout, then the server is ended: a probe always takes about
 * {@link PROBE_SECONDS}, and servers are probed concurrently.
 */
import type { Runner } from "./exec.ts";
import { REDACTED, readAgentFileRaw } from "./files.ts";

export const PROBE_SECONDS = 4;

export interface McpServerSpec {
  name: string;
  command?: string;
  args: string[];
  env: Record<string, string>;
  url?: string;
  headers: Record<string, string>;
}

export interface ToolSnapshot {
  servers: { name: string; status: "ok" | "unreachable"; tools: string[] }[];
  tools: string[];
}

type Json = Record<string, unknown>;
const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const stringMap = (v: unknown): Record<string, string> => {
  const out: Record<string, string> = {};
  if (v !== null && typeof v === "object" && !Array.isArray(v)) for (const [k, x] of Object.entries(v as Json)) if (typeof x === "string") out[k] = x;
  return out;
};
const parse = (text: string | null): Json | null => {
  if (text === null) return null;
  try {
    const v = JSON.parse(text) as unknown;
    return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null;
  } catch {
    return null;
  }
};

/** Pure: the approved servers, from the three files' text (null = absent). */
export function approvedServers(mcpJson: string | null, settings: (string | null)[]): McpServerSpec[] {
  const servers = (parse(mcpJson)?.["mcpServers"] ?? {}) as Json;
  const docs = settings.map(parse);
  const enabled = new Set(docs.flatMap((d) => strings(d?.["enabledMcpjsonServers"])));
  const disabled = new Set(docs.flatMap((d) => strings(d?.["disabledMcpjsonServers"])));
  const all = docs.some((d) => d?.["enableAllProjectMcpServers"] === true);
  const out: McpServerSpec[] = [];
  for (const [name, raw] of Object.entries(servers)) {
    if (disabled.has(name) || !(all || enabled.has(name))) continue;
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
    const r = raw as Json;
    const spec: McpServerSpec = { name, args: strings(r["args"]), env: stringMap(r["env"]), headers: stringMap(r["headers"]) };
    if (typeof r["command"] === "string" && r["command"] !== "") spec.command = r["command"];
    else if (typeof r["url"] === "string" && r["url"] !== "") spec.url = r["url"];
    else continue;
    out.push(spec);
  }
  return out.sort((a, b) => (a.name < b.name ? -1 : 1));
}

const INIT = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "burrow-agent-host", version: "0" } } };
const INITIALIZED = { jsonrpc: "2.0", method: "notifications/initialized" };
const LIST = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} };

/** Pure: the tool names in a server's stdout, or null when it never answered tools/list. */
export function toolsFromStdout(stdout: string): string[] | null {
  for (const line of stdout.split("\n")) {
    let msg: Json;
    try {
      msg = JSON.parse(line) as Json;
    } catch {
      continue;
    }
    if (msg["id"] !== 2) continue;
    const tools = (msg["result"] as Json | undefined)?.["tools"];
    if (!Array.isArray(tools)) return null;
    return (tools as Json[]).map((t) => t?.["name"]).filter((n): n is string => typeof n === "string");
  }
  return null;
}

/**
 * `sh -c PROBE_SCRIPT sh WORK SECONDS COMMAND ARG...`: the messages from stdin,
 * then stdin held open for SECONDS; the server is TERMed at SECONDS and KILLed
 * a second later. Plain POSIX sh, no coreutils `timeout`.
 */
export const PROBE_SCRIPT = [
  'cd "$1" || exit 3',
  't="$2"',
  "shift 2",
  '{ cat; sleep "$t"; } | "$@" &',
  "p=$!",
  '( sleep "$t"; kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 &',
  'wait "$p"',
].join("\n");

export interface ProbeUser {
  name: string;
  home: string;
  work: string;
}

async function probeStdio(runner: Runner, user: ProbeUser, spec: McpServerSpec, seconds: number): Promise<string[] | null> {
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin",
    HOME: user.home,
    LANG: process.env.LANG ?? "C.UTF-8",
    ...spec.env,
  };
  try {
    const r = await runner.run(
      ["runuser", "-u", user.name, "--", "/bin/sh", "-c", PROBE_SCRIPT, "sh", user.work, String(seconds), spec.command!, ...spec.args],
      { stdin: [INIT, INITIALIZED, LIST].map((m) => JSON.stringify(m)).join("\n") + "\n", env },
    );
    return toolsFromStdout(r.stdout);
  } catch {
    // e.g. a server arg carrying a held secret: refused before spawn.
    return null;
  }
}

async function probeHttp(spec: McpServerSpec, seconds: number): Promise<string[] | null> {
  const headers: Record<string, string> = { "content-type": "application/json", accept: "application/json, text/event-stream", ...spec.headers };
  const signal = AbortSignal.timeout(seconds * 1000);
  const body = (text: string): Json | null => {
    const direct = parse(text);
    if (direct !== null) return direct;
    for (const l of text.split("\n")) if (l.startsWith("data:")) { const m = parse(l.slice(5).trim()); if (m?.["id"] !== undefined) return m; }
    return null;
  };
  try {
    const init = await fetch(spec.url!, { method: "POST", headers, body: JSON.stringify(INIT), signal });
    if (!init.ok || body(await init.text()) === null) return null;
    const sid = init.headers.get("mcp-session-id");
    if (sid !== null) headers["mcp-session-id"] = sid;
    await fetch(spec.url!, { method: "POST", headers, body: JSON.stringify(INITIALIZED), signal }).then((r) => r.text());
    const list = await fetch(spec.url!, { method: "POST", headers, body: JSON.stringify(LIST), signal });
    const msg = body(await list.text());
    const tools = (msg?.["result"] as Json | undefined)?.["tools"];
    return Array.isArray(tools) ? (tools as Json[]).map((t) => t?.["name"]).filter((n): n is string => typeof n === "string") : null;
  } catch {
    return null;
  }
}

export interface SnapshotDeps {
  runner: Runner;
  seconds?: number;
  /** Test seam for the HTTP probe. */
  probeHttp?(spec: McpServerSpec, seconds: number): Promise<string[] | null>;
}

/** Probe every approved server of the agent in `user.work`. */
export async function snapshotTools(deps: SnapshotDeps, user: ProbeUser): Promise<ToolSnapshot> {
  const read = async (key: string): Promise<string | null> => {
    const r = await readAgentFileRaw(deps.runner, user, key);
    return r.status === "ok" ? r.content : null;
  };
  const specs = approvedServers(await read(".mcp.json"), [await read(".claude/settings.json"), await read(".claude/settings.local.json")]);
  const seconds = deps.seconds ?? PROBE_SECONDS;
  const servers = await Promise.all(
    specs.map(async (spec) => {
      const names =
        spec.command !== undefined ? await probeStdio(deps.runner, user, spec, seconds) : await (deps.probeHttp ?? probeHttp)(spec, seconds);
      if (names === null) return { name: spec.name, status: "unreachable" as const, tools: [] };
      const secrets = [...Object.values(spec.env), ...Object.values(spec.headers)].filter((v) => v.length >= 12);
      const shown = names.map((n) => (secrets.some((s) => n.includes(s)) ? REDACTED : n));
      return { name: spec.name, status: "ok" as const, tools: [...new Set(shown)].sort() };
    }),
  );
  const tools = servers.flatMap((s) => (s.status === "unreachable" ? [`unreachable:${s.name}`] : s.tools.map((t) => `${s.name}/${t}`))).sort();
  return { servers, tools };
}
