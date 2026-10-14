/**
 * Pure parts of the agent host: names, units, command parsing, the observed
 * state table, the argv secret check, and the Phoenix client. No root, no
 * systemd. The isolation half is test/isolation.test.ts.
 */
import { describe, expect, test } from "bun:test";
import { SecretInArgv, SecretRegistry, assertNoSecretsInArgv } from "../src/exec.ts";
import { connectionKey, isAgentEnvName, shortId, userName, envFile, runDir, statusFile } from "../src/ids.ts";
import { loginScreenStatus, observe, parseShow, parseStart, renderEnvFile } from "../src/agents.ts";
import { PACKAGED_RUNNER, dropIn, templateUnit } from "../src/units.ts";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { PhoenixChannel, agentHostUrl, backoffMs, type SocketLike } from "../src/phoenix.ts";
import { alive, runAgent, type RunnerIo } from "../src/runner.ts";
import { isFileKey, parseFiles, writeAgentFiles } from "../src/files.ts";
import type { Runner } from "../src/exec.ts";
import { LOGIN_MARKERS, captureArgv, redactPane, scrubLine } from "../src/pane.ts";
import { Host, withAuth, type AuthDeps } from "../src/host.ts";
import { FALLBACK, HEADER, loadSuiteConventions, renderUserMemory, userMemoryPath, writeUserMemory } from "../src/conventions.ts";
import { checkApiKey, parseEnvFile, type Fetch } from "../src/auth.ts";
import { writeConventions } from "../src/agents.ts";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

const A = "01a10322-e24f-7001-8356-98259d347cbe";
// Created within the same millisecond-clock prefix as A: the head is shared.
const B = "01a10322-e24f-7001-9000-0123456789ab";

describe("names", () => {
  test("the user name comes from the random TAIL of a UUIDv7, not its clock head", () => {
    expect(userName(A)).toBe("agent-98259d347cbe");
    expect(userName(B)).toBe("agent-0123456789ab");
    expect(userName(A)).not.toBe(userName(B));
    expect(userName(A).length).toBeLessThanOrEqual(32);
  });

  test("refuses a non-id", () => {
    expect(() => shortId("../etc")).toThrow();
  });

  test("paths are per agent", () => {
    expect(envFile(A)).toBe(`/etc/suite-agents/${A}.env`);
    expect(runDir(A)).toBe(`/run/suite-agents/${A}`);
    expect(statusFile(A)).toBe("/home/agent-98259d347cbe/.local/state/suite/sessions/suite-agent.status.json");
  });

  test("the connection key is suite-cli's agentKey for the same folder", () => {
    // Vector computed by suite-cli 0.7.2's src/agent_connections.ts agentKey()
    // for this path (which does not exist, so its canonical form is itself).
    expect(connectionKey("/home/agent-98259d347cbe/work")).toBe(SUITE_CLI_KEY_VECTOR);
  });

  test("reserved env names are refused", () => {
    expect(isAgentEnvName("ANTHROPIC_API_KEY")).toBe(true);
    for (const n of ["HOME", "PATH", "LD_PRELOAD", "TMUX_TMPDIR", "lower", "A-B"]) expect(isAgentEnvName(n)).toBe(false);
  });
});

// From suite-cli 0.7.2 agentKey("/home/agent-98259d347cbe/work"), run on moon 2026-10-09.
const SUITE_CLI_KEY_VECTOR = "work-4e19478c8cac30c4";

