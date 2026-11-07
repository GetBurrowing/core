/**
 * Claude Code's own subscription login (`claude auth login`), driven for a
 * native agent that has no terminal (core task 01a1b365 stage 1).
 *
 * WHAT CHANGED, AND WHY. Until this task Burrow never relayed a Claude login
 * (core task 01a17b10): a Claude Pro or Max owner had to reach the agent's
 * own pane over a terminal. Task 01a1b365 lets the owner sign in on
 * Anthropic's page in their own browser and paste the code that page shows
 * into Burrow, which hands it to THIS agent's own, unmodified
 * `claude auth login` on the same install. Sign-in itself still happens on
 * Anthropic's page. Whether core may send the code at all is decided in core
 * (stage 2 of that task); this module only takes it if it arrives.
 *
 * MEASURED, not remembered (Claude Code 2.1.295, a throwaway node:22
 * container, fresh HOME, no account, no login completed, 2026-11-07; the
 * transcript, state and challenge redacted, is
 * test/fixtures/claude-auth-login-2.1.295.txt):
 *
 *   - there is no device-code or polling login for claude.ai. `claude auth
 *     login` prints "If the browser didn't open, visit:
 *     https://claude.com/cai/oauth/authorize?code=true&...&code_challenge=...
 *     &state=..." and waits at "Paste code here if prompted >". The code is
 *     bound to the PKCE verifier THAT process holds, so the URL must come from
 *     it and the same process must receive the code;
 *   - A PLAIN PIPE WORKS. With no tty on stdin or stdout the CLI still prints
 *     the URL and reads the code from stdin. So this module uses a pipe, not
 *     a tmux pty: the code goes to the child's stdin and nowhere else. It is
 *     never in a tmux paste buffer, never in scrollback, never typed into any
 *     pane (pane.ts stays read only), and never in an argv (exec.ts
 *     SecretInArgv);
 *   - a code shaped `<code>#<state>` is sent to Anthropic's token endpoint (a
 *     made-up one: "Login failed: Request failed with status code 400", exit
 *     1). A line without `#` gets "Invalid code. Please make sure the full
 *     code was copied." and the CLI waits for another line. EOF on stdin does
 *     not end it; SIGTERM does;
 *   - `claude auth status --json` exits 1 with `loggedIn: false` when not
 *     logged in, and an ANTHROPIC_API_KEY in the env reads as logged in with
 *     `authMethod: "api_key"`. So the login child's env is built here from
 *     nothing (`env -i`): the agent's env file, and any API key in it, never
 *     reaches it.
 *
 * The outcome is decided ONLY by `claude auth status --json` (loggedIn,
 * authMethod "claude.ai", email, subscriptionType; org journal 2026-08-13),
 * never by the child's exit code or its output.
 *
 * WHAT LEAVES THIS MODULE. The sign-in URL goes only into the ref'd
 * `agent.claude_login` reply to the start that asked for it: never a status
 * file, an observation, `agent.state`, the inventory or a log line. The
 * child's output (stdout and stderr) is read only to find that URL, then
 * discarded; it is never logged. The code is never logged, echoed, stored or
 * put in an argv; it is held in the {@link SecretRegistry} only while its
 * submit runs, so any argv carrying it in that window is refused.
 *
 * Runs as the agent's own uid (`runuser`, like every write into its home),
 * so Claude's credentials land in the agent's home and are never read here.
 */
import type { Runner, SecretRegistry } from "./exec.ts";
import { homeDir, isAgentId, unitName, userName } from "./ids.ts";

/** Only Anthropic's own sign-in hosts, and a query (the PKCE request). Anything else is never sent. */
export const LOGIN_URL = /^https:\/\/claude\.(com|ai)\/[A-Za-z0-9/_.-]*\?[\x21-\x7e]*$/;
export const MAX_URL = 4096;
/** A pasted code: printable ASCII, no whitespace, at most 512 bytes. */
export const CODE_SHAPE = /^[\x21-\x7e]{1,512}$/;

