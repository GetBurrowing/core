/**
 * Claude subscription login (core task 01a1b365 stage 1, claude_login.ts):
 * the URL parser against the MEASURED transcript (2.1.295), then the whole
 * host path against a stub `claude` (test/fixtures/claude-stub.sh) run for
 * real over a pipe, without runuser: the reply shapes, every outcome, the
 * restart on ok, and the leak scan.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SecretInArgv, SecretRegistry, assertNoSecretsInArgv, liveRunner, type Runner } from "../src/exec.ts";
import { Host } from "../src/host.ts";
import type { AgentsDeps, Observation } from "../src/agents.ts";
import {
  ClaudeLogin,
  LOGIN_URL,
  asAgent,
  isCodeShaped,
  liveLoginSpawn,
  outcome,
  parseAuthStatus,
  parseLoginUrl,
  type ClaudeLoginDeps,
} from "../src/claude_login.ts";
import { unitName, userName } from "../src/ids.ts";

const A = "01a1b365-0000-7000-8000-00000000000a";
const FIXTURES = resolve(import.meta.dir, "fixtures");
const TRANSCRIPT = readFileSync(join(FIXTURES, "claude-auth-login-2.1.295.txt"), "utf8");
const STUB = join(FIXTURES, "claude-stub.sh");
chmodSync(STUB, 0o755);

/** A unique code per run, shaped like what Anthropic's page shows (`<code>#<state>`). */
const SENTINEL = `SENTINEL-${crypto.randomUUID()}#STUBSTATE-code`;

describe("parseLoginUrl (measured transcript)", () => {
  test("POSITIVE CONTROL: the fixture is 2.1.295's login, with its paste prompt", () => {
    expect(TRANSCRIPT).toContain("2.1.295 (Claude Code)");
    expect(TRANSCRIPT).toContain("Paste code here if prompted >");
    expect(TRANSCRIPT).toContain("state=[redacted]");
  });

  test("reads the claude.com authorize URL from the pipe transcript", () => {
    const url = parseLoginUrl(TRANSCRIPT);
    expect(url).not.toBeNull();
    expect(url!.startsWith("https://claude.com/cai/oauth/authorize?code=true&")).toBe(true);
    expect(url).toContain("redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback");
    expect(url).toMatch(LOGIN_URL);
  });

  test("refuses every URL that is not Anthropic's own sign-in with a query", () => {
    for (const bad of [
      "visit: https://claude.com.attacker.invalid/cai/oauth/authorize?x=1",
      "visit: https://evil.invalid/?https://claude.com/x?",
      "visit: http://claude.com/cai/oauth/authorize?x=1",
      "visit: https://claude.com/cai/oauth/authorize",
      "visit: https://claude.co/cai/oauth/authorize?x=1",
      "visit: https://user@claude.com/cai?x=1",
      "visit: https://platform.claude.com/oauth/code/callback?x=1",
    ]) {
      expect([bad, parseLoginUrl(bad)]).toEqual([bad, null]);
    }
    expect(parseLoginUrl("visit: https://claude.ai/oauth/authorize?code=true")).toBe("https://claude.ai/oauth/authorize?code=true");
  });

  test("ANSI colour does not hide the URL", () => {
    expect(parseLoginUrl("\x1b[1mvisit: https://claude.com/cai/oauth/authorize?a=b\x1b[0m\n")).toBe("https://claude.com/cai/oauth/authorize?a=b");
  });
});