describe("units", () => {
  test("the template runs as the drop-in's user, restarts on failure, reads the per-agent env file", () => {
    const unit = templateUnit(["/usr/local/bin/bun", "run", "/opt/suite/agent-host/src/runner.ts"]);
    expect(unit).toContain("EnvironmentFile=/etc/suite-agents/%i.env");
    expect(unit).toContain("Restart=on-failure");
    expect(unit).toContain("ExecStart=/usr/local/bin/bun run /opt/suite/agent-host/src/runner.ts");
    expect(unit).not.toContain("User=");
  });

  test("the packaged template (image and full_machine user-data) is exactly what the host writes", () => {
    // Stage 3 ships packaging/suite-agent@.service in both profiles; the host
    // rewrites the template on every start, so a drift would flap the unit.
    const packaged = readFileSync(resolve(import.meta.dir, "..", "packaging", "suite-agent@.service"), "utf8");
    expect(packaged).toBe(templateUnit(PACKAGED_RUNNER));
  });

  test("every agent launch is marked unattended, so suite-cli seeds Claude's onboarding", () => {
    expect(templateUnit(PACKAGED_RUNNER)).toContain("Environment=SUITE_UNATTENDED=1\n");
  });

  test("agents never auto-update the pinned CLIs and trust the system CA bundle", () => {
    const unit = templateUnit(PACKAGED_RUNNER);
    expect(unit).toContain("Environment=DISABLE_AUTOUPDATER=1");
    expect(unit).toContain("Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt");
  });

  test("the drop-in names the agent's own user and its private tmux dir", () => {
    const d = dropIn(A);
    expect(d).toContain("User=agent-98259d347cbe");
    expect(d).toContain("Group=suite-agents");
    expect(d).toContain("WorkingDirectory=/home/agent-98259d347cbe/work");
    expect(d).toContain(`Environment=TMUX_TMPDIR=/run/suite-agents/${A}`);
  });
});

describe("agent.start payloads", () => {
  const good = {
    agent_id: A,
    runtime_id: "ada-native-1a2b3c4d",
    runtime_token: "t".repeat(43),
    harness: "claude_code",
    core_url: "http://core-platform:4000",
    env: { ANTHROPIC_API_KEY: "sk-test" },
  };

  test("a valid one parses", () => {
    expect(parseStart(good)).toMatchObject({ agent_id: A, env: { ANTHROPIC_API_KEY: "sk-test" } });
  });

  test("bad ids, URLs and env are refused", () => {
    expect(parseStart({ ...good, agent_id: "../../etc" })).toBeString();
    expect(parseStart({ ...good, runtime_id: "a b" })).toBeString();
    expect(parseStart({ ...good, core_url: "file:///etc/passwd" })).toBeString();
    expect(parseStart({ ...good, env: { PATH: "/tmp" } })).toBeString();
    expect(parseStart({ ...good, env: { X: "a\nB=c" } })).toBeString();
    expect(parseStart({ ...good, runtime_token: "" })).toBeString();
  });

  test("the env file carries only this agent's values, quoted", () => {
    expect(renderEnvFile(A, { ANTHROPIC_API_KEY: "sk-'x" })).toBe(
      `# Managed by Suite's agent host. This agent's values only.\nSUITE_AGENT_ID=${A}\nANTHROPIC_API_KEY='sk-\\'x'\n`,
    );
  });
});

describe("observed state", () => {
  const show = (active: string, sub = "") => parseShow(`ActiveState=${active}\nSubState=${sub}\n`);
  test("table", () => {
    expect(observe(A, show("failed"), null).state).toBe("crashed");
    expect(observe(A, show("inactive"), null).state).toBe("stopped");
    expect(observe(A, show("activating", "auto-restart"), null).state).toBe("starting");
    expect(observe(A, show("active"), { state: "ready" }).state).toBe("running");
    expect(observe(A, show("active"), { state: "dialog" }).state).toBe("starting");
    expect(observe(A, show("active"), null).state).toBe("starting");
  });

  // Stage 7: the behavioural gate's agent sat at "Starting" for ten minutes
  // on a screen nobody would answer. suite-cli's launch record turns that
  // into `stuck` once its launch window closes; here it reads as crashed.
  test("stuck reads as crashed, with what is on screen", () => {
    const o = observe(A, show("active"), { state: "stuck", reason: "an unrecognised screen: Welcome" });
    expect(o).toMatchObject({ state: "crashed", detail: "stuck: an unrecognised screen: Welcome" });
    expect(observe(A, show("active"), { state: "stuck" }).detail).toBe("stuck: Claude's input box did not appear");
  });

  test("POSITIVE CONTROL: the same screen before the launch window closes is still starting", () => {
    expect(observe(A, show("active"), { state: "unknown_dialog", title: "Welcome" }).state).toBe("starting");
    expect(observe(A, show("active"), { state: "starting" }).state).toBe("starting");
  });

  test("a failed turn (auth_error) is needs_login, and its pane is not withheld as a login screen", () => {
    const status = { state: "needs_login", login: { step: "auth_error" } };
    expect(observe(A, show("active"), status)).toMatchObject({ state: "needs_login", detail: "auth_error" });
    expect(loginScreenStatus(status)).toBe(false);
    expect(loginScreenStatus({ state: "needs_login", login: { step: "login_url" } })).toBe(true);
    expect(loginScreenStatus({ state: "ready" })).toBe(false);
  });

  test("needs_login carries the step and the url suite-cli reported, and nothing else", () => {
    const o = observe(A, show("active"), { state: "needs_login", login: { step: "login_url", url: "https://claude.com/cai/oauth/authorize?x=1" } });
    expect(o).toMatchObject({ state: "needs_login", detail: "login_url", login: { step: "login_url", url: "https://claude.com/cai/oauth/authorize?x=1" } });
  });
});

