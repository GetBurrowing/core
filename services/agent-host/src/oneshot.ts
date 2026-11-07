/**
 * `agent.oneshot`: ONE isolated, tool-less question to an agent's own harness
 * CLI, on the agent's own subscription login (core task 01a1b721 stage 2).
 *
 *   in   agent.oneshot {agent_id, ref, prompt, max_output_tokens, timeout_ms}
 *   out  agent.oneshot {ref, agent_id, result: ok | refused | failed | timeout,
 *                       reason?, text?, usage?: {input_tokens, output_tokens,
 *                       cache_read_tokens, cache_creation_tokens}}
 *
 * Core's secretary uses it as its only model path. Core never sees a
 * credential: the CLI runs as the agent's OS user and uses the login stored
 * in that user's home, exactly as the agent's own unit does.
 *
 * WHAT THE CHILD GETS, AND WHAT IT DOES NOT (flags measured against the
 * pinned Claude Code 2.1.295 `--help`, and run once on 2.1.319, 2026-11-07):
 *
 *   - the prompt on STDIN only. It is never in an argv (world-readable through
 *     `ps`; it is also held in the SecretRegistry while the call runs, so any
 *     argv carrying it is refused, exec.ts) and never logged, nor is the
 *     answer;
 *   - NO tools: `--tools ""` (the empty set); NO MCP servers:
 *     `--strict-mcp-config --mcp-config {"mcpServers":{}}`; no user, project
 *     or local settings (`--setting-sources ""`, so no hooks, plugins or
 *     apiKeyHelper load); no skills or commands (`--disable-slash-commands`);
 *   - no session written or resumed: `--no-session-persistence`, `-p`, never
 *     `--resume`/`--continue`;
 *   - cwd a fresh, empty temp dir owned by the agent, removed afterwards;
 *   - an env built from nothing (`env -i`), and even then
 *     ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL and
 *     OPENAI_API_KEY are deleted from it ({@link STRIPPED_ENV});
 *   - killed at `timeout_ms`.
 *
 * REFUSED (`result: refused`, nothing run) when:
 *   - the agent is not running (`not_running`);
 *   - the agent's env file holds ANTHROPIC_API_KEY or OPENAI_API_KEY
 *     (`api_key_login`): only the variable NAMES are looked at;
 *   - Claude: the agent's `~/.claude/settings.json` defines `apiKeyHelper`
 *     (`api_key_login`); `claude auth status --json` reads not logged in
 *     (`not_logged_in`) or logged in by anything but `claude.ai`
 *     (`api_key_login`);
 *   - Codex: `codex login status` does not report a ChatGPT login
 *     (`api_key_login`, or `not_logged_in`). A ChatGPT-logged-in Codex agent
 *     is STILL refused, `tools_not_disableable`: Codex 0.162.0 `exec` has no
 *     switch that removes its shell and patch tools (`--sandbox read-only`
 *     only limits what they may write; they can still read and run), so the
 *     "no tools" property cannot be met there.
 */
import { lstatSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseAuthStatus } from "./claude_login.ts";
import { codexHomeFor } from "./codex_login.ts";
import type { SecretRegistry } from "./exec.ts";
import { homeDir, isAgentId, userName, workDir } from "./ids.ts";

/** Names that are never in a oneshot child's env. */
export const STRIPPED_ENV = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY"] as const;
/** Names whose presence in the agent's env file means an API-key login. */
export const API_KEY_NAMES = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"] as const;

export const DEFAULT_TIMEOUT_MS = 120_000;
export const MAX_TIMEOUT_MS = 300_000;
export const DEFAULT_MAX_OUTPUT_TOKENS = 4_000;
export const MAX_OUTPUT_TOKENS = 32_000;
/** A prompt larger than this is refused before anything runs. */
export const MAX_PROMPT_BYTES = 2_000_000;
/** How long the login checks (`auth status`, `login status`) may take. */
export const CHECK_TIMEOUT_MS = 20_000;

export type OneshotReason =
  | "api_key_login"
  | "not_running"
  | "not_logged_in"
  | "tools_not_disableable"
  | "unsupported_harness"
  | "invalid";

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_creation_tokens: number;
}