describe("code shape and outcome (pure)", () => {
  test("a code is printable ASCII with no whitespace, at most 512 bytes", () => {
    expect(isCodeShaped("abc#def")).toBe(true);
    expect(isCodeShaped("x".repeat(512))).toBe(true);
    for (const bad of ["", "a b", "a\nb", "a\tb", "x".repeat(513), "é#x", 42, null]) expect(isCodeShaped(bad)).toBe(false);
  });

  test("auth status decides, as measured: loggedIn, authMethod, subscriptionType", () => {
    const st = (o: object) => parseAuthStatus(JSON.stringify(o));
    expect(outcome(st({ loggedIn: false, authMethod: "none" }))).toEqual({ result: "bad_code" });
    expect(outcome(st({ loggedIn: true, authMethod: "claude.ai", email: "a@example.com", subscriptionType: "max" }))).toEqual({
      result: "ok",
      account: "a@example.com",
      plan: "max",
    });
    expect(outcome(st({ loggedIn: true, authMethod: "claude.ai", email: "a@example.com", subscriptionType: "pro" })).result).toBe("ok");
    expect(outcome(st({ loggedIn: true, authMethod: "claude.ai", email: "a@example.com", subscriptionType: "free" }))).toEqual({ result: "no_subscription" });
    expect(outcome(st({ loggedIn: true, authMethod: "claude.ai", email: "a@example.com" }))).toEqual({ result: "no_subscription" });
    // An API key in the env reads as logged in (measured): not a subscription login.
    expect(outcome(st({ loggedIn: true, authMethod: "api_key" }))).toEqual({ result: "failed" });
    expect(outcome(parseAuthStatus("not json"))).toEqual({ result: "failed" });
  });

  test("the child runs as the agent with an env built from nothing: no API key, no host token", () => {
    const argv = asAgent(A, "/home/x", ["claude", "auth", "login"]);
    expect(argv.slice(0, 6)).toEqual(["runuser", "-u", userName(A), "--", "env", "-i"]);
    expect(argv.join(" ")).not.toMatch(/ANTHROPIC|AGENT_HOST_TOKEN|TMUX/);
    expect(argv.slice(-3)).toEqual(["claude", "auth", "login"]);
  });
});

// ---------------------------------------------------------------------------
// The whole host path, against the stub, for real over a pipe.

interface Rig {
  home: string;
  host: Host;
  login: ClaudeLogin;
  secrets: SecretRegistry;
  pushed: { event: string; payload: Record<string, unknown> }[];
  logs: string[];
  argvs: string[][];
  violations: string[];
  restarts: string[][];
}

class StubHost extends Host {
  override async observe(agentId: string): Promise<Observation> {
    return { agent_id: agentId, state: "running", detail: null, files_applied: null };
  }
}

let rigs: Rig[] = [];

function rig(opts: { mode?: string; plan?: string; idleMs?: number; submitWaitMs?: number } = {}): Rig {
  const home = mkdtempSync(join(tmpdir(), "claude-login-"));
  mkdirSync(join(home, ".stub"));
  writeFileSync(join(home, ".stub", "good_sha"), createHash("sha256").update(SENTINEL).digest("hex"));
  if (opts.mode) writeFileSync(join(home, ".stub", "mode"), opts.mode);
  if (opts.plan) writeFileSync(join(home, ".stub", "plan"), opts.plan);
  const secrets = new SecretRegistry();
  const argvs: string[][] = [];
  const violations: string[] = [];
  const restarts: string[][] = [];
  const logs: string[] = [];
  // Every argv passes the same check the live runner makes, and is recorded.
  const check = (argv: string[]) => {
    argvs.push([...argv]);
    try {
      assertNoSecretsInArgv(argv, secrets);
    } catch (e) {
      violations.push((e as Error).name);
      throw e;
    }
  };
  // No runuser here: the `runuser -u <agent> --` prefix is checked, then dropped.
  const strip = (argv: string[]) => {
    expect(argv.slice(0, 4)).toEqual(["runuser", "-u", userName(A), "--"]);
    return argv.slice(4);
  };
  const real = liveRunner(new SecretRegistry());
  const runner: Runner = {
    async run(argv, o) {
      check(argv);
      if (argv[0] === "systemctl") {
        restarts.push([...argv]);
        return { exitCode: 0, stdout: "", stderr: "" };
      }
      return real.run(strip(argv), o);
    },
  };
  const spawnReal = liveLoginSpawn(secrets, () => {});
  const spawn: ClaudeLoginDeps["spawn"] = (argv, cwd, onOutput) => {
    check(argv);
    return spawnReal(strip(argv), cwd, onOutput);
  };
  const log = (l: string) => logs.push(l);
  const login = new ClaudeLogin({
    spawn,
    runner,
    secrets,
    log,
    claudeBin: STUB,
    home: () => home,
    urlWaitMs: 3_000,
    submitWaitMs: opts.submitWaitMs ?? 3_000,
    idleMs: opts.idleMs,
  });
  const deps: AgentsDeps = { runner, secrets, runnerCommand: ["x"], log };
  const pushed: Rig["pushed"] = [];
  const host = new StubHost(
    deps,
    { push: async (event, payload) => (pushed.push({ event, payload: JSON.parse(JSON.stringify(payload)) }), "ok") },
    "contained",
    undefined,
    false,
    null,
    undefined,
    login,
  );
  const r = { home, host, login, secrets, pushed, logs, argvs, violations, restarts };
  rigs.push(r);
  return r;
}