describe("no secret in argv (mirrors suite-cli's assertNoSecretsInArgv)", () => {
  test("an argv carrying a held secret is refused (positive control)", () => {
    const s = new SecretRegistry();
    s.add("tok-SECRET-01a10322");
    expect(() => assertNoSecretsInArgv(["runuser", "x", "--token=tok-SECRET-01a10322"], s)).toThrow(SecretInArgv);
  });
  test("an argv without one passes", () => {
    const s = new SecretRegistry();
    s.add("tok-SECRET-01a10322");
    expect(() => assertNoSecretsInArgv(["systemctl", "restart", `suite-agent@${A}.service`], s)).not.toThrow();
  });
});

describe("phoenix", () => {
  test("url and backoff", () => {
    expect(agentHostUrl("http://core-platform:4000")).toBe("ws://core-platform:4000/agent-host/websocket?vsn=2.0.0");
    expect(agentHostUrl("https://suite.example.invalid/")).toBe("wss://suite.example.invalid/agent-host/websocket?vsn=2.0.0");
    expect([0, 1, 2, 10].map(backoffMs)).toEqual([1000, 2000, 4000, 30000]);
  });

  test("joins with the header, never the URL, and routes pushes and replies", async () => {
    const sent: unknown[] = [];
    let opened: { url: string; headers: Record<string, string> } | null = null;
    const ws: SocketLike = {
      readyState: 1,
      send: (d) => void sent.push(JSON.parse(d)),
      close: () => {},
      onopen: null,
      onclose: null,
      onerror: null,
      onmessage: null,
    };
    let joined = 0;
    const got: unknown[] = [];
    const ch = new PhoenixChannel({
      url: "ws://core/agent-host/websocket?vsn=2.0.0",
      headers: { "x-agent-host-token": "tok" },
      topic: "agent_host:control",
      joinPayload: () => ({ profile: "contained" }),
      socket: (url, headers) => {
        opened = { url, headers };
        return ws;
      },
      log: () => {},
      onJoined: () => void joined++,
      setTimer: () => null,
      clearTimer: () => {},
    });
    ch.on("agent.stop", (p) => void got.push(p));
    ch.connect();
    expect(opened!.url).not.toContain("tok");
    expect(opened!.headers).toEqual({ "x-agent-host-token": "tok" });
    ws.onopen!(null);
    expect(sent[0]).toEqual(["1", "1", "agent_host:control", "phx_join", { profile: "contained" }]);
    ws.onmessage!({ data: JSON.stringify(["1", "1", "agent_host:control", "phx_reply", { status: "ok", response: {} }]) });
    expect(joined).toBe(1);
    const p = ch.push("agent.state", { a: 1 });
    ws.onmessage!({ data: JSON.stringify(["1", "2", "agent_host:control", "phx_reply", { status: "ok", response: {} }]) });
    expect(await p).toBe("ok");
    ws.onmessage!({ data: JSON.stringify([null, null, "agent_host:control", "agent.stop", { agent_id: A }]) });
    expect(got).toEqual([{ agent_id: A }]);
  });
});

