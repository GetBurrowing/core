/**
 * `agent.oneshot` (core task 01a1b721 stage 2, oneshot.ts): every refusal,
 * then the whole call against a stub CLI (test/fixtures/oneshot-cli-stub.sh)
 * run for real through `env -i`, without runuser: the prompt only on stdin,
 * the four key variables absent from the child's env, no session left
 * behind, the temp cwd removed, the no-tools / no-MCP flags present, the
 * timeout, and the Host's reply shape.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SecretRegistry, assertNoSecretsInArgv } from "../src/exec.ts";
import { Host } from "../src/host.ts";
import type { AgentsDeps } from "../src/agents.ts";
import { userName } from "../src/ids.ts";
import {
  STRIPPED_ENV,
  asAgentWithEnv,
  claudeArgv,
  definesApiKeyHelper,
  liveChildRun,
  parseClaudeResult,
  parseOneshot,
  runOneshot,
  type OneshotDeps,
  type OneshotReply,
} from "../src/oneshot.ts";

const A = "01a1b721-0000-7000-8000-00000000000a";
const STUB = resolve(import.meta.dir, "fixtures", "oneshot-cli-stub.sh");
chmodSync(STUB, 0o755);
const PROMPT = `PROMPT-SENTINEL-${crypto.randomUUID()} rank these inputs`;

interface Rig {
  deps: OneshotDeps;
  home: string;
  record: string;
  argvs: string[][];
  dirs: string[];
  logs: string[];
  fileEnv: Record<string, string> | null;
}

let root = "";
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "oneshot-test-"));
});
afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function rig(opts: { state?: string; fileEnv?: Record<string, string> | null; settings?: string | null; stub?: Record<string, string> } = {}): Rig {
  const home = mkdtempSync(join(root, "home-"));
  mkdirSync(join(home, ".stub"), { recursive: true });
  for (const [k, v] of Object.entries(opts.stub ?? {})) writeFileSync(join(home, ".stub", k), v);
  const argvs: string[][] = [];
  const dirs: string[] = [];
  const logs: string[] = [];
  const secrets = new SecretRegistry();
  const live = liveChildRun((argv) => assertNoSecretsInArgv(argv, secrets));
  const r: Rig = {
    home,
    record: join(home, ".stub", "record"),
    argvs,
    dirs,
    logs,
    fileEnv: opts.fileEnv === undefined ? { BURROW_AGENT_ID: A, BURROW_AGENT_HARNESS: "claude_code" } : opts.fileEnv,
    deps: {
      readEnv: () => r.fileEnv,
      state: async () => opts.state ?? "running",
      readClaudeSettings: async () => (opts.settings === undefined ? null : opts.settings),
      // No runuser here: the `runuser -u <agent> --` prefix is checked, then dropped.
      run: (argv, o) => {
        argvs.push([...argv]);
        expect(argv.slice(0, 6)).toEqual(["runuser", "-u", userName(A), "--", "env", "-i"]);
        return live(argv.slice(4), o);
      },
      makeTempDir: async () => {
        const d = mkdtempSync(join(root, "cwd-"));
        dirs.push(d);
        return d;
      },
      removeDir: (p) => rmSync(p, { recursive: true, force: true }),
      // The child starts from an env that DOES carry every key variable, as an
      // inherited env could: only the strip keeps them out.
      baseEnv: () => ({
        HOME: home,
        PATH: "/usr/bin:/bin",
        ANTHROPIC_API_KEY: "sk-ant-api03-LEAKED-KEY-should-never-reach-child",
        ANTHROPIC_AUTH_TOKEN: "LEAKED-AUTH-TOKEN",
        ANTHROPIC_BASE_URL: "https://leaked.invalid",
        OPENAI_API_KEY: "sk-LEAKED-OPENAI",
      }),
      secrets,
      log: (l) => logs.push(l),
      claudeBin: STUB,
      codexBin: STUB,
    },
  };
  return r;
}

const req = (over: Partial<{ timeoutMs: number }> = {}) => ({
  agentId: A,
  ref: "r1",
  prompt: PROMPT,
  maxOutputTokens: 1000,
  timeoutMs: over.timeoutMs ?? 20_000,
});

describe("refusals", () => {
  test("an agent that is not running is refused, nothing run", async () => {
    const r = rig({ state: "stopped" });
    expect(await runOneshot(r.deps, req())).toEqual({ result: "refused", reason: "not_running" });
    expect(r.argvs).toEqual([]);
  });

  test("an ANTHROPIC_API_KEY or OPENAI_API_KEY in the agent's env file is an API-key login", async () => {
    for (const name of ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]) {
      const r = rig({ fileEnv: { BURROW_AGENT_HARNESS: "claude_code", [name]: "x" } });
      expect(await runOneshot(r.deps, req())).toEqual({ result: "refused", reason: "api_key_login" });
      expect(r.argvs).toEqual([]);
    }
  });

  test("an apiKeyHelper in the agent's Claude settings is an API-key login", async () => {
    const r = rig({ settings: JSON.stringify({ apiKeyHelper: "/usr/local/bin/print-key" }) });
    expect(await runOneshot(r.deps, req())).toEqual({ result: "refused", reason: "api_key_login" });
    expect(r.argvs).toEqual([]);
    expect(definesApiKeyHelper(JSON.stringify({ theme: "dark" }))).toBe(false);
    expect(definesApiKeyHelper("{not json apiKeyHelper")).toBe(true);
  });

  test("claude auth status not logged in is not_logged_in; an api_key auth method is api_key_login", async () => {
    const out = rig({ stub: { auth: '{"loggedIn":false,"authMethod":"none"}' } });
    expect(await runOneshot(out.deps, req())).toEqual({ result: "refused", reason: "not_logged_in" });
    const key = rig({ stub: { auth: '{"loggedIn":true,"authMethod":"api_key"}' } });
    expect(await runOneshot(key.deps, req())).toEqual({ result: "refused", reason: "api_key_login" });
    // Only the status check ran; the prompt never went anywhere.
    expect(key.argvs.length).toBe(1);
    expect(existsSync(join(key.record, "stdin"))).toBe(false);
  });

  test("the CLI reporting not logged in mid-call is not_logged_in", async () => {
    const r = rig({ stub: { mode: "not_logged_in" } });
    expect(await runOneshot(r.deps, req())).toEqual({ result: "refused", reason: "not_logged_in" });
  });

  test("codex: an API-key login, no login, and (with ChatGPT) tools that cannot be disabled", async () => {
    const env = { BURROW_AGENT_HARNESS: "codex" };
    const apiKey = rig({ fileEnv: env, stub: { codex_login: "Logged in using an API key - sk-***" } });
    expect(await runOneshot(apiKey.deps, req())).toEqual({ result: "refused", reason: "api_key_login" });
    const none = rig({ fileEnv: env });
    expect(await runOneshot(none.deps, req())).toEqual({ result: "refused", reason: "not_logged_in" });
    const chatgpt = rig({ fileEnv: env, stub: { codex_login: "Logged in using ChatGPT" } });
    expect(await runOneshot(chatgpt.deps, req())).toEqual({ result: "refused", reason: "tools_not_disableable" });
    // Codex never ran an exec, so it never saw the prompt.
    expect(chatgpt.argvs.every((a) => !a.includes("exec"))).toBe(true);
    expect(existsSync(join(chatgpt.record, "stdin"))).toBe(false);
  });

  test("a payload without a prompt or ref is refused by the parser", () => {
    expect(typeof parseOneshot({ agent_id: A, ref: "r" })).toBe("string");
    expect(typeof parseOneshot({ agent_id: A, prompt: "p" })).toBe("string");
    expect(parseOneshot({ agent_id: A, ref: "r", prompt: "p", max_output_tokens: 10_000_000, timeout_ms: -1 })).toMatchObject({
      maxOutputTokens: 32_000,
      timeoutMs: 120_000,
    });
  });
});

describe("the call, against the stub CLI", () => {
  test("ok: text and real usage from the JSON result", async () => {
    const r = rig();
    const reply = await runOneshot(r.deps, req());
    expect(reply).toEqual({
      result: "ok",
      text: '{"ok":true}',
      usage: { input_tokens: 12, output_tokens: 5, cache_read_tokens: 3, cache_creation_tokens: 7 },
    });
  });

  test("ARGV: the prompt is on stdin and in no argv", async () => {
    const r = rig();
    await runOneshot(r.deps, req());
    expect(readFileSync(join(r.record, "stdin"), "utf8")).toBe(PROMPT);
    // POSITIVE CONTROL: the stub recorded the print-mode argv.
    const argv = readFileSync(join(r.record, "argv"), "utf8");
    expect(argv).toContain("--output-format");
    expect(argv).not.toContain("PROMPT-SENTINEL");
    for (const a of r.argvs) expect(a.join("\u0000")).not.toContain("PROMPT-SENTINEL");
  });

  test("ENV: the child env lacks the four key variables", async () => {
    const r = rig();
    await runOneshot(r.deps, req());
    const env = readFileSync(join(r.record, "env"), "utf8");
    // POSITIVE CONTROL: the env the stub saw is the one built here.
    expect(env).toContain(`HOME=${r.home}`);
    expect(env).toContain("CLAUDE_CODE_MAX_OUTPUT_TOKENS=1000");
    for (const name of STRIPPED_ENV) expect(env).not.toContain(`${name}=`);
    expect(env).not.toContain("LEAKED");
    for (const a of r.argvs) expect(a.join(" ")).not.toContain("LEAKED");
  });

  test("TOOLS/MCP: tools are the empty set, MCP strict and empty, no settings, no session", async () => {
    const r = rig();
    await runOneshot(r.deps, req());
    const argv = readFileSync(join(r.record, "argv"), "utf8").split("\n").slice(0, -1);
    const after = (flag: string) => argv[argv.indexOf(flag) + 1];
    expect(argv[0]).toBe("-p");
    expect(argv).toContain("--tools");
    expect(after("--tools")).toBe("");
    expect(argv).toContain("--strict-mcp-config");
    expect(after("--mcp-config")).toBe('{"mcpServers":{}}');
    expect(after("--setting-sources")).toBe("");
    expect(argv).toContain("--no-session-persistence");
    expect(argv).toContain("--disable-slash-commands");
    expect(argv.some((a) => /^--(resume|continue)$|^-c$|^-r$/.test(a))).toBe(false);
    expect(claudeArgv("claude").slice(1)).toEqual(argv);
  });

  test("SESSION: no session dir persists and the temp cwd is gone", async () => {
    const r = rig();
    await runOneshot(r.deps, req());
    const cwd = readFileSync(join(r.record, "cwd"), "utf8").trim();
    // POSITIVE CONTROL: the stub ran in the fresh dir handed to it (and wrote into it).
    expect(r.dirs.length).toBe(1);
    expect(cwd.endsWith(r.dirs[0]!.split("/").pop()!)).toBe(true);
    expect(existsSync(r.dirs[0]!)).toBe(false);
    expect(existsSync(join(r.home, ".claude", "projects"))).toBe(false);
  });

  test("TIMEOUT: a CLI that outlives timeout_ms is killed and reads timeout", async () => {
    const r = rig({ stub: { mode: "slow" } });
    const t0 = Date.now();
    expect(await runOneshot(r.deps, req({ timeoutMs: 500 }))).toEqual({ result: "timeout" });
    expect(Date.now() - t0).toBeLessThan(10_000);
    expect(existsSync(r.dirs[0]!)).toBe(false);
  });

  test("the prompt is held as a secret only while the call runs", async () => {
    const r = rig();
    await runOneshot(r.deps, req());
    expect(r.deps.secrets.values()).not.toContain(PROMPT);
  });

  test("the live wrapper is runuser + env -i, the keys stripped before it is built", () => {
    const argv = asAgentWithEnv(A, { HOME: "/home/x" }, ["claude", "-p"]);
    expect(argv).toEqual(["runuser", "-u", userName(A), "--", "env", "-i", "HOME=/home/x", "claude", "-p"]);
  });
});

describe("parseClaudeResult (pure)", () => {
  test("garbage is failed, an error result failed, an auth error not_logged_in", () => {
    expect(parseClaudeResult("nope")).toEqual({ result: "failed", reason: "unparseable_output" });
    expect(parseClaudeResult('{"is_error":true,"result":"overloaded"}')).toEqual({ result: "failed", reason: "cli_error" });
    expect(parseClaudeResult('{"is_error":true,"result":"Invalid API key"}')).toEqual({ result: "refused", reason: "not_logged_in" });
  });
});

describe("Host.handleOneshot", () => {
  test("answers agent.oneshot with ref and agent_id, and logs neither prompt nor text", async () => {
    const r = rig();
    const pushed: [string, Record<string, unknown>][] = [];
    const deps = { runner: { run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) }, secrets: r.deps.secrets, runnerCommand: ["x"], log: (l: string) => r.logs.push(l) } as unknown as AgentsDeps;
    const host = new Host(deps, { push: async (e, p) => (pushed.push([e, p]), "ok") }, "contained", undefined, false, null, undefined, undefined, r.deps);
    const payload: Record<string, unknown> = { agent_id: A, ref: "ref-1", prompt: PROMPT, max_output_tokens: 500, timeout_ms: 20_000 };
    await host.handleOneshot(payload as never);
    expect("prompt" in payload).toBe(false);
    expect(pushed.length).toBe(1);
    const [event, reply] = pushed[0]!;
    expect(event).toBe("agent.oneshot");
    expect(reply).toMatchObject({ ref: "ref-1", agent_id: A, result: "ok", text: '{"ok":true}' });
    expect(r.logs.join("\n")).not.toContain("PROMPT-SENTINEL");
    expect(r.logs.join("\n")).not.toContain('{"ok":true}');
    expect(r.logs.join("\n")).toContain("oneshot ok");
  });

  test("a payload with no ref gets no answer; an invalid one is refused invalid", async () => {
    const r = rig();
    const pushed: unknown[] = [];
    const deps = { runner: { run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) }, secrets: r.deps.secrets, runnerCommand: ["x"], log: () => {} } as unknown as AgentsDeps;
    const host = new Host(deps, { push: async (_e, p) => (pushed.push(p), "ok") }, "contained", undefined, false, null, undefined, undefined, r.deps);
    await host.handleOneshot({ agent_id: A, prompt: PROMPT } as never);
    expect(pushed).toEqual([]);
    await host.handleOneshot({ agent_id: A, ref: "x" } as never);
    expect(pushed).toEqual([{ ref: "x", agent_id: A, result: "refused", reason: "invalid" } satisfies Record<string, unknown> & Partial<OneshotReply>]);
  });
});