export type OneshotReply =
  | { result: "ok"; text: string; usage: Usage }
  | { result: "refused"; reason: OneshotReason }
  | { result: "failed"; reason: string }
  | { result: "timeout" };

export interface OneshotRequest {
  agentId: string;
  ref: string;
  prompt: string;
  maxOutputTokens: number;
  timeoutMs: number;
}

export interface ChildRun {
  exitCode: number;
  stdout: string;
  timedOut: boolean;
}

export interface OneshotDeps {
  /** The agent's env file (auth.ts readAgentEnv). Only names and BURROW_AGENT_HARNESS are read. */
  readEnv(agentId: string): Record<string, string> | null;
  /** The agent's observed state (host.ts observe). */
  state(agentId: string): Promise<string>;
  /** `~/.claude/settings.json` of the agent, or null. Read only for `apiKeyHelper`. */
  readClaudeSettings(agentId: string): Promise<string | null>;
  /** Run `argv` (already wrapped as the agent) with `stdin`, killed at `timeoutMs`. stderr is never read. */
  run(argv: string[], opts: { cwd: string; stdin: string; timeoutMs: number }): Promise<ChildRun>;
  /** A fresh empty dir the agent may use as its cwd. */
  makeTempDir(agentId: string): Promise<string>;
  removeDir(path: string): void;
  /** The env the child starts from, before {@link oneshotEnv} strips it. */
  baseEnv(agentId: string): Record<string, string>;
  secrets: SecretRegistry;
  log(line: string): void;
  claudeBin?: string;
  codexBin?: string;
}

/** The command's payload, checked; a string names what is wrong. Pure. */
export function parseOneshot(payload: Record<string, unknown>): OneshotRequest | string {
  const { agent_id: agentId, ref, prompt, max_output_tokens: max, timeout_ms: timeout } = payload;
  if (!isAgentId(agentId)) return "agent_id missing";
  if (typeof ref !== "string" || ref === "") return "ref missing";
  if (typeof prompt !== "string" || prompt === "") return "prompt missing";
  if (Buffer.byteLength(prompt, "utf8") > MAX_PROMPT_BYTES) return "prompt too large";
  const clamp = (v: unknown, dflt: number, hi: number) =>
    typeof v === "number" && Number.isInteger(v) && v > 0 ? Math.min(v, hi) : dflt;
  return {
    agentId,
    ref,
    prompt,
    maxOutputTokens: clamp(max, DEFAULT_MAX_OUTPUT_TOKENS, MAX_OUTPUT_TOKENS),
    timeoutMs: clamp(timeout, DEFAULT_TIMEOUT_MS, MAX_TIMEOUT_MS),
  };
}

/** The Claude Code argv: print mode, JSON out, no tools, no MCP, no settings, no session. Pure. */
export function claudeArgv(bin: string): string[] {
  return [
    bin,
    "-p",
    "--output-format",
    "json",
    "--tools",
    "",
    "--strict-mcp-config",
    "--mcp-config",
    '{"mcpServers":{}}',
    "--setting-sources",
    "",
    "--disable-slash-commands",
    "--no-session-persistence",
  ];
}

/** `base` minus every {@link STRIPPED_ENV} name, plus the output cap. Pure. */
export function oneshotEnv(base: Record<string, string>, maxOutputTokens: number): Record<string, string> {
  const env: Record<string, string> = { ...base };
  for (const name of STRIPPED_ENV) delete env[name];
  env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = String(maxOutputTokens);
  env.DISABLE_AUTOUPDATER = "1";
  return env;
}

/** `runuser -u <agent> -- env -i K=V... <rest>`. Pure. */
export function asAgentWithEnv(agentId: string, env: Record<string, string>, rest: string[]): string[] {
  if (!isAgentId(agentId)) throw new Error("not an agent id");
  const pairs = Object.entries(env).map(([k, v]) => `${k}=${v}`);
  return ["runuser", "-u", userName(agentId), "--", "env", "-i", ...pairs, ...rest];
}