describe("the runner", () => {
  const io = (results: Record<string, number[]>, stop = { v: false }): RunnerIo & { calls: string[][] } => {
    const calls: string[][] = [];
    return {
      calls,
      async spawn(argv) {
        calls.push(argv);
        const k = argv.slice(0, 2).join(" ");
        const q = results[k] ?? [0];
        return { exitCode: q.length > 1 ? q.shift()! : q[0]!, stdout: "" };
      },
      sleep: async () => {},
      log: () => {},
      stopping: () => stop.v,
    };
  };

  test("launches suite claude, then exits 1 when pane-status says the session is gone", async () => {
    const r = io({ "suite pane-status": [0, 0, 1] });
    expect(await runAgent(r)).toBe(1);
    expect(r.calls[0]).toEqual(["suite", "claude", "--session", "suite-agent"]);
    expect(r.calls.filter((c) => c[1] === "pane-status")).toHaveLength(3);
    // Nothing the runner runs types into a pane.
    expect(r.calls.some((c) => c.includes("send-keys"))).toBe(false);
  });

  test("an older suite-cli without pane-status falls back to tmux has-session", async () => {
    const r = io({ "suite pane-status": [2], "tmux has-session": [1] });
    expect(await alive(r, "suite-agent")).toBe(false);
  });

  test("a stop exits 0", async () => {
    const stop = { v: true };
    expect(await runAgent(io({}, stop))).toBe(0);
  });
});

// Stage 5: the agent's own files. The real writes (as the agent's uid, on a
// real filesystem with planted symlinks) are in test/isolation.test.ts.
describe("agent file keys (same rule as core's NativeAgents.valid_file_key?/1)", () => {
  test("accepts relative keys up to three deep", () => {
    for (const k of ["CLAUDE.md", "AGENTS.md", ".claude/settings.json", "a/b/c.md", ".mcp.json"]) {
      expect(isFileKey(k)).toBe(true);
    }
  });

  test("refuses traversal, absolute, home-relative, too deep and odd characters", () => {
    for (const k of [
      "../x", "a/../../x", "a/..", "./x", "/etc/x", "~/x", "~agent/x", "a/b/c/d", "", "a//b", "a/",
      "a\nb", "a b", "-rf", "a/\0", "..", ".", "...", "x\\y", 42, null,
    ]) {
      expect(isFileKey(k)).toBe(false);
    }
  });

  test("parseStart carries files; absent is null, a malformed list is refused", () => {
    const good = {
      agent_id: A, runtime_id: "ada-native-1234abcd", runtime_token: "t".repeat(32), harness: "claude_code",
      core_url: "http://core:4000", env: {},
    };
    expect(parseStart(good)).toMatchObject({ files: null });
    const files = [{ key: "CLAUDE.md", content: "# Ada\n", version: 2 }];
    expect(parseStart({ ...good, files })).toMatchObject({ files });
    expect(parseStart({ ...good, files: "CLAUDE.md" })).toBeString();
    expect(parseStart({ ...good, files: [{ key: "CLAUDE.md", content: 1, version: 1 }] })).toBeString();
    expect(parseFiles([{ key: "x", content: "", version: 1.5 }])).toBeString();
  });

  test("the writer never runs a command for an invalid key, and runs as the agent for a valid one", async () => {
    const calls: string[][] = [];
    const stdins: (string | undefined)[] = [];
    const runner: Runner = {
      run: async (argv, opts) => {
        calls.push(argv);
        stdins.push(opts?.stdin);
        return { exitCode: 0, stdout: "", stderr: "" };
      },
    };
    const user = { name: "agent-98259d347cbe", uid: 1001, gid: 1001, home: "/home/agent-98259d347cbe", work: "/home/agent-98259d347cbe/work", runDir: "/run/x" };
    const res = await writeAgentFiles(runner, user, [
      { key: "../escape", content: "x", version: 1 },
      { key: ".claude/settings.json", content: "{}", version: 3 },
    ]);
    expect(res.rejected.map((r) => r.key)).toEqual(["../escape"]);
    expect(res.applied).toEqual({ ".claude/settings.json": 3 });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.slice(0, 4)).toEqual(["runuser", "-u", "agent-98259d347cbe", "--"]);
    expect(calls[0]!.slice(-4)).toEqual([user.work, ".claude", "settings.json", "0644"]);
    // Content travels on stdin, never in argv.
    expect(stdins[0]).toBe("{}");
  });

  test("observe reports files_applied as given", () => {
    const show = (active: string) => parseShow(`ActiveState=${active}\nSubState=running`);
    expect(observe(A, show("active"), { state: "ready" }, { "CLAUDE.md": 4 }).files_applied).toEqual({ "CLAUDE.md": 4 });
    expect(observe(A, show("active"), { state: "ready" }).files_applied).toBeNull();
  });
});

