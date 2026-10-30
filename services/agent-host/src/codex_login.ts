/**
 * Codex's own device-code login, driven for a native agent that has no
 * terminal (core task 01a10315 stage 4).
 *
 * `codex login --device-auth` prints a URL on auth.openai.com and a one-time
 * code, then polls OpenAI until the person enters that code on OpenAI's own
 * page in their own browser. The code grants nothing by itself: the login
 * finishes only when the person approves it there. So the code and the URL
 * may be shown to the agent's owner in Burrow, and nothing else may: the
 * token Codex then saves (`auth.json` in CODEX_HOME) is never read, logged
 * or sent by anything here. This module only ever runs `codex login
 * --device-auth` and `codex login status`, and writes the agent's status file.
 *
 * This is NOT a Claude login. Burrow never relays a Claude login (core task
 * 01a17b10); nothing here is used for the `claude_code` harness.
 *
 * MEASURED, not remembered (codex-cli 0.162.0, node:22 container on moon,
 * fresh HOME and CODEX_HOME, 2026-10-30; the transcript, with the code
 * replaced, is test/fixtures/codex-device-auth-0.162.0.txt):
 *
 *   - stdout, coloured with ANSI escapes even when it is a pipe;
 *   - "1. Open this link in your browser and sign in to your account", then
 *     an indented `https://auth.openai.com/codex/device`;
 *   - "2. Enter this one-time code (expires in 15 minutes)", then an indented
 *     code shaped `XXXX-XXXXX` (upper-case letters and digits);
 *   - `codex login status` exits 1 and prints "Not logged in" when it is not;
 *   - left alone, the login ends exactly 15 minutes later with exit 1 and, on
 *     stderr, "Error logging in with device code: device auth timed out after
 *     15 minutes" (measured 21:18:24Z to 21:33:24Z);
 *   - killed with SIGTERM it exited 0 without logging in, so an exit code is
 *     never taken as a login: `codex login status` decides.
 *
 * Runs inside the agent's unit (runner.ts), so as the agent's own uid, with
 * CODEX_HOME at the path burrow-cli's `codexHomeFor` resolves for the work
 * dir (`<work dir>/.codex`, burrow-cli 9a8ef75 src/commands/codex.ts).
 */
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/** Status file shapes this module writes (the agent host reads them, agents.ts `observe`). */
export type CodexStatus =
  | { state: "starting"; detail?: string }
  | { state: "needs_login"; login: { step: "device_code"; url: string; code: string } }
  | { state: "ready" };

export interface DeviceAuth {
  url: string;
  code: string;
  /** From "(expires in N minutes)", in seconds; null when the line is not there. */
  expiresInS: number | null;
}

/** At most one `codex login --device-auth` start per this window. */
export const RESTART_THROTTLE_MS = 60_000;

const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g;
/** Only OpenAI's own sign-in host. Anything else is not a Codex device login and is not shown. */
const DEVICE_URL = /^https:\/\/auth\.openai\.com\/[A-Za-z0-9/_-]*$/;
/** Core keeps a code only when it matches this (reconciler.ex); so does the host. */
export const DEVICE_CODE = /^[A-Z0-9-]{4,16}$/;
const CODE_SHAPE = /^[A-Z0-9]+(?:-[A-Z0-9]+)+$/;

export function stripAnsi(text: string): string {
  return text.replace(ANSI, "");
}

/**
 * The URL and code from `codex login --device-auth`'s stdout so far, or null
 * until both have been printed. Each value is the trimmed line FOLLOWING its
 * numbered instruction, as measured; a value of any other shape is refused.
 */
export function parseDeviceAuth(stdout: string): DeviceAuth | null {
  const lines = stripAnsi(stdout).split(/\r?\n/).map((l) => l.trim());
  let url: string | null = null;
  let code: string | null = null;
  let expiresInS: number | null = null;
  for (let i = 0; i < lines.length - 1; i++) {
    const line = lines[i]!;
    const next = lines[i + 1]!;
    if (/^1\.\s.*\blink\b/i.test(line) && DEVICE_URL.test(next)) url = next;
    if (/^2\.\s.*\bone-time code\b/i.test(line) && CODE_SHAPE.test(next) && DEVICE_CODE.test(next)) {
      code = next;
      const m = /expires in (\d+) minutes?/i.exec(line);
      expiresInS = m ? Number(m[1]) * 60 : null;
    }
  }
  return url !== null && code !== null ? { url, code, expiresInS } : null;
}