afterEach(() => {
  for (const r of rigs) {
    r.login.end(A);
    rmSync(r.home, { recursive: true, force: true });
  }
  rigs = [];
});

const start = (r: Rig, ref = "s1") => r.host.handleClaudeLoginStart({ agent_id: A, ref });
const submit = (r: Rig, code: unknown, ref = "c1") => r.host.handleClaudeLoginCode({ agent_id: A, ref, code } as Record<string, unknown>);
const replies = (r: Rig) => r.pushed.filter((p) => p.event === "agent.claude_login").map((p) => p.payload);

describe("agent.claude_login_start", () => {
  test("replies {ref, agent_id, result: url, url} with the stub's claude.com URL, and nothing else is pushed", async () => {
    const r = rig();
    await start(r);
    expect(r.pushed.map((p) => p.event)).toEqual(["agent.claude_login"]);
    const [reply] = replies(r);
    expect(Object.keys(reply!).sort()).toEqual(["agent_id", "ref", "result", "url"]);
    expect(reply).toMatchObject({ ref: "s1", agent_id: A, result: "url" });
    expect(String(reply!.url)).toMatch(LOGIN_URL);
    expect(String(reply!.url)).toContain("state=STUBSTATE");
    // It ran the agent's own CLI, as the agent, with `auth login --claudeai`.
    expect(r.argvs[0]!.slice(0, 4)).toEqual(["runuser", "-u", userName(A), "--"]);
    expect(r.argvs[0]!.slice(-3)).toEqual(["auth", "login", "--claudeai"]);
    expect(r.login.pending(A)).toBe(true);
  });

  test("a non-claude URL is refused: result failed, no url, the login ended", async () => {
    const r = rig({ mode: "badurl" });
    await start(r);
    expect(replies(r)).toEqual([{ ref: "s1", agent_id: A, result: "failed" }]);
    expect(r.login.pending(A)).toBe(false);
    expect(JSON.stringify(r.pushed)).not.toContain("attacker");
  });

  test("a login that prints no URL is failed after the wait", async () => {
    const r = rig({ mode: "nourl" });
    await start(r);
    expect(replies(r)).toEqual([{ ref: "s1", agent_id: A, result: "failed" }]);
    expect(r.login.pending(A)).toBe(false);
  });

  test("one login per agent: a second start ends the first", async () => {
    const r = rig();
    await start(r, "s1");
    const first = (r.login as unknown as { sessions: Map<string, { proc: { exited: Promise<number> } }> }).sessions.get(A)!.proc;
    await start(r, "s2");
    const code = await Promise.race([first.exited, new Promise((res) => setTimeout(() => res("still running"), 2_000))]);
    expect(code).not.toBe("still running");
    expect(r.login.pending(A)).toBe(true);
    expect(replies(r).map((x) => x.ref)).toEqual(["s1", "s2"]);
  });

  test("a login nobody finishes is ended when idle; a code then gets no_session", async () => {
    const r = rig({ idleMs: 200 });
    await start(r);
    await new Promise((res) => setTimeout(res, 600));
    expect(r.login.pending(A)).toBe(false);
    await submit(r, SENTINEL);
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "no_session" });
    expect(r.restarts).toEqual([]);
  });
});