/*
 * Stage 6: "Recent output" is READ ONLY, and a login screen never leaves the
 * machine. The login screens below are the first lines suite-cli's fixtures
 * (claude-code-2.1.295-login) show; the URL's values are placeholders.
 */

describe("recent output (pane.ts)", () => {
  const loginUrl = [
    " Browser didn't open? Use the url below to sign in (c to copy)",
    "",
    "https://claude.com/cai/oauth/authorize?code=true&client_id=x&response_type=code&redir",
    "ect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=FFFF",
    "",
    " Paste code here if prompted >",
  ].join("\n");
  const loginMethod = " Select login method:\n\n ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise";
  const apiKey = "  Detected a custom API key in your environment\n\n  ANTHROPIC_API_KEY: sk-ant-...AAAAAAAAAAAAAAAAAAAA";

  for (const [name, text] of [["login-url", loginUrl], ["login-method", loginMethod], ["api-key-confirm", apiKey]] as const) {
    test(`a ${name} screen is withheld whole`, () => {
      expect(redactPane(text, false)).toEqual({ lines: [], hidden: "login" });
    });
  }

  test("the status file alone is enough to withhold the pane", () => {
    expect(redactPane("ordinary output", true)).toEqual({ lines: [], hidden: "login" });
  });

  test("ordinary output passes (positive control), scrubbed", () => {
    const out = redactPane("hello\nkey sk-ant-api03-abcDEF_123 here\nANTHROPIC_API_KEY=whatever\nAuthorization: Bearer abc.def\n", false);
    expect(out.hidden).toBeNull();
    expect(out.lines).toEqual([
      "hello",
      "key sk-ant-[redacted] here",
      "ANTHROPIC_API_KEY=[redacted]",
      "Authorization: Bearer [redacted]",
    ]);
  });

  test("scrubbing is idempotent (core scrubs the host's output again)", () => {
    const once = scrubLine("key sk-ant-api03-abc ANTHROPIC_API_KEY=x Bearer y https://e.com/?code=z");
    expect(scrubLine(once)).toBe(once);
    expect(once).toBe("key sk-ant-[redacted] ANTHROPIC_API_KEY=[redacted] Bearer [redacted] https://e.com/?code=[redacted]");
  });

  test("an OAuth code in a URL is scrubbed", () => {
    expect(scrubLine("https://example.com/cb?code=abc123&state=zz&x=1")).toBe(
      "https://example.com/cb?code=[redacted]&state=[redacted]&x=1",
    );
  });

  // Needs the whole repo; skipped where only services/agent-host is mounted
  // (test/isolation/run.sh, the image-build job). Core's own RedactTest
  // asserts the same screens are withheld.
  const redactEx = resolve(import.meta.dir, "../../../apps/platform/lib/platform/agent_host/redact.ex");
  test.skipIf(!existsSync(redactEx))("core's Redact module uses the same login markers", () => {
    const ex = readFileSync(redactEx, "utf8");
    for (const m of LOGIN_MARKERS) expect(ex).toContain(JSON.stringify(m));
  });

  test("the capture runs as the agent, on its own tmux socket, and only reads", () => {
    const argv = captureArgv(A, 80);
    expect(argv.slice(0, 4)).toEqual(["runuser", "-u", userName(A), "--"]);
    expect(argv).toContain(`TMUX_TMPDIR=${runDir(A)}`);
    expect(argv).toContain("capture-pane");
    expect(argv).not.toContain("send-keys");
    expect(argv).toContain("=suite-agent:");
  });

  test("a pane request pushes the redacted text back, and runs nothing but the capture", async () => {
    const seen: string[][] = [];
    const runner: Runner = {
      async run(argv) {
        seen.push(argv);
        return { exitCode: 0, stdout: "working\nsk-ant-api03-SECRET\n", stderr: "" };
      },
    };
    const pushed: [string, Record<string, unknown>][] = [];
    const host = new Host(
      { runner, secrets: new SecretRegistry(), runnerCommand: ["x"], log: () => {} },
      { push: async (e, p) => (pushed.push([e, p]), "ok") },
      "contained",
    );
    await host.handlePane({ agent_id: A, lines: 50, ref: "r1" }, { statusSaysLogin: () => false });
    expect(seen).toHaveLength(1);
    expect(seen[0]).toContain("capture-pane");
    expect(pushed).toEqual([["agent.pane", { ref: "r1", agent_id: A, lines: ["working", "sk-ant-[redacted]"], hidden: null }]]);

    pushed.length = 0;
    seen.length = 0;
    await host.handlePane({ agent_id: A, lines: 50, ref: "r2" }, { statusSaysLogin: () => true });
    expect(seen).toHaveLength(0);
    expect(pushed).toEqual([["agent.pane", { ref: "r2", agent_id: A, lines: [], hidden: "login" }]]);
  });
});

