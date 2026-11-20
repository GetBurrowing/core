/**
 * The owner's remote terminal on a hosted agent (core task 01a1f4c6).
 * Stage 1, Claude: the launch records the opt-in, the runner supervises the
 * terminal host child, and the record a start writes keeps the opt-in and
 * never turns config access on. Stage 2, Codex: the runner makes the shell
 * session and writes the marker itself, before the login loop, in the format
 * burrow-cli's own reader (vendored at the pinned ref) reads back.
 */
import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync, rmSync, statSync, mkdirSync, writeFileSync } from "node:fs";
import * as nodeFs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CLAUDE_LAUNCH, POLL_MS, runAgent, runCodexAgent, type RunnerIo } from "../src/runner.ts";
import {
  TERMINAL_HOST,
  TERMINAL_HOST_BACKOFF_MS,
  agentRecordPath,
  markRemoteTerminal,
  shellSessionArgv,
  superviseTerminalHost,
  type CodexTerminal,
  type RecordFs,
  type TerminalHostIo,
} from "../src/terminal_host.ts";
import { renderAgentRecord } from "../src/agents.ts";
import { connectionKey } from "../src/ids.ts";
import type { CodexLoginIo } from "../src/codex_login.ts";
import { VENDORED_REF, agentKey, parseAgentRecord, serializeAgentRecord } from "./fixtures/burrow_cli/agent_record.ts";

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

/* ------------------------------------------------------------------------- */
/* Stage 2: the Codex harness                                                 */
/* ------------------------------------------------------------------------- */

const HOME = "/home/agent-98259d347cbe";
const WORK = `${HOME}/work`;
const AGENT = "01a10322-e24f-7001-8356-98259d347cbe";
const OPTS = { codexBin: "codex", codexHome: `${WORK}/.codex`, env: { CODEX_HOME: `${WORK}/.codex` } };
const PRIOR = {
  dir: WORK,
  burrowUrl: "https://b.test",
  runtimeId: "rt-1",
  headerNames: ["CF-Access-Client-Id"],
  configAccess: "owner_only",
};

/** An in-memory fs that records every path it is asked to open. */
function memFs(files: Record<string, string> = {}) {
  const opened: string[] = [];
  const modes: Record<string, number> = {};
  const fs: RecordFs = {
    readFileSync(path) {
      opened.push(path);
      const v = files[path];
      if (v === undefined) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
      return v;
    },
    writeFileSync(path, data, opts) {
      opened.push(path);
      files[path] = data;
      modes[path] = opts.mode;
    },
    chmodSync(path, mode) {
      opened.push(path);
      modes[path] = mode;
    },
    renameSync(from, to) {
      opened.push(from, to);
      files[to] = files[from]!;
      modes[to] = modes[from]!;
      delete files[from];
      delete modes[from];
    },
  };
  return { fs, files, modes, opened };
}

/** The codex world: a tmux that knows which sessions exist, a login already done, and an event order. */
function codexWorld(opts: { sessionUp?: boolean; record?: string | null } = {}) {
  const order: string[] = [];
  const tmux: string[][] = [];
  let sessionUp = opts.sessionUp ?? false;
  const stop = { v: false };
  const path = agentRecordPath(HOME, WORK);
  const mem = memFs(opts.record === null ? {} : { [path]: opts.record ?? `${JSON.stringify(PRIOR, null, 2)}\n` });
  const io: RunnerIo = {
    async spawn(argv) {
      if (argv[0] === "tmux") {
        tmux.push(argv);
        order.push(`tmux ${argv[1]}`);
        if (argv[1] === "has-session") return { exitCode: sessionUp ? 0 : 1, stdout: "" };
        if (argv[1] === "new-session") sessionUp = true;
      }
      return { exitCode: 0, stdout: "" };
    },
    sleep: async () => {
      await tick();
    },
    log: () => {},
    stopping: () => stop.v,
  };
  const login: CodexLoginIo = {
    start() {
      throw new Error("no device login in this world");
    },
    async exitCode(argv) {
      order.push(argv.join(" "));
      return 0;
    },
    writeStatus: () => {},
    now: () => 0,
    sleep: async () => {},
    log: () => {},
    stopping: () => stop.v,
  };
  const h = hostIo(stop);
  const start = h.io.start;
  h.io.start = (argv) => (order.push("terminal host"), start(argv));
  const terminal: CodexTerminal = { host: h.io, shell: io, home: HOME, workDir: WORK, loginShell: "/bin/bash", fs: mem.fs };
  return {
    io,
    login,
    terminal,
    order,
    tmux,
    stop,
    host: h,
    mem,
    path,
    killSession: () => void (sessionUp = false),
  };
}

