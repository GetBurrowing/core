/**
 * Codex's device login (core task 01a10315 stage 4): the stdout parser
 * against the MEASURED transcript (codex-cli 0.162.0; only the one-time code
 * is replaced), what the host reports for a device_code status, codex in
 * agent.start, the restart-on-expiry throttle and the runner's codex loop.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import {
  RESTART_THROTTLE_MS,
  codexEnv,
  codexHomeFor,
  ensureCodexLogin,
  parseDeviceAuth,
  startDeviceLogin,
  stripAnsi,
  type CodexLoginIo,
  type CodexStatus,
} from "../src/codex_login.ts";
import { SUPPORTED_HARNESSES, deviceLogin, observe, parseShow, parseStart, renderEnvFile } from "../src/agents.ts";
import { isAgentEnvName } from "../src/ids.ts";
import { isSecretFile } from "../src/files.ts";
import { CODEX_BRIDGE, runCodexAgent, type RunnerIo } from "../src/runner.ts";

const A = "01a10322-e24f-7001-8356-98259d347cbe";
const TRANSCRIPT = readFileSync(resolve(import.meta.dir, "fixtures/codex-device-auth-0.162.0.txt"), "utf8");
const OPTS = { codexBin: "codex", codexHome: "/home/agent-98259d347cbe/work/.codex", env: { CODEX_HOME: "/home/agent-98259d347cbe/work/.codex" } };

describe("parseDeviceAuth (measured transcript)", () => {
  test("POSITIVE CONTROL: the fixture is the coloured output codex prints to a pipe", () => {
    expect(TRANSCRIPT).toContain("\x1b[94m");
    expect(stripAnsi(TRANSCRIPT)).toContain("2. Enter this one-time code (expires in 15 minutes)");
  });

  test("reads the URL, the code and the expiry", () => {
    expect(parseDeviceAuth(TRANSCRIPT)).toEqual({ url: "https://auth.openai.com/codex/device", code: "WXYZ-9K8LM", expiresInS: 900 });
  });

  test("nothing until both the URL and the code have arrived", () => {
    const cut = TRANSCRIPT.indexOf("2. Enter");
    expect(parseDeviceAuth(TRANSCRIPT.slice(0, cut))).toBeNull();
    expect(parseDeviceAuth("")).toBeNull();
  });

  test("a URL on any other host is not a Codex device login", () => {
    expect(parseDeviceAuth(TRANSCRIPT.replace("auth.openai.com", "claude.com"))).toBeNull();
    expect(parseDeviceAuth(TRANSCRIPT.replace("https://auth.openai.com/codex/device", "http://auth.openai.com/codex/device"))).toBeNull();
  });

  test("a code of another shape is refused", () => {
    expect(parseDeviceAuth(TRANSCRIPT.replace("WXYZ-9K8LM", "wxyz-9k8lm"))).toBeNull();
    expect(parseDeviceAuth(TRANSCRIPT.replace("WXYZ-9K8LM", "WXYZ9K8LM"))).toBeNull();
    expect(parseDeviceAuth(TRANSCRIPT.replace("WXYZ-9K8LM", "ABCDEFGHIJ-KLMNOPQRS"))).toBeNull();
  });

  test("the agent's Codex home is burrow-cli's <root>/.codex", () => {
    expect(codexHomeFor("/home/agent-98259d347cbe/work")).toBe("/home/agent-98259d347cbe/work/.codex");
  });

  test("codex's env carries its home and no value from the agent's env file", () => {
    const env = codexEnv({ PATH: "/usr/bin", HOME: "/home/x", ANTHROPIC_API_KEY: "sk-ant-x", BURROW_AGENT_ID: A }, "/h/.codex");
    expect(env).toEqual({ PATH: "/usr/bin", HOME: "/home/x", CODEX_HOME: "/h/.codex" });
  });
});

describe("a device_code status, observed", () => {
  const show = (active: string) => parseShow(`ActiveState=${active}\nSubState=\n`);
  const status = { state: "needs_login", login: { step: "device_code", url: "https://auth.openai.com/codex/device", code: "WXYZ-9K8LM" } };

  test("is needs_login carrying the URL and the code", () => {
    expect(observe(A, show("active"), status)).toMatchObject({
      state: "needs_login",
      detail: "device_code",
      login: { step: "device_code", url: "https://auth.openai.com/codex/device", code: "WXYZ-9K8LM" },
    });
  });

  test("a URL off auth.openai.com, or a malformed code, leaves the step alone", () => {
    for (const login of [
      { ...status.login, url: "https://claude.com/cai/oauth/authorize" },
      { ...status.login, code: "not a code" },
      { ...status.login, code: undefined },
    ]) {
      const o = observe(A, show("active"), { state: "needs_login", login });
      expect(o.login).toEqual({ step: "device_code" });
    }
  });

  test("only device_code carries them: any other step with a url and code is the step alone", () => {
    const o = observe(A, show("active"), { state: "needs_login", login: { ...status.login, step: "login_url" } });
    expect(o.login).toEqual({ step: "login_url" });
    expect(JSON.stringify(o)).not.toContain("WXYZ");
  });

  test("deviceLogin is the same rule on its own", () => {
    expect(deviceLogin(status.login)).toEqual({ url: status.login.url, code: status.login.code });
    expect(deviceLogin(undefined)).toBeNull();
  });
});

describe("agent.start for codex", () => {
  const good = {
    agent_id: A,
    runtime_id: "ada-native-1a2b3c4d",
    runtime_token: "t".repeat(43),
    harness: "codex",
    core_url: "http://core-platform:4000",
    env: {},
  };

  test("parses, and codex is a harness this host runs", () => {
    expect(parseStart(good)).toMatchObject({ agent_id: A, harness: "codex" });
    expect(SUPPORTED_HARNESSES.has("codex")).toBe(true);
    expect(SUPPORTED_HARNESSES.has("claude_code")).toBe(true);
  });

  test("the env file names the harness, and core cannot set that name", () => {
    expect(renderEnvFile(A, {}, "codex")).toContain("BURROW_AGENT_HARNESS=codex\n");
    expect(isAgentEnvName("BURROW_AGENT_HARNESS")).toBe(false);
    expect(parseStart({ ...good, env: { BURROW_AGENT_HARNESS: "claude_code" } })).toBe("env name BURROW_AGENT_HARNESS is not allowed");
  });
});

/** A fake world: a clock, scripted `codex login` runs and `codex login status` answers. */
function world(script: { logins: Array<{ chunks: string[]; exit: number; logsIn?: boolean }>; loggedIn?: boolean; stop?: () => boolean }) {
  let now = 1_000_000;
  let loggedIn = script.loggedIn ?? false;
  const starts: number[] = [];
  const statuses: CodexStatus[] = [];
  const argvs: string[][] = [];
  const logs: string[] = [];
  const io: CodexLoginIo = {
    start(argv, _env, onStdout) {
      argvs.push(argv);
      starts.push(now);
      const run = script.logins.shift();
      if (run === undefined) throw new Error("no scripted login left");
      for (const c of run.chunks) onStdout(c);
      if (run.logsIn) loggedIn = true;
      now += 1_000;
      return { exited: Promise.resolve(run.exit), kill: () => {} };
    },
    async exitCode(argv) {
      argvs.push(argv);
      return loggedIn ? 0 : 1;
    },
    writeStatus: (s) => statuses.push(s),
    now: () => now,
    sleep: async (ms) => {
      now += ms;
    },
    log: (l) => logs.push(l),
    stopping: script.stop ?? (() => false),
  };
  return { io, starts, statuses, argvs, logs };
}