describe("no path from Suite into an agent's pane", () => {
  const src = resolve(import.meta.dir, "../src");
  const files = readdirSync(src).filter((f) => f.endsWith(".ts"));

  test("nothing in the agent host sends keys to a pane", () => {
    // Positive control: the scan reads real source (pane.ts names capture-pane).
    expect(files.some((f) => readFileSync(resolve(src, f), "utf8").includes("capture-pane"))).toBe(true);
    for (const f of files) {
      const text = readFileSync(resolve(src, f), "utf8");
      expect({ f, sendKeys: /["'`]send-keys["'`]/.test(text) }).toEqual({ f, sendKeys: false });
      expect({ f, pasteBuffer: /paste-buffer|load-buffer/.test(text) }).toEqual({ f, pasteBuffer: false });
    }
  });

  test("the commands core can send are exactly start, restart, stop, logs, pane and check_auth", () => {
    const main = readFileSync(resolve(src, "main.ts"), "utf8");
    const events = [...main.matchAll(/channel\.on\("([^"]+)"/g)].map((m) => m[1]).sort();
    expect(events).toEqual(["agent.check_auth", "agent.logs", "agent.pane", "agent.restart", "agent.start", "agent.stop"]);
  });
});

describe("the API key reaches only its own agent's env file", () => {
  test("agent.start accepts ANTHROPIC_API_KEY and the env file carries it", () => {
    const cmd = parseStart({
      agent_id: A,
      runtime_id: "ada-native-0011aabb",
      runtime_token: "t".repeat(32),
      harness: "claude_code",
      core_url: "http://core:4000",
      env: { ANTHROPIC_API_KEY: "sk-ant-api03-ownkey" },
      files: [],
    });
    expect(typeof cmd).toBe("object");
    const file = renderEnvFile(A, (cmd as { env: Record<string, string> }).env);
    expect(file).toContain("ANTHROPIC_API_KEY='sk-ant-api03-ownkey'");
    expect(file).toContain(`SUITE_AGENT_ID=${A}`);
    // Positive control for the other agent: its file has no key.
    expect(renderEnvFile(B, {})).not.toContain("ANTHROPIC_API_KEY");
  });

  test("the unit template does not carry the key; only the per-agent EnvironmentFile does", () => {
    const unit = templateUnit(PACKAGED_RUNNER);
    expect(unit).not.toContain("ANTHROPIC_API_KEY");
    expect(unit).toContain("EnvironmentFile=/etc/suite-agents/%i.env");
    expect(dropIn(A)).not.toContain("ANTHROPIC_API_KEY");
  });
});

describe("Suite's conventions load whatever the owner's CLAUDE.md says (stage 7 round 2, case 7008)", () => {
  const user = { name: userName(A), uid: 1000, gid: 1000, home: `/home/${userName(A)}`, work: `/home/${userName(A)}/work`, runDir: runDir(A) };

  test("the user memory file is ~/.claude/CLAUDE.md: outside the work dir the owner's files are written into", () => {
    expect(userMemoryPath(user)).toBe(`/home/${userName(A)}/.claude/CLAUDE.md`);
    expect(userMemoryPath(user).startsWith(`${user.work}/`)).toBe(false);
    // The owner's editor cannot name it: keys are relative to the work dir.
    expect(isFileKey("~/.claude/CLAUDE.md")).toBe(false);
    expect(isFileKey("../.claude/CLAUDE.md")).toBe(false);
  });

  test("it carries suite-cli's text after a header; without it, the reply rule", () => {
    const text = "## Always respond in channel\n\nuse suite_reply\n";
    const full = renderUserMemory(text);
    expect(full.startsWith(HEADER)).toBe(true);
    expect(full).toContain(text);
    expect(renderUserMemory(null)).toContain(FALLBACK);
    expect(FALLBACK).toContain("suite_reply");
  });

  test("suite-cli's SUITE_CONVENTIONS is read from its installed sources; a missing lib is null", async () => {
    const lib = mkdtempSync(`${tmpdir()}/suite-cli-lib-`);
    try {
      mkdirSync(`${lib}/src`);
      writeFileSync(`${lib}/src/claude_md.ts`, 'export const SUITE_CONVENTIONS = "## Always respond in channel\\n\\nsuite_reply STUB";\n');
      expect(await loadSuiteConventions(lib)).toBe("## Always respond in channel\n\nsuite_reply STUB");
      expect(await loadSuiteConventions(`${lib}/nope`)).toBeNull();
    } finally {
      rmSync(lib, { recursive: true, force: true });
    }
  });

  test("written as the agent, content on stdin, every start", async () => {
    const calls: { argv: string[]; stdin?: string }[] = [];
    const runner: Runner = {
      async run(argv, options) {
        calls.push({ argv, stdin: options?.stdin });
        return { exitCode: 0, stdout: "", stderr: "" };
      },
    };
    const logs: string[] = [];
    const deps = { runner, secrets: new SecretRegistry(), runnerCommand: ["x"], log: (l: string) => logs.push(l), conventions: async () => "CONV suite_reply" };
    await writeConventions(deps, user, A);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.argv.slice(0, 4)).toEqual(["runuser", "-u", userName(A), "--"]);
    expect(calls[0]!.argv).toContain(userMemoryPath(user));
    expect(calls[0]!.stdin).toBe(renderUserMemory("CONV suite_reply"));
    expect(logs).toEqual([]);

    // Positive control for the log: no text loaded is said out loud.
    await writeConventions({ ...deps, conventions: async () => null }, user, A);
    expect(calls[1]!.stdin).toBe(renderUserMemory(null));
    expect(logs).toHaveLength(1);
  });

  test("a failed write is an error, not a silent skip", async () => {
    const runner: Runner = { run: async () => ({ exitCode: 1, stdout: "", stderr: "denied" }) };
    await expect(writeUserMemory(runner, user, "x")).rejects.toThrow("denied");
  });
});

describe("the API key check (stage 7 round 2, case 7009)", () => {
  const recording = (status: number | Error) => {
    const seen: { url: string; headers: Record<string, string> }[] = [];
    const f: Fetch = async (url, init) => {
      seen.push({ url, headers: init.headers });
      if (status instanceof Error) throw status;
      return { status };
    };
    return { f, seen };
  };

  test("the env file parses back to what renderEnvFile wrote, quotes and backslashes included", () => {
    const env = { ANTHROPIC_API_KEY: "sk-ant-api03-a'b\\c", ANTHROPIC_BASE_URL: "http://x.invalid" };
    const parsed = parseEnvFile(renderEnvFile(A, env));
    expect(parsed.ANTHROPIC_API_KEY).toBe(env.ANTHROPIC_API_KEY);
    expect(parsed.ANTHROPIC_BASE_URL).toBe(env.ANTHROPIC_BASE_URL);
    expect(parsed.SUITE_AGENT_ID).toBe(A);
  });

  test("401 is rejected, 2xx ok, anything else unknown; one request, key in a header only", async () => {
    const env = { ANTHROPIC_API_KEY: "sk-ant-api03-KEYVALUE" };
    for (const [status, want] of [[401, "rejected"], [200, "ok"], [403, "unknown"], [500, "unknown"]] as const) {
      const { f, seen } = recording(status);
      expect(await checkApiKey(env, f)).toBe(want);
      expect(seen).toHaveLength(1);
      expect(seen[0]!.url).toBe("https://api.anthropic.com/v1/models?limit=1");
      expect(seen[0]!.url).not.toContain("KEYVALUE");
      expect(seen[0]!.headers["x-api-key"]).toBe("sk-ant-api03-KEYVALUE");
    }
    const failing = recording(new Error("network down"));
    expect(await checkApiKey(env, failing.f)).toBe("unknown");
  });

  test("no key (a subscription login) is never checked: unknown, no request", async () => {
    const { f, seen } = recording(200);
    expect(await checkApiKey({ SUITE_AGENT_ID: A }, f)).toBe("unknown");
    expect(await checkApiKey(null, f)).toBe("unknown");
    expect(seen).toHaveLength(0);
  });

  test("ANTHROPIC_BASE_URL is honoured, as Claude Code honours it", async () => {
    const { f, seen } = recording(401);
    expect(await checkApiKey({ ANTHROPIC_API_KEY: "k", ANTHROPIC_BASE_URL: "http://proxy.invalid/" }, f)).toBe("rejected");
    expect(seen[0]!.url).toBe("http://proxy.invalid/v1/models?limit=1");
  });

  test("a rejected key reads needs_login over a live observation, never over stopped or crashed", () => {
    const live = observe(A, { active: "active", sub: "running" }, { state: "ready" });
    expect(live.state).toBe("running");
    expect(withAuth(live, true)).toMatchObject({ state: "needs_login", detail: "auth_error", login: { step: "auth_error" } });
    expect(withAuth(live, false)).toEqual(live);
    const stopped = observe(A, { active: "inactive", sub: "dead" }, null);
    expect(withAuth(stopped, true)).toEqual(stopped);
  });

  test("check_auth answers first, then reports the agent needs_login; ok changes nothing", async () => {
    const runner: Runner = { run: async () => ({ exitCode: 0, stdout: "ActiveState=active\nSubState=running\n", stderr: "" }) };
    const pushed: [string, Record<string, unknown>][] = [];
    const auth = (status: number): AuthDeps => ({ readEnv: () => ({ ANTHROPIC_API_KEY: "sk-ant-api03-x" }), fetch: async () => ({ status }) });
    const mk = (status: number) =>
      new Host(
        { runner, secrets: new SecretRegistry(), runnerCommand: ["x"], log: () => {} },
        { push: async (e, p) => (pushed.push([e, p]), "ok") },
        "contained",
        auth(status),
      );

    await mk(401).handleCheckAuth({ agent_id: A, ref: "r1" });
    expect(pushed.map(([e]) => e)).toEqual(["agent.auth", "agent.state"]);
    expect(pushed[0]![1]).toEqual({ ref: "r1", agent_id: A, result: "rejected" });
    expect(pushed[1]![1]).toMatchObject({ agent_id: A, state: "needs_login", detail: "auth_error" });

    pushed.length = 0;
    await mk(200).handleCheckAuth({ agent_id: A, ref: "r2" });
    expect(pushed).toEqual([["agent.auth", { ref: "r2", agent_id: A, result: "ok" }]]);

    pushed.length = 0;
    await mk(401).handleCheckAuth({ agent_id: "not-an-id", ref: "r3" });
    expect(pushed).toEqual([]);
  });
});