/** The live starting env: what the CLI needs to run as the agent, nothing from its env file. */
export function liveBaseEnv(agentId: string): Record<string, string> {
  const home = homeDir(agentId);
  return {
    HOME: home,
    USER: userName(agentId),
    PATH: `${home}/.local/bin:/usr/local/bin:/usr/bin:/bin`,
    LANG: "C.UTF-8",
    NODE_EXTRA_CA_CERTS: "/etc/ssl/certs/ca-certificates.crt",
  };
}

/** True when a Claude settings file defines an `apiKeyHelper`. Pure. */
export function definesApiKeyHelper(settings: string | null): boolean {
  if (settings === null) return false;
  try {
    const v = JSON.parse(settings) as unknown;
    if (typeof v !== "object" || v === null) return false;
    const helper = (v as Record<string, unknown>).apiKeyHelper;
    return helper !== undefined && helper !== null && helper !== "";
  } catch {
    // Unparseable settings: Claude may still read a helper from it; refuse.
    return /apiKeyHelper/.test(settings);
  }
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.floor(v) : 0);

/** Claude Code's `--output-format json` result, as a reply. Pure. */
export function parseClaudeResult(stdout: string): OneshotReply {
  let v: unknown;
  try {
    v = JSON.parse(stdout.trim());
  } catch {
    return { result: "failed", reason: "unparseable_output" };
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) return { result: "failed", reason: "unparseable_output" };
  const o = v as Record<string, unknown>;
  const text = typeof o.result === "string" ? o.result : null;
  if (o.is_error === true) {
    if (text !== null && /not logged in|please run \/login|invalid api key|authentication/i.test(text)) {
      return { result: "refused", reason: "not_logged_in" };
    }
    return { result: "failed", reason: "cli_error" };
  }
  if (text === null) return { result: "failed", reason: "no_result" };
  const u = (typeof o.usage === "object" && o.usage !== null ? o.usage : {}) as Record<string, unknown>;
  return {
    result: "ok",
    text,
    usage: {
      input_tokens: num(u.input_tokens),
      output_tokens: num(u.output_tokens),
      cache_read_tokens: num(u.cache_read_input_tokens),
      cache_creation_tokens: num(u.cache_creation_input_tokens),
    },
  };
}

/** The whole call. Never throws; never logs the prompt or the answer. */
export async function runOneshot(deps: OneshotDeps, req: OneshotRequest): Promise<OneshotReply> {
  const fileEnv = deps.readEnv(req.agentId) ?? {};
  if ((await deps.state(req.agentId)) !== "running") return { result: "refused", reason: "not_running" };
  if (API_KEY_NAMES.some((n) => n in fileEnv)) return { result: "refused", reason: "api_key_login" };
  const harness = fileEnv.BURROW_AGENT_HARNESS ?? "claude_code";
  if (harness !== "claude_code" && harness !== "codex") return { result: "refused", reason: "unsupported_harness" };

  const env = oneshotEnv(deps.baseEnv(req.agentId), req.maxOutputTokens);
  let dir: string | null = null;
  const holdPrompt = !deps.secrets.values().includes(req.prompt);
  if (holdPrompt) deps.secrets.add(req.prompt);
  try {
    dir = await deps.makeTempDir(req.agentId);
    if (harness === "codex") return await codex(deps, req, env, dir);

    if (definesApiKeyHelper(await deps.readClaudeSettings(req.agentId))) return { result: "refused", reason: "api_key_login" };
    const bin = deps.claudeBin ?? "claude";
    const status = await deps.run(asAgentWithEnv(req.agentId, env, [bin, "auth", "status", "--json"]), {
      cwd: dir,
      stdin: "",
      timeoutMs: CHECK_TIMEOUT_MS,
    });
    const auth = parseAuthStatus(status.stdout);
    if (auth === null || !auth.loggedIn) return { result: "refused", reason: "not_logged_in" };
    if (auth.authMethod !== "claude.ai") return { result: "refused", reason: "api_key_login" };

    const r = await deps.run(asAgentWithEnv(req.agentId, env, claudeArgv(bin)), { cwd: dir, stdin: req.prompt, timeoutMs: req.timeoutMs });
    if (r.timedOut) return { result: "timeout" };
    return parseClaudeResult(r.stdout);
  } catch (error) {
    return { result: "failed", reason: error instanceof Error ? error.name : "error" };
  } finally {
    if (holdPrompt) deps.secrets.remove(req.prompt);
    if (dir !== null) {
      try {
        deps.removeDir(dir);
      } catch {
        deps.log(`agent ${req.agentId}: oneshot temp dir not removed`);
      }
    }
  }
}