describe("startDeviceLogin", () => {
  test("writes needs_login with the URL and code as soon as both are printed, even split across chunks", async () => {
    const mid = TRANSCRIPT.indexOf("WXYZ") + 2;
    const w = world({ logins: [{ chunks: [TRANSCRIPT.slice(0, mid), TRANSCRIPT.slice(mid)], exit: 1 }] });
    expect(await startDeviceLogin(A, w.io, OPTS)).toBe(1);
    expect(w.argvs[0]).toEqual(["codex", "login", "--device-auth"]);
    expect(w.statuses).toEqual([{ state: "needs_login", login: { step: "device_code", url: "https://auth.openai.com/codex/device", code: "WXYZ-9K8LM" } }]);
    // The code is not logged.
    expect(w.logs.join("\n")).not.toContain("WXYZ");
  });

  test("never reads auth.json: the login code names it only in a comment, and file reads refuse it", () => {
    const src = resolve(import.meta.dir, "../src");
    for (const f of ["codex_login.ts", "runner.ts", "agents.ts", "host.ts"]) {
      const text = readFileSync(resolve(src, f), "utf8");
      for (const l of text.split("\n").filter((x) => x.includes("auth.json"))) {
        expect({ f, l, comment: /^\s*(\*|\/\/)/.test(l) }).toEqual({ f, l, comment: true });
      }
    }
    // Positive control: the scan reads the file that names it.
    expect(readFileSync(resolve(src, "codex_login.ts"), "utf8")).toContain("auth.json");
    // agent.file_read shows Codex's token file by name only, never its content (files.ts).
    expect(isSecretFile(".codex/auth.json")).toBe(true);
  });
});