/** burrow-cli's `codexHomeFor({}, root)`: the agent's Codex home inside its work dir. */
export function codexHomeFor(workDir: string): string {
  return join(workDir, ".codex");
}

/**
 * Codex's environment: what a CLI needs to run and reach OpenAI, plus its
 * home. Nothing from the agent's env file (an API key there is not Codex's).
 */
export function codexEnv(env: Record<string, string | undefined>, codexHome: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of ["PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "HTTPS_PROXY", "NO_PROXY"]) {
    const v = env[k];
    if (v !== undefined && v !== "") out[k] = v;
  }
  out.CODEX_HOME = codexHome;
  return out;
}

export interface LoginChild {
  /** Resolves with the exit code. */
  exited: Promise<number>;
  kill(): void;
}

export interface CodexLoginIo {
  /** Start a child; `onStdout` receives each stdout chunk as text. Its stderr is the unit's journal. */
  start(argv: string[], env: Record<string, string>, onStdout: (chunk: string) => void): LoginChild;
  /** Run a child to completion; only its exit code is read. */
  exitCode(argv: string[], env: Record<string, string>): Promise<number>;
  writeStatus(status: CodexStatus): void;
  now(): number;
  sleep(ms: number): Promise<void>;
  log(line: string): void;
  stopping(): boolean;
}

export interface CodexLoginOptions {
  codexBin: string;
  codexHome: string;
  env: Record<string, string>;
}

/** `codex login status`: exit 0 is logged in (burrow-cli codex.ts `codexLoggedIn`, re-measured on 0.162.0). */
export async function codexLoggedIn(io: CodexLoginIo, opts: CodexLoginOptions): Promise<boolean> {
  return (await io.exitCode([opts.codexBin, "login", "status"], opts.env)) === 0;
}

/**
 * One `codex login --device-auth`, as this agent. As soon as its stdout
 * carries the URL and the code, the status file says
 * `{state: "needs_login", login: {step: "device_code", url, code}}`; nothing
 * else from that output is kept. Resolves with the child's exit code.
 */
export async function startDeviceLogin(agentId: string, io: CodexLoginIo, opts: CodexLoginOptions): Promise<number> {
  let seen = "";
  let shown = false;
  const child = io.start([opts.codexBin, "login", "--device-auth"], opts.env, (chunk) => {
    if (shown) return;
    seen += chunk;
    const auth = parseDeviceAuth(seen);
    if (auth === null) return;
    shown = true;
    seen = "";
    io.writeStatus({ state: "needs_login", login: { step: "device_code", url: auth.url, code: auth.code } });
    const expiry = auth.expiresInS === null ? "" : `, expires in ${Math.round(auth.expiresInS / 60)} min`;
    // The code is not a credential, but there is no reason for it in a log.
    io.log(`agent ${agentId}: codex device login waiting for its owner on auth.openai.com${expiry}`);
  });
  const exitCode = await child.exited;
  if (!shown) io.log(`agent ${agentId}: codex login --device-auth exited ${exitCode} before printing a code`);
  return exitCode;
}

/**
 * Until Codex is logged in: a device login, and another when one ends
 * without a login (the code expired), at most one start per
 * {@link RESTART_THROTTLE_MS}. True once `codex login status` exits 0; false
 * when the unit is stopping.
 */
export async function ensureCodexLogin(agentId: string, io: CodexLoginIo, opts: CodexLoginOptions): Promise<boolean> {
  let lastStart: number | null = null;
  for (;;) {
    if (io.stopping()) return false;
    if (await codexLoggedIn(io, opts)) {
      io.writeStatus({ state: "starting" });
      return true;
    }
    if (lastStart !== null) {
      const wait = lastStart + RESTART_THROTTLE_MS - io.now();
      if (wait > 0) await io.sleep(wait);
      if (io.stopping()) return false;
    }
    lastStart = io.now();
    const exitCode = await startDeviceLogin(agentId, io, opts);
    // Exit 0 is not trusted on its own: `codex login status` decides.
    if (exitCode !== 0) io.log(`agent ${agentId}: codex device login ended (exit ${exitCode}); starting a fresh one`);
  }
}

/** Write the status file the agent host reads: temp file and rename, so a reader never sees half of it. */
export function writeStatusFile(path: string, status: CodexStatus): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(status)}\n`, { mode: 0o600 });
  renameSync(tmp, path);
}