/** How long a start waits for the URL. */
export const URL_WAIT_MS = 30_000;
/** How long a submit waits for the login child to end before asking `claude auth status`. */
export const SUBMIT_WAIT_MS = 30_000;
/** A login nobody finished is ended after this long. */
export const IDLE_MS = 10 * 60_000;

/** Plans a Burrow agent may run on. */
export const SUBSCRIPTION_PLANS = new Set(["pro", "max"]);

export type StartReply = { result: "url"; url: string } | { result: "failed" };
export type CodeReply =
  | { result: "ok"; account: string; plan: string }
  | { result: "bad_code" | "no_subscription" | "no_session" | "failed" };
export type LogoutReply = { result: "ok" | "failed" };

export interface AuthStatus {
  loggedIn: boolean;
  authMethod: string | null;
  email: string | null;
  subscriptionType: string | null;
}

/** A running `claude auth login`. */
export interface LoginProcess {
  /** Bytes for its stdin. */
  write(text: string): void;
  closeStdin(): void;
  exited: Promise<number>;
  kill(): void;
}

export interface ClaudeLoginDeps {
  /** Start a long-lived child; `onOutput` gets its stdout and stderr as text. */
  spawn(argv: string[], cwd: string, onOutput: (chunk: string) => void): LoginProcess;
  /** For `claude auth status` / `logout` (as the agent) and nothing else. */
  runner: Runner;
  secrets: SecretRegistry;
  log(line: string): void;
  claudeBin?: string;
  /** The agent's home. Defaults to ids.ts `homeDir`. */
  home?: (agentId: string) => string;
  urlWaitMs?: number;
  submitWaitMs?: number;
  idleMs?: number;
}

const ANSI = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07/g;

/** The first claude.com / claude.ai sign-in URL in the output so far, or null. Pure. */
export function parseLoginUrl(output: string): string | null {
  for (const line of output.replace(ANSI, "").split(/\r?\n/)) {
    for (const m of line.matchAll(/https?:\/\/[^\s]+/g)) {
      const url = m[0];
      if (url.length <= MAX_URL && LOGIN_URL.test(url)) return url;
    }
  }
  return null;
}

export function isCodeShaped(code: unknown): code is string {
  return typeof code === "string" && CODE_SHAPE.test(code);
}

/**
 * The child's whole environment, from nothing: what Claude needs to run and
 * reach Anthropic, as the agent. No value from the agent's env file (an
 * ANTHROPIC_API_KEY there would win over the subscription) and none from
 * this daemon's (AGENT_HOST_TOKEN).
 */
export function loginEnv(agentId: string, home: string): string[] {
  return [
    `HOME=${home}`,
    `USER=${userName(agentId)}`,
    `PATH=${home}/.local/bin:/usr/local/bin:/usr/bin:/bin`,
    "LANG=C.UTF-8",
    "DISABLE_AUTOUPDATER=1",
    "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
  ];
}

/** `runuser -u <agent> -- env -i <loginEnv> <rest>`. */
export function asAgent(agentId: string, home: string, rest: string[]): string[] {
  if (!isAgentId(agentId)) throw new Error("not an agent id");
  return ["runuser", "-u", userName(agentId), "--", "env", "-i", ...loginEnv(agentId, home), ...rest];
}