async function codex(deps: OneshotDeps, req: OneshotRequest, env: Record<string, string>, dir: string): Promise<OneshotReply> {
  const codexEnv = { ...env, CODEX_HOME: codexHomeFor(workDir(req.agentId)) };
  const r = await deps.run(asAgentWithEnv(req.agentId, codexEnv, [deps.codexBin ?? "codex", "login", "status"]), {
    cwd: dir,
    stdin: "",
    timeoutMs: CHECK_TIMEOUT_MS,
  });
  if (r.exitCode !== 0 || /not logged in/i.test(r.stdout)) return { result: "refused", reason: "not_logged_in" };
  if (!/ChatGPT/.test(r.stdout)) return { result: "refused", reason: "api_key_login" };
  return { result: "refused", reason: "tools_not_disableable" };
}

/**
 * The live pieces: a temp dir under the system tmp owned by the agent
 * (`chown` as root, mode 0700), the child run with stdout piped, stderr
 * discarded (never read, never logged), stdin the prompt.
 */
export function liveOneshotDeps(base: Pick<OneshotDeps, "readEnv" | "state" | "secrets" | "log"> & {
  check(argv: string[], secrets: SecretRegistry): void;
}): OneshotDeps {
  return {
    readEnv: base.readEnv,
    state: base.state,
    secrets: base.secrets,
    log: base.log,
    baseEnv: liveBaseEnv,
    async readClaudeSettings(agentId) {
      const proc = Bun.spawn(["runuser", "-u", userName(agentId), "--", "cat", `${homeDir(agentId)}/.claude/settings.json`], {
        stdout: "pipe",
        stderr: "ignore",
        stdin: "ignore",
      });
      const [out, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
      return code === 0 ? out : null;
    },
    async makeTempDir(agentId) {
      const dir = mkdtempSync(join(tmpdir(), "burrow-oneshot-"));
      const proc = Bun.spawn(["chown", `${userName(agentId)}:`, dir], { stdout: "ignore", stderr: "ignore", stdin: "ignore" });
      if ((await proc.exited) !== 0) {
        rmSync(dir, { recursive: true, force: true });
        throw new Error("chown failed");
      }
      return dir;
    },
    removeDir(path) {
      if (lstatSync(path, { throwIfNoEntry: false })?.isDirectory()) rmSync(path, { recursive: true, force: true });
    },
    run: liveChildRun((argv) => base.check(argv, base.secrets)),
  };
}

/**
 * Spawn, write stdin, read stdout, kill at the timeout. stderr is ignored.
 * The child leads its own process group (`detached`) and the timeout kills
 * the whole group, so a CLI's own children (under `runuser` and `env`) go
 * with it and cannot hold stdout open.
 */
export function liveChildRun(check: (argv: string[]) => void): OneshotDeps["run"] {
  return async (argv, opts) => {
    check(argv);
    const proc = Bun.spawn(argv, {
      cwd: opts.cwd,
      env: { PATH: "/usr/sbin:/usr/bin:/sbin:/bin" },
      stdin: new Blob([opts.stdin]),
      stdout: "pipe",
      stderr: "ignore",
      detached: true,
    });
    const killGroup = () => {
      try {
        process.kill(-proc.pid, "SIGKILL");
      } catch {
        proc.kill("SIGKILL");
      }
    };
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<ChildRun>((res) => {
      timer = setTimeout(() => {
        killGroup();
        res({ exitCode: -1, stdout: "", timedOut: true });
      }, opts.timeoutMs);
    });
    const done = Promise.all([new Response(proc.stdout).text(), proc.exited]).then(([stdout, exitCode]) => ({ exitCode, stdout, timedOut: false }));
    try {
      return await Promise.race([done, timeout]);
    } finally {
      clearTimeout(timer);
    }
  };
}