describe("the Codex harness gets a terminal", () => {
  test("the shell session is created when absent, in the work dir, as a login shell", async () => {
    const w = codexWorld({ sessionUp: false });
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async () => 7, w.terminal)).toBe(1);
    expect(w.tmux[0]).toEqual(["tmux", "has-session", "-t", "=suite-agent"]);
    expect(w.tmux[1]).toEqual(shellSessionArgv("suite-agent", WORK, "/bin/bash"));
    expect(shellSessionArgv("suite-agent", WORK, "/bin/bash")).toEqual(["tmux", "new-session", "-d", "-s", "suite-agent", "-c", WORK, "/bin/bash", "-l"]);
    expect(w.tmux.filter((a) => a[1] === "new-session")).toHaveLength(1);
    // Nothing is ever typed into it.
    expect(w.tmux.some((a) => a[1] === "send-keys")).toBe(false);
  });

  test("an existing shell session is left alone", async () => {
    const w = codexWorld({ sessionUp: true });
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async () => 7, w.terminal)).toBe(1);
    expect(w.tmux.filter((a) => a[1] === "new-session")).toHaveLength(0);
    expect(w.tmux.filter((a) => a[1] === "has-session").length).toBeGreaterThanOrEqual(1);
  });

  test("the terminal host child starts before the login loop, after the session and the marker", async () => {
    const w = codexWorld();
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async () => 7, w.terminal)).toBe(1);
    const host = w.order.indexOf("terminal host");
    const loginCheck = w.order.findIndex((e) => e.startsWith("codex login status"));
    expect(host).toBeGreaterThan(-1);
    expect(loginCheck).toBeGreaterThan(host);
    expect(w.order.indexOf("tmux new-session")).toBeLessThan(host);
    expect(w.host.started).toEqual([[...TERMINAL_HOST]]);
    // The marker was already on the record when the host first started.
    expect(JSON.parse(w.mem.files[w.path]!).remoteTerminal).toBe("suite-agent");
  });

  test("the marker is written with every prior field kept, at 0600, through a temp file and a rename", async () => {
    const w = codexWorld();
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async () => 7, w.terminal)).toBe(1);
    const after = JSON.parse(w.mem.files[w.path]!);
    expect(after).toEqual({ ...PRIOR, remoteTerminal: "suite-agent" });
    expect(w.mem.modes[w.path]).toBe(0o600);
    const tmp = `${w.path}.tmp-${process.pid}`;
    expect(w.mem.opened).toContain(tmp);
    expect(tmp in w.mem.files).toBe(false);
  });

  test("the credentials file is never opened, and nothing outside this folder's record is", async () => {
    const w = codexWorld();
    w.mem.files[w.path.replace(/\.json$/, ".credentials.json")] = "NEVER-READ";
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async () => 7, w.terminal)).toBe(1);
    expect(w.mem.opened.length).toBeGreaterThan(0);
    expect(w.mem.opened.some((p) => p.includes("credentials"))).toBe(false);
    expect(w.mem.opened.every((p) => p === w.path || p === `${w.path}.tmp-${process.pid}`)).toBe(true);
    expect(w.path).toBe(`${HOME}/.config/burrow/agents/${connectionKey(WORK)}.json`);
  });

  test("an unchanged marker writes nothing; a record for another folder, or none, is refused", () => {
    const m = memFs();
    const path = agentRecordPath(HOME, WORK);
    m.files[path] = `${JSON.stringify({ ...PRIOR, remoteTerminal: "suite-agent" }, null, 2)}\n`;
    expect(markRemoteTerminal(HOME, WORK, "suite-agent", m.fs)).toBe("already");
    expect(m.opened).toEqual([path]);
    m.files[path] = `${JSON.stringify({ ...PRIOR, dir: "/elsewhere" }, null, 2)}\n`;
    expect(markRemoteTerminal(HOME, WORK, "suite-agent", m.fs)).toBe("no-record");
    expect(JSON.parse(m.files[path]!).remoteTerminal).toBeUndefined();
    expect(markRemoteTerminal(HOME, WORK, "suite-agent", memFs().fs)).toBe("no-record");
  });

  test("while the bridge runs, a shell the owner exited and a marker watch cleared both come back", async () => {
    const w = codexWorld();
    let release!: (code: number) => void;
    const bridge = new Promise<number>((r) => (release = r));
    const done = runCodexAgent(w.io, w.login, AGENT, OPTS, () => bridge, w.terminal);
    for (let i = 0; i < 5; i++) await tick();
    expect(w.tmux.filter((a) => a[1] === "new-session")).toHaveLength(1);
    // The owner typed `exit`; burrow watch saw the session go and cleared the marker.
    w.killSession();
    const { remoteTerminal: _gone, ...cleared } = JSON.parse(w.mem.files[w.path]!);
    w.mem.files[w.path] = `${JSON.stringify(cleared, null, 2)}\n`;
    for (let i = 0; i < 10 && w.tmux.filter((a) => a[1] === "new-session").length < 2; i++) await tick();
    expect(w.tmux.filter((a) => a[1] === "new-session")).toHaveLength(2);
    for (let i = 0; i < 5; i++) await tick();
    expect(JSON.parse(w.mem.files[w.path]!).remoteTerminal).toBe("suite-agent");
    expect(POLL_MS).toBe(5_000);
    w.stop.v = true;
    release(143);
    expect(await done).toBe(0);
  });

  test("a terminal that cannot be set up never stops the agent from logging in and bridging", async () => {
    const w = codexWorld({ record: null });
    w.io.spawn = async () => ({ exitCode: 1, stdout: "" }); // tmux cannot make a session
    const bridges: string[][] = [];
    expect(await runCodexAgent(w.io, w.login, AGENT, OPTS, async (argv) => (bridges.push(argv), 7), w.terminal)).toBe(1);
    expect(bridges).toHaveLength(1);
  });
});