/** `claude auth status --json`'s stdout, or null when it is not that JSON. Pure. */
export function parseAuthStatus(stdout: string): AuthStatus | null {
  let v: unknown;
  try {
    v = JSON.parse(stdout);
  } catch {
    return null;
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (typeof o.loggedIn !== "boolean") return null;
  const str = (x: unknown): string | null => (typeof x === "string" && x !== "" ? x : null);
  return { loggedIn: o.loggedIn, authMethod: str(o.authMethod), email: str(o.email), subscriptionType: str(o.subscriptionType) };
}

/** The reply for a status read after a code was written. Pure. */
export function outcome(status: AuthStatus | null): CodeReply {
  if (status === null) return { result: "failed" };
  if (!status.loggedIn) return { result: "bad_code" };
  if (status.authMethod !== "claude.ai") return { result: "failed" };
  const plan = (status.subscriptionType ?? "").toLowerCase();
  if (!SUBSCRIPTION_PLANS.has(plan)) return { result: "no_subscription" };
  const account = status.email ?? "";
  if (account.length > 320 || /[\x00-\x1f\x7f]/.test(account)) return { result: "failed" };
  return { result: "ok", account, plan };
}

interface Session {
  proc: LoginProcess;
  done: boolean;
  timer: ReturnType<typeof setTimeout>;
}

/** `p`, or "timeout" after `ms`; the timer never outlives the race. */
async function within<T>(p: Promise<T>, ms: number): Promise<T | "timeout"> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([p, new Promise<"timeout">((r) => (timer = setTimeout(() => r("timeout"), ms)))]);
  } finally {
    clearTimeout(timer);
  }
}

export class ClaudeLogin {
  private readonly sessions = new Map<string, Session>();
  private readonly claudeBin: string;
  private readonly home: (agentId: string) => string;
  private readonly urlWaitMs: number;
  private readonly submitWaitMs: number;
  private readonly idleMs: number;

  constructor(private readonly deps: ClaudeLoginDeps) {
    this.claudeBin = deps.claudeBin ?? "claude";
    this.home = deps.home ?? homeDir;
    this.urlWaitMs = deps.urlWaitMs ?? URL_WAIT_MS;
    this.submitWaitMs = deps.submitWaitMs ?? SUBMIT_WAIT_MS;
    this.idleMs = deps.idleMs ?? IDLE_MS;
  }

  /** True while a login for this agent is waiting for its code. */
  pending(agentId: string): boolean {
    const s = this.sessions.get(agentId);
    return s !== undefined && !s.done;
  }

  /** End this agent's login, if one is running. */
  end(agentId: string): void {
    const s = this.sessions.get(agentId);
    if (s === undefined) return;
    this.sessions.delete(agentId);
    clearTimeout(s.timer);
    if (!s.done) s.proc.kill();
    s.done = true;
  }

  /**
   * `agent.claude_login_start`: a fresh `claude auth login` as the agent (a
   * second start ends the first), and its sign-in URL once it prints one.
   */
  async start(agentId: string): Promise<StartReply> {
    this.end(agentId);
    const home = this.home(agentId);
    let url: string | null = null;
    let seen = "";
    let found: (u: string) => void = () => {};
    const gotUrl = new Promise<string>((r) => (found = r));
    let proc: LoginProcess;
    try {
      proc = this.deps.spawn(asAgent(agentId, home, [this.claudeBin, "auth", "login", "--claudeai"]), home, (chunk) => {
        // After the URL, the output is not read at all.
        if (url !== null) return;
        seen = (seen + chunk).slice(-16_384);
        const u = parseLoginUrl(seen);
        if (u === null) return;
        url = u;
        seen = "";
        found(u);
      });
    } catch (error) {
      this.deps.log(`agent ${agentId}: claude auth login did not start (${error instanceof Error ? error.name : "error"})`);
      return { result: "failed" };
    }
    const session: Session = { proc, done: false, timer: setTimeout(() => {}, 0) };
    void proc.exited.then(() => {
      session.done = true;
      clearTimeout(session.timer);
      if (this.sessions.get(agentId) === session) this.sessions.delete(agentId);
    });
    this.sessions.set(agentId, session);
    const first = await within(Promise.race([gotUrl, proc.exited.then(() => "exited" as const)]), this.urlWaitMs);
    if (url === null || session.done) {
      this.end(agentId);
      this.deps.log(`agent ${agentId}: claude auth login printed no sign-in URL (${first === "exited" ? "it exited" : "timed out"})`);
      return { result: "failed" };
    }
    clearTimeout(session.timer);
    session.timer = setTimeout(() => {
      if (this.sessions.get(agentId) !== session) return;
      this.end(agentId);
      this.deps.log(`agent ${agentId}: claude login ended after ${Math.round(this.idleMs / 60_000)} min with no code`);
    }, this.idleMs);
    (session.timer as { unref?: () => void }).unref?.();
    this.deps.log(`agent ${agentId}: claude login waiting for its owner's code`);
    return { result: "url", url };
  }

