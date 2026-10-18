/**
 * Does an agent's API key still work? (task 01a10322 stage 7, round 2)
 *
 * THE GAP. An agent that worked on a valid key and is then given an invalid
 * one resumes its Claude Code session; the launch reads ready, no 401 notice
 * is drawn in the pane, and the dev channel drops every inbound message
 * (gate case 7009, measured). suite-cli's status file says `ready`, so
 * nothing the host observes changes, and the mention ends with no reply and
 * no notice.
 *
 * THE CHECK. When core's no-reply watchdog fires for an agent, it asks the
 * host (`agent.check_auth`). The host reads the agent's own env file and, if
 * it holds an `ANTHROPIC_API_KEY`, sends ONE request to the API's model list
 * with that key, which is where Claude Code itself sends it. 401 is
 * `rejected`; a 2xx is `ok`; anything else, including no key, is `unknown`.
 *
 * Scope, stated as scope: this checks the Burrow-mediated API-key path and
 * nothing else. A subscription login (Claude Code's own OAuth credentials)
 * is never read, sent or checked here: that login is the person's, through
 * Anthropic's own flow.
 *
 * The key travels in a request header from this process, never in an argv,
 * and is never logged.
 */
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { envFile } from "./ids.ts";

export type AuthResult = "ok" | "rejected" | "unknown";

export const DEFAULT_API_BASE = "https://api.anthropic.com";
export const CHECK_TIMEOUT_MS = 8_000;

/** The inverse of agents.ts `renderEnvFile`: `KEY='value'` lines, comments skipped. Pure. */
export function parseEnvFile(content: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const m = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line);
    if (m === null) continue;
    const [, name, raw] = m as unknown as [string, string, string];
    if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'")) {
      out[name] = raw.slice(1, -1).replace(/\\(['\\])/g, "$1");
    } else {
      out[name] = raw;
    }
  }
  return out;
}

/** The agent's env, from its root-owned-directory env file, or null. */
export function readAgentEnv(agentId: string): Record<string, string> | null {
  const path = envFile(agentId);
  try {
    if (!existsSync(path) || !lstatSync(path).isFile()) return null;
    return parseEnvFile(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

export type Fetch = (url: string, init: { method: string; headers: Record<string, string>; signal: AbortSignal }) => Promise<{ status: number }>;

/** Classify one key, with one request. Never throws. */
export async function checkApiKey(env: Record<string, string> | null, fetchImpl: Fetch, timeoutMs = CHECK_TIMEOUT_MS): Promise<AuthResult> {
  const key = env?.ANTHROPIC_API_KEY;
  if (key === undefined || key === "") return "unknown";
  const base = (env?.ANTHROPIC_BASE_URL || DEFAULT_API_BASE).replace(/\/+$/, "");
  if (!/^https?:\/\//.test(base)) return "unknown";
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(`${base}/v1/models?limit=1`, {
      method: "GET",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01" },
      signal: controller.signal,
    });
    if (res.status === 401) return "rejected";
    if (res.status >= 200 && res.status < 300) return "ok";
    return "unknown";
  } catch {
    return "unknown";
  } finally {
    clearTimeout(timer);
  }
}
