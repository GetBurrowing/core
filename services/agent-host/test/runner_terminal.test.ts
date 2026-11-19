/**
 * The owner's remote terminal on a hosted Claude agent (core task 01a1f4c6
 * stage 1): the launch records the opt-in, the runner supervises the
 * terminal host child, and the record a start writes keeps the opt-in and
 * never turns config access on.
 */
import { describe, expect, test } from "bun:test";
import { CLAUDE_LAUNCH, runAgent, type RunnerIo } from "../src/runner.ts";
import { TERMINAL_HOST, TERMINAL_HOST_BACKOFF_MS, superviseTerminalHost, type TerminalHostIo } from "../src/terminal_host.ts";
import { renderAgentRecord } from "../src/agents.ts";

const tick = () => new Promise((r) => setTimeout(r, 0));

function runnerIo(paneStatus: number[], stop = { v: false }): RunnerIo & { calls: string[][] } {
  const calls: string[][] = [];
  return {
    calls,
    async spawn(argv) {
      calls.push(argv);
      if (argv[1] === "pane-status") return { exitCode: paneStatus.length > 1 ? paneStatus.shift()! : paneStatus[0]!, stdout: "" };
      return { exitCode: 0, stdout: "" };
    },
    sleep: async () => {
      await tick();
    },
    log: () => {},
    stopping: () => stop.v,
  };
}

/** A terminal host io whose children exit when told to; `sleeps` records each backoff. */
function hostIo(stop = { v: false }) {
  const started: string[][] = [];
  const sleeps: number[] = [];
  const exits: ((code: number) => void)[] = [];
  const logs: string[] = [];
  let failStart = false;
  const io: TerminalHostIo = {
    start(argv) {
      started.push(argv);
      if (failStart) throw new Error("ENOENT: burrow");
      return { exited: new Promise<number>((r) => exits.push(r)) };
    },
    sleep: async (ms) => {
      sleeps.push(ms);
      await tick();
    },
    log: (l) => logs.push(l),
    stopping: () => stop.v,
  };
  return { io, started, sleeps, exits, logs, stop, failToStart: () => void (failStart = true) };
}

describe("the Claude launch records the remote-terminal opt-in", () => {
  test("runAgent spawns exactly CLAUDE_LAUNCH first, with --remote-terminal", async () => {
    expect(CLAUDE_LAUNCH).toEqual(["burrow", "claude", "--session", "suite-agent", "--remote-terminal"]);
    const r = runnerIo([0, 1]);
    expect(await runAgent(r)).toBe(1);
    expect(r.calls[0]).toEqual(CLAUDE_LAUNCH);
    expect(r.calls.filter((c) => c[1] === "claude")).toHaveLength(1);
  });

  test("the terminal host starts after the launch, as TERMINAL_HOST with no token and no send-keys", async () => {
    expect(TERMINAL_HOST).toEqual(["burrow", "watch", "--no-install", "--host-only", "--interval", "10"]);
    const r = runnerIo([0, 0, 1]);
    const h = hostIo();
    const order: string[] = [];
    const spawn = r.spawn.bind(r);
    r.spawn = async (argv) => (order.push(argv.slice(0, 2).join(" ")), spawn(argv));
    const start = h.io.start;
    h.io.start = (argv) => (order.push("terminal host"), start(argv));
    expect(await runAgent(r, "suite-agent", h.io)).toBe(1);
    expect(order.slice(0, 2)).toEqual(["burrow claude", "terminal host"]);
    expect(h.started).toEqual([[...TERMINAL_HOST]]);
    expect(TERMINAL_HOST.join(" ")).not.toMatch(/token|send-keys|--dry-run/i);
  });

  test("a terminal host that cannot start never ends runAgent; the session decides", async () => {
    const r = runnerIo([0, 0, 0, 0, 1]);
    const h = hostIo();
    h.failToStart();
    expect(await runAgent(r, "suite-agent", h.io)).toBe(1);
    expect(r.calls.filter((c) => c[1] === "pane-status")).toHaveLength(5);
    expect(h.started.length).toBeGreaterThanOrEqual(1);
    // Logged by name only.
    expect(h.logs.join("\n")).not.toContain("ENOENT");
    h.stop.v = true;
  });
});

describe("superviseTerminalHost", () => {
  test("spawns TERMINAL_HOST and respawns it 5 s after it exits", async () => {
    const h = hostIo();
    const done = superviseTerminalHost(h.io);
    await tick();
    expect(h.started).toEqual([[...TERMINAL_HOST]]);
    h.exits[0]!(1); // watch's RSS-ceiling exit
    for (let i = 0; i < 5 && h.started.length < 2; i++) await tick();
    expect(h.sleeps).toEqual([TERMINAL_HOST_BACKOFF_MS]);
    expect(TERMINAL_HOST_BACKOFF_MS).toBe(5_000);
    expect(h.started).toEqual([[...TERMINAL_HOST], [...TERMINAL_HOST]]);
    h.stop.v = true;
    h.exits[1]!(0);
    await done;
  });

  test("does not respawn after a stop", async () => {
    const h = hostIo();
    const done = superviseTerminalHost(h.io);
    await tick();
    h.stop.v = true;
    h.exits[0]!(143);
    await done;
    expect(h.started).toHaveLength(1);
    expect(h.sleeps).toEqual([]);
  });

  test("a child that fails to spawn is retried after the backoff, and the supervisor never rejects", async () => {
    const h = hostIo();
    h.failToStart();
    const done = superviseTerminalHost(h.io);
    for (let i = 0; i < 10 && h.started.length < 3; i++) await tick();
    expect(h.started.length).toBeGreaterThanOrEqual(3);
    expect(h.sleeps.every((ms) => ms === TERMINAL_HOST_BACKOFF_MS)).toBe(true);
    h.stop.v = true;
    await expect(done).resolves.toBeUndefined();
  });
});

describe("the record a start writes", () => {
  const DIR = "/home/agent-x/work";
  test("keeps remoteTerminal across starts and never writes configAccess", () => {
    // First start: no record yet. Then `burrow claude --remote-terminal` sets the opt-in.
    const first = JSON.parse(renderAgentRecord(null, DIR, "https://b.test", "rt-1"));
    expect("configAccess" in first).toBe(false);
    const marked = JSON.stringify({ ...first, remoteTerminal: "suite-agent" });
    // Every later start (token rotation, restart, image update) re-renders it.
    let rec = marked;
    for (let start = 0; start < 3; start++) rec = renderAgentRecord(rec, DIR, "https://b.test", "rt-1");
    const after = JSON.parse(rec);
    expect(after.remoteTerminal).toBe("suite-agent");
    // configAccess absent = off, so burrow watch opens the terminal topic ONLY
    // and never registers runtime_host: beside the agent host's own file serving.
    expect("configAccess" in after).toBe(false);
    expect(Object.keys(after).sort()).toEqual(["burrowUrl", "dir", "headerNames", "remoteTerminal", "runtimeId"]);
  });
});
