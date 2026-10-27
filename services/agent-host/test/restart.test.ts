/**
 * agent.restart with a ref (task 01a17b1c stage 4): the tool snapshot before
 * and after, answered as agent.restarted. No root: the start itself and the
 * observation are injected; the probe runs a real stdio server through the
 * real probe script (without runuser).
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { SecretRegistry, type Runner } from "../src/exec.ts";
import type { AgentsDeps, Observation, ObservedState, StartCommand } from "../src/agents.ts";
import { Host, type RestartDeps } from "../src/host.ts";
import { PROBE_SCRIPT, approvedServers, snapshotTools, toolsFromStdout, type ToolSnapshot } from "../src/tools.ts";

const A = "01a10322-e24f-7001-8356-98259d347cbe";
const START = {
  agent_id: A,
  runtime_id: "rt-restart-test",
  runtime_token: "tok-0123456789abcdef",
  harness: "claude_code",
  core_url: "http://core.invalid",
  env: {},
  files: [],
};

class StubHost extends Host {
  states: ObservedState[] = [];
  override async observe(agentId: string): Promise<Observation> {
    const state = this.states.length > 1 ? this.states.shift()! : (this.states[0] ?? "running");
    return { agent_id: agentId, state, detail: null, files_applied: null };
  }
}

function harness(states: ObservedState[], snapshots: ToolSnapshot[]) {
  const events: string[] = [];
  const pushed: [string, Record<string, unknown>][] = [];
  const runner: Runner = { run: async () => ({ exitCode: 0, stdout: "", stderr: "" }) };
  const deps: AgentsDeps = { runner, secrets: new SecretRegistry(), runnerCommand: ["x"], log: () => {} };
  const restart: Partial<RestartDeps> = {
    snapshot: async () => {
      events.push("snapshot");
      return snapshots.shift() ?? { servers: [], tools: [] };
    },
    startAgent: async (_d: AgentsDeps, cmd: StartCommand) => {
      events.push(`start:${cmd.agent_id === A}`);
    },
    sleep: async () => {},
    waitMs: 1_000,
    pollMs: 0,
  };
  const host = new StubHost(deps, { push: async (e, p) => (pushed.push([e, p]), "ok") }, "contained", undefined, false, null, restart);
  host.states = states;
  return { host, events, pushed };
}

const snap = (tools: string[]): ToolSnapshot => ({ servers: [], tools });

describe("agent.restart returns a tools snapshot", () => {
  test("before is taken before the files are rewritten, after once the agent is back", async () => {
    const { host, events, pushed } = harness(["running", "starting", "running"], [snap(["A/x"]), snap(["A/x", "B/y"])]);
    await host.handleRestart({ ...START, ref: "r1" });
    expect(events).toEqual(["snapshot", "start:true", "snapshot"]);
    const restarted = pushed.filter(([e]) => e === "agent.restarted");
    expect(restarted).toHaveLength(1);
    expect(restarted[0]![1]).toEqual({ ref: "r1", agent_id: A, outcome: "ready", before: snap(["A/x"]), after: snap(["A/x", "B/y"]) });
  });

  test("a needs_login agent returns no probe output", async () => {
    const { host, events, pushed } = harness(["needs_login"], []);
    await host.handleRestart({ ...START, ref: "r2" });
    expect(events).toEqual(["start:true"]);
    expect(pushed.find(([e]) => e === "agent.restarted")![1]).toEqual({ ref: "r2", agent_id: A, outcome: "needs_login", before: null, after: null });
  });

  test("an agent that never comes back is a timeout, and still answered", async () => {
    const { host, pushed } = harness(["running", "starting"], [snap([]), snap([])]);
    await host.handleRestart({ ...START, ref: "r3" });
    expect(pushed.find(([e]) => e === "agent.restarted")![1]).toMatchObject({ ref: "r3", outcome: "timeout" });
  });

  test("without a ref it is the old start: no agent.restarted", async () => {
    const { host, events, pushed } = harness(["running"], []);
    await host.handleRestart({ ...START });
    expect(events).toEqual(["start:true"]);
    expect(pushed.some(([e]) => e === "agent.restarted")).toBe(false);
  });

  test("a malformed restart with a ref is answered gone, nothing started", async () => {
    const { host, events, pushed } = harness(["running"], []);
    await host.handleRestart({ agent_id: A, ref: "r4" });
    expect(events).toEqual([]);
    expect(pushed).toEqual([["agent.restarted", { ref: "r4", agent_id: A, outcome: "gone", before: null, after: null }]]);
  });
});

describe("which servers, and parsing", () => {
  test("only approved .mcp.json servers", () => {
    const mcp = JSON.stringify({ mcpServers: { A: { command: "a" }, B: { command: "b" }, C: { url: "http://x.invalid" } } });
    expect(approvedServers(mcp, [null, JSON.stringify({ enabledMcpjsonServers: ["A", "C"] })]).map((s) => s.name)).toEqual(["A", "C"]);
    expect(approvedServers(mcp, [JSON.stringify({ enableAllProjectMcpServers: true, disabledMcpjsonServers: ["B"] }), null]).map((s) => s.name)).toEqual(["A", "C"]);
    expect(approvedServers(null, [])).toEqual([]);
  });

  test("tools/list result by id 2; no answer is null", () => {
    expect(toolsFromStdout('{"id":1,"result":{}}\n{"id":2,"result":{"tools":[{"name":"x"},{"name":"y"}]}}\n')).toEqual(["x", "y"]);
    expect(toolsFromStdout('{"id":1,"result":{}}\n')).toBeNull();
  });
});

describe("the probe, for real (a stdio server, no runuser)", () => {
  const dir = mkdtempSync(resolve(tmpdir(), "ah-probe-"));
  const server = resolve(dir, "server.js");
  writeFileSync(
    server,
    `let b="";process.stdin.on("data",c=>{b+=c;let i;while((i=b.indexOf("\\n"))!==-1){const l=b.slice(0,i);b=b.slice(i+1);if(!l.trim())continue;const m=JSON.parse(l);
if(process.env.SILENT||m.id===undefined)continue;
const r=m.method==="initialize"?{protocolVersion:"2025-06-18",capabilities:{}}:m.method==="tools/list"?{tools:(process.env.TOOLS||"").split(",").filter(Boolean).map(name=>({name}))}:{};
process.stdout.write(JSON.stringify({jsonrpc:"2.0",id:m.id,result:r})+"\\n")}});`,
  );
  const work = resolve(dir, "work");
  mkdirSync(resolve(work, ".claude"), { recursive: true });
  const probe = `probe-${crypto.randomUUID()}`;
  writeFileSync(
    resolve(work, ".mcp.json"),
    JSON.stringify({
      mcpServers: {
        A: { command: process.execPath, args: [server], env: { TOOLS: "a_one,a_two", API_KEY: probe } },
        Q: { command: process.execPath, args: [server], env: { SILENT: "1", TOKEN: probe } },
      },
    }),
  );
  writeFileSync(resolve(work, ".claude/settings.local.json"), JSON.stringify({ enabledMcpjsonServers: ["A", "Q"] }));

  // runuser is root-only: strip it and run the rest as this user. Files are read by READ_SCRIPT the same way.
  const seen: { argv: string[]; env?: Record<string, string> }[] = [];
  const runner: Runner = {
    async run(argv, options = {}) {
      seen.push({ argv, env: options.env });
      const real = argv[0] === "runuser" ? argv.slice(argv.indexOf("--") + 1) : argv;
      const proc = Bun.spawn(real, { env: options.env ?? (process.env as Record<string, string>), stdin: options.stdin === undefined ? "ignore" : new Blob([options.stdin]), stdout: "pipe", stderr: "pipe" });
      const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      return { exitCode, stdout, stderr };
    },
  };

  test("lists A's tools, reports Q unreachable, runs as the agent with no host env and no secret in argv", async () => {
    try {
      const s = await snapshotTools({ runner, seconds: 2 }, { name: "agent-x", home: dir, work });
      expect(s.tools).toEqual(["A/a_one", "A/a_two", "unreachable:Q"]);
      expect(JSON.stringify(s)).not.toContain(probe);
      const probes = seen.filter((c) => c.argv.includes(PROBE_SCRIPT));
      expect(probes).toHaveLength(2);
      for (const p of probes) {
        expect(p.argv.slice(0, 4)).toEqual(["runuser", "-u", "agent-x", "--"]);
        expect(p.argv.join(" ")).not.toContain(probe);
        expect(Object.keys(p.env ?? {}).sort()).toEqual(expect.arrayContaining(["HOME", "PATH"]));
        expect(p.env?.["AGENT_HOST_TOKEN"]).toBeUndefined();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 20_000);
});