  /**
   * `agent.claude_login_code`: the owner's pasted code, written once to the
   * waiting login's stdin. The login then ends either way, and
   * `claude auth status --json` decides the reply.
   */
  async submit(agentId: string, code: unknown): Promise<CodeReply> {
    if (!isCodeShaped(code)) {
      this.deps.log(`agent ${agentId}: claude login code refused: not code-shaped`);
      return { result: "bad_code" };
    }
    const session = this.sessions.get(agentId);
    if (session === undefined || session.done) {
      this.deps.log(`agent ${agentId}: claude login code arrived with no login waiting`);
      return { result: "no_session" };
    }
    const fresh = !this.deps.secrets.values().includes(code);
    this.deps.secrets.add(code);
    try {
      try {
        session.proc.write(`${code}\n`);
        session.proc.closeStdin();
      } catch (error) {
        this.end(agentId);
        this.deps.log(`agent ${agentId}: the code could not be written to claude auth login (${error instanceof Error ? error.name : "error"})`);
        return { result: "failed" };
      }
      await within(session.proc.exited, this.submitWaitMs);
      this.end(agentId);
      const reply = outcome(await this.status(agentId));
      if (reply.result === "no_subscription") {
        // Signed in, but not with a plan this agent can run on: do not leave
        // the agent on that account.
        await this.deps.runner.run(asAgent(agentId, this.home(agentId), [this.claudeBin, "auth", "logout"]), { cwd: this.home(agentId) });
      }
      this.deps.log(`agent ${agentId}: claude login: ${reply.result}`);
      return reply;
    } finally {
      if (fresh) this.deps.secrets.remove(code);
    }
  }

  /** `claude auth status --json` as the agent; null when it cannot be read. */
  async status(agentId: string): Promise<AuthStatus | null> {
    const home = this.home(agentId);
    const r = await this.deps.runner.run(asAgent(agentId, home, [this.claudeBin, "auth", "status", "--json"]), { cwd: home });
    return parseAuthStatus(r.stdout);
  }

  /** `agent.claude_logout`: ends a waiting login, then `claude auth logout`; status decides. */
  async logout(agentId: string): Promise<LogoutReply> {
    this.end(agentId);
    const home = this.home(agentId);
    await this.deps.runner.run(asAgent(agentId, home, [this.claudeBin, "auth", "logout"]), { cwd: home });
    const status = await this.status(agentId);
    const result = status !== null && !status.loggedIn ? "ok" : "failed";
    this.deps.log(`agent ${agentId}: claude logout: ${result}`);
    return { result };
  }
}

/** The argv that restarts the agent's unit after a login, so `burrow claude` starts logged in. */
export function restartArgv(agentId: string): string[] {
  return ["systemctl", "restart", unitName(agentId)];
}

/**
 * The live spawn: argv checked against the registry first (exec.ts), stdin a
 * pipe, stdout and stderr read here and never inherited, so the child's
 * output can never reach this daemon's journal.
 */
export function liveLoginSpawn(secrets: SecretRegistry, check: (argv: string[], secrets: SecretRegistry) => void): ClaudeLoginDeps["spawn"] {
  return (argv, cwd, onOutput) => {
    check(argv, secrets);
    const proc = Bun.spawn(argv, { cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    const pump = async (stream: ReadableStream<Uint8Array>) => {
      const decoder = new TextDecoder();
      for await (const chunk of stream) onOutput(decoder.decode(chunk, { stream: true }));
    };
    void pump(proc.stdout).catch(() => {});
    void pump(proc.stderr).catch(() => {});
    return {
      write: (text) => {
        proc.stdin.write(text);
        void proc.stdin.flush();
      },
      closeStdin: () => void proc.stdin.end(),
      exited: proc.exited,
      kill: () => proc.kill(),
    };
  };
}