describe("agent.claude_login_code outcomes", () => {
  test("ok: the known-good code logs in; account and plan come from auth status; the unit restarts", async () => {
    const r = rig();
    await start(r);
    await submit(r, SENTINEL);
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "ok", account: "owner@example.com", plan: "max" });
    expect(r.restarts).toEqual([["systemctl", "restart", unitName(A)]]);
    // The restart is reported like any start: an agent.state after the reply.
    expect(r.pushed.map((p) => p.event)).toEqual(["agent.claude_login", "agent.claude_login", "agent.state"]);
    expect(r.login.pending(A)).toBe(false);
  });

  test("bad_code: a wrong code the CLI rejects; no restart", async () => {
    const r = rig();
    await start(r);
    await submit(r, "WRONG-code#STUBSTATE");
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "bad_code" });
    expect(r.restarts).toEqual([]);
    expect(r.login.pending(A)).toBe(false);
  });

  test("bad_code: a code without '#' that the CLI re-prompts for is ended after the wait, and status decides", async () => {
    const r = rig({ submitWaitMs: 800 });
    await start(r);
    await submit(r, "NOHASHCODE");
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "bad_code" });
    expect(r.login.pending(A)).toBe(false);
  });

  test("a login that never ends after the code is decided by auth status, not by the child", async () => {
    const r = rig({ mode: "hang", submitWaitMs: 800 });
    await start(r);
    await submit(r, SENTINEL);
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "bad_code" });
  });

  test("bad_code without touching the login: a code that is not code-shaped", async () => {
    const r = rig();
    await start(r);
    await submit(r, "has space");
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "bad_code" });
    expect(r.login.pending(A)).toBe(true);
    expect(r.argvs).toHaveLength(1);
  });

  test("no_subscription: logged in on a plan that is not pro or max, then logged out again", async () => {
    const r = rig({ plan: "free" });
    await start(r);
    await submit(r, SENTINEL);
    expect(replies(r)[1]).toEqual({ ref: "c1", agent_id: A, result: "no_subscription" });
    expect(r.restarts).toEqual([]);
    expect(parseAuthStatus((await liveRunner(new SecretRegistry()).run([STUB, "auth", "status", "--json"], { env: { HOME: r.home, PATH: "/usr/bin:/bin" } })).stdout)?.loggedIn).toBe(false);
  });

  test("no_session: a code with no login started", async () => {
    const r = rig();
    await submit(r, SENTINEL);
    expect(replies(r)).toEqual([{ ref: "c1", agent_id: A, result: "no_session" }]);
    expect(r.argvs).toEqual([]);
  });

  test("agent.claude_logout: claude auth logout as the agent; status decides", async () => {
    const r = rig();
    await start(r);
    await submit(r, SENTINEL);
    await r.host.handleClaudeLogout({ agent_id: A, ref: "o1" });
    expect(replies(r)[2]).toEqual({ ref: "o1", agent_id: A, result: "ok" });
    expect(r.argvs.some((a) => a.slice(-2).join(" ") === "auth logout")).toBe(true);
  });

  test("a command without an agent id or ref does nothing", async () => {
    const r = rig();
    await r.host.handleClaudeLoginStart({ agent_id: "nope", ref: "x" });
    await r.host.handleClaudeLoginCode({ agent_id: A, code: SENTINEL });
    expect(r.pushed).toEqual([]);
    expect(r.argvs).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// LEAK: the sentinel code reaches the stub's stdin and nothing else.

function filesUnder(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const s = statSync(p);
    if (s.isDirectory()) filesUnder(p, out);
    else out.push(p);
  }
  return out;
}

/** Every sink a leak could land in, as text. */
function sinks(r: Rig, consoleOut: string[]): Record<string, string> {
  return {
    logs: r.logs.join("\n"),
    console: consoleOut.join("\n"),
    pushes: JSON.stringify(r.pushed),
    agent_state: JSON.stringify(r.pushed.filter((p) => p.event === "agent.state")),
    argv: JSON.stringify(r.argvs),
    files: filesUnder(r.home)
      .map((f) => readFileSync(f, "utf8"))
      .join("\n"),
    registry: JSON.stringify(r.secrets.values()),
  };
}

function leaks(all: Record<string, string>, needle: string): string[] {
  return Object.entries(all)
    .filter(([, text]) => text.includes(needle))
    .map(([name]) => name);
}

describe("LEAK: the code and the URL stay where they belong", () => {
  const consoleOut: string[] = [];
  const saved = { log: console.log, error: console.error, warn: console.warn, info: console.info };
  beforeEach(() => {
    consoleOut.length = 0;
    for (const k of ["log", "error", "warn", "info"] as const) console[k] = (...a: unknown[]) => void consoleOut.push(a.map(String).join(" "));
  });
  afterEach(() => Object.assign(console, saved));

  test("POSITIVE CONTROL: the same scan finds the sentinel when it is put in each sink", () => {
    const r = rig();
    r.logs.push(`x ${SENTINEL}`);
    consoleOut.push(SENTINEL);
    r.pushed.push({ event: "agent.state", payload: { detail: SENTINEL } });
    r.argvs.push(["echo", SENTINEL]);
    writeFileSync(join(r.home, "status.json"), SENTINEL);
    r.secrets.add(SENTINEL);
    expect(leaks(sinks(r, consoleOut), SENTINEL).sort()).toEqual(["agent_state", "argv", "console", "files", "logs", "pushes", "registry"]);
  });

  test("a full ok login: the sentinel is in no log, console line, push, agent.state, argv, file in HOME or held secret", async () => {
    const r = rig();
    await start(r);
    const payload: Record<string, unknown> = { agent_id: A, ref: "c1", code: SENTINEL };
    await r.host.handleClaudeLoginCode(payload);
    // It really logged in with that code, so the code really reached the stub.
    expect(replies(r)[1]).toMatchObject({ result: "ok" });
    expect(leaks(sinks(r, consoleOut), SENTINEL)).toEqual([]);
    // The handler took the code out of the payload it was given.
    expect("code" in payload).toBe(false);
    expect(r.violations).toEqual([]);
  });

  test("the daemon's own logs never carry the URL, its state, or the CLI's transcript", async () => {
    const r = rig();
    await start(r);
    await submit(r, "WRONG-code#STUBSTATE");
    await start(r, "s2");
    await submit(r, SENTINEL, "c2");
    const daemon = [...r.logs, ...consoleOut].join("\n");
    // Positive control: the daemon did log the login's lifecycle.
    expect(daemon).toContain("claude login waiting for its owner's code");
    expect(daemon).toContain("claude login: ok");
    for (const needle of ["STUBSTATE", "STUBCHALLENGE", "oauth", "claude.com", "Paste code", "Login failed", "Opening browser", "stub-stderr-transcript-marker", "WRONG-code"]) {
      expect([needle, daemon.includes(needle)]).toEqual([needle, false]);
    }
    // The URL is in exactly the two start replies and in no other push.
    const withUrl = r.pushed.filter((p) => JSON.stringify(p).includes("oauth/authorize"));
    expect(withUrl.map((p) => [p.event, p.payload.result, p.payload.ref])).toEqual([
      ["agent.claude_login", "url", "s1"],
      ["agent.claude_login", "url", "s2"],
    ]);
  });

  test("SecretInArgv: while its submit runs the code is held, so an argv carrying it is refused", async () => {
    const r = rig();
    await start(r);
    let heldDuringSubmit = false;
    const inner = (r.login as unknown as { deps: ClaudeLoginDeps }).deps.runner;
    (r.login as unknown as { deps: ClaudeLoginDeps }).deps.runner = {
      run: (argv, o) => {
        if (argv.includes("status")) {
          heldDuringSubmit = r.secrets.values().includes(SENTINEL);
          // Positive control, same registry, same window: an argv with the code is refused.
          expect(() => assertNoSecretsInArgv(["tmux", "send-keys", SENTINEL], r.secrets)).toThrow(SecretInArgv);
        }
        return inner.run(argv, o);
      },
    };
    await submit(r, SENTINEL);
    expect(heldDuringSubmit).toBe(true);
    expect(r.violations).toEqual([]);
    expect(replies(r)[1]).toMatchObject({ result: "ok" });
    // Dropped once the submit is over.
    expect(r.secrets.values()).not.toContain(SENTINEL);
  });
});

describe("claude_login.ts never reaches a tmux session or a pane", () => {
  test("no tmux, send-keys, paste or load buffer in the module", () => {
    const src = readFileSync(resolve(import.meta.dir, "../src/claude_login.ts"), "utf8");
    const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    // Positive control: the stripped source still names the CLI it runs.
    expect(code).toContain('"auth", "login"');
    expect(code).not.toMatch(/tmux|send-keys|paste-buffer|load-buffer|capture-pane/);
  });
});