describe("the record round-trips through burrow-cli's own reader (vendored at BURROW_CLI_REF)", () => {
  test("the vendored reader is pinned to the BURROW_CLI_REF agent-host installs", () => {
    const env = readFileSync(join(import.meta.dir, "..", "versions.env"), "utf8");
    const ref = /^BURROW_CLI_REF=(\S+)$/m.exec(env)?.[1];
    // A bump fails here until test/fixtures/burrow_cli/agent_record.ts is re-vendored from the new ref.
    expect(ref).toBe(VENDORED_REF);
  });

  test("a start's record plus the Codex marker is what burrow-cli reads, byte for byte, at the key it reads", () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "rt-roundtrip-")));
    try {
      const home = join(root, "home");
      const work = join(home, "work");
      mkdirSync(work, { recursive: true });
      // burrow-cli finds the record by its own key for the folder.
      expect(connectionKey(work)).toBe(agentKey(work));
      const path = agentRecordPath(home, work);
      mkdirSync(join(home, ".config", "burrow", "agents"), { recursive: true });
      writeFileSync(path, renderAgentRecord(null, work, "https://b.test", "rt-1"), { mode: 0o600 });

      expect(markRemoteTerminal(home, work, "suite-agent", nodeFs)).toBe("marked");
      const text = readFileSync(path, "utf8");
      const rec = parseAgentRecord(text);
      expect(rec).not.toBeNull();
      expect(rec!.dir).toBe(work);
      expect(rec!.suiteUrl).toBe("https://b.test");
      expect(rec!.runtimeId).toBe("rt-1");
      expect(rec!.remoteTerminal).toBe("suite-agent");
      expect(rec!.configAccess).toBeUndefined();
      // Byte-identical to what burrow-cli would write for the same record: no
      // field it does not know, none it would drop, same order and layout.
      expect(serializeAgentRecord(rec!)).toBe(text);
      expect(statSync(path).mode & 0o777).toBe(0o600);

      // And the next start keeps the marker, as burrow-cli's reader sees it.
      const restarted = renderAgentRecord(text, work, "https://b.test", "rt-1");
      expect(parseAgentRecord(restarted)!.remoteTerminal).toBe("suite-agent");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