describe("ensureCodexLogin: restart on expiry, throttled", () => {
  test("already logged in: no device login, status starting", async () => {
    const w = world({ logins: [], loggedIn: true });
    expect(await ensureCodexLogin(A, w.io, OPTS)).toBe(true);
    expect(w.starts).toEqual([]);
    expect(w.statuses).toEqual([{ state: "starting" }]);
  });

  test("an expired code starts a fresh login no sooner than 60 s after the last start", async () => {
    const w = world({
      logins: [
        { chunks: [TRANSCRIPT], exit: 1 },
        { chunks: [TRANSCRIPT.replace("WXYZ-9K8LM", "ABCD-1E2FG")], exit: 1 },
        { chunks: [TRANSCRIPT], exit: 0, logsIn: true },
      ],
    });
    expect(await ensureCodexLogin(A, w.io, OPTS)).toBe(true);
    expect(w.starts).toHaveLength(3);
    for (let i = 1; i < w.starts.length; i++) expect(w.starts[i]! - w.starts[i - 1]!).toBeGreaterThanOrEqual(RESTART_THROTTLE_MS);
    const codes = w.statuses.flatMap((s) => (s.state === "needs_login" ? [s.login.code] : []));
    expect(codes).toEqual(["WXYZ-9K8LM", "ABCD-1E2FG", "WXYZ-9K8LM"]);
    expect(w.statuses.at(-1)).toEqual({ state: "starting" });
  });

  test("POSITIVE CONTROL for the throttle: a login that ran past 60 s restarts without waiting", async () => {
    const w = world({ logins: [{ chunks: [TRANSCRIPT], exit: 1 }, { chunks: [TRANSCRIPT], exit: 0, logsIn: true }] });
    const start = w.io.start.bind(w.io);
    let first = true;
    w.io.start = (argv, env, on) => {
      const r = start(argv, env, on);
      if (first) {
        first = false;
        // The first code lived its whole 15 minutes.
        const before = w.io.now();
        w.io.sleep(15 * 60_000);
        expect(w.io.now() - before).toBe(15 * 60_000);
      }
      return r;
    };
    expect(await ensureCodexLogin(A, w.io, OPTS)).toBe(true);
    // The run itself (1 s) plus its 15 minutes, and no added wait.
    expect(w.starts[1]! - w.starts[0]!).toBe(1_000 + 15 * 60_000);
  });

  test("exit 0 without a login (codex login status still non-zero) is not trusted", async () => {
    const w = world({ logins: [{ chunks: [TRANSCRIPT], exit: 0 }, { chunks: [TRANSCRIPT], exit: 0, logsIn: true }] });
    expect(await ensureCodexLogin(A, w.io, OPTS)).toBe(true);
    expect(w.starts).toHaveLength(2);
  });

  test("a stop ends the loop", async () => {
    const w = world({ logins: [], stop: () => true });
    expect(await ensureCodexLogin(A, w.io, OPTS)).toBe(false);
  });
});

describe("the runner's codex loop", () => {
  const runnerIo = (stop = { v: false }): RunnerIo => ({
    spawn: async () => ({ exitCode: 0, stdout: "" }),
    sleep: async () => {},
    log: () => {},
    stopping: () => stop.v,
  });

  test("logs in, writes ready, then runs burrow codex --no-session; a bridge that ends is exit 1", async () => {
    const w = world({ logins: [{ chunks: [TRANSCRIPT], exit: 0, logsIn: true }] });
    const bridges: string[][] = [];
    const code = await runCodexAgent(runnerIo(), w.io, A, OPTS, async (argv) => {
      bridges.push(argv);
      // The bridge only runs once Codex is logged in and the status says ready.
      expect(w.statuses.at(-1)).toEqual({ state: "ready" });
      return 7;
    });
    expect(code).toBe(1);
    expect(bridges).toEqual([CODEX_BRIDGE]);
    expect(CODEX_BRIDGE).toEqual(["burrow", "codex", "--no-session"]);
    expect(w.statuses[0]).toEqual({ state: "starting" });
    expect(w.statuses.some((s) => s.state === "needs_login")).toBe(true);
  });

  test("a stop during the bridge is exit 0", async () => {
    const stop = { v: false };
    const w = world({ logins: [], loggedIn: true });
    const code = await runCodexAgent(runnerIo(stop), w.io, A, OPTS, async () => {
      stop.v = true;
      return 143;
    });
    expect(code).toBe(0);
  });
});
