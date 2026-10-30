/**
 * What `burrow-agent@<id>.service` runs, AS THE AGENT'S OWN USER.
 *
 * 1. `suite claude --session suite-agent` in the agent's work dir, with no
 *    terminal. suite-cli does all the Claude wiring (plugin checkout, MCP
 *    entries, CLAUDE.md if absent), creates the tmux session, answers the
 *    launch dialogs it knows, and returns. Its tmux server's socket is under
 *    $TMUX_TMPDIR, this agent's 0700 runtime dir (see units.ts).
 * 2. Every few seconds, `burrow pane-status --session suite-agent --answer`:
 *    suite-cli looks at the pane, answers a known dialog if one is up, and
 *    writes the status file the agent host reads. There is no pane classifier
 *    here; it is suite-cli's.
 * 3. When the session is gone without a stop, exit 1, so systemd's
 *    Restart=on-failure brings the agent back and the host reports `crashed`
 *    if it keeps failing. On SIGTERM (systemctl stop), kill this agent's tmux
 *    server and exit 0.
 *
 * Nothing here ever types into the pane. Logging in is the person's, through
 * Anthropic's own flow.
 *
 * HARNESS `codex` (core task 01a10315 stage 4; the env file's
 * BURROW_AGENT_HARNESS says which):
 *
 * 1. While `codex login status` is non-zero, Codex's own device login
 *    (codex_login.ts): the status file carries its URL and one-time code for
 *    the owner to enter on auth.openai.com, and a fresh login starts when one
 *    expires, at most once a minute.
 * 2. Then `burrow codex --no-session` in the work dir, which runs burrow-cli's
 *    Codex bridge in this process's place and returns only when it ends. Not
 *    `--session`: burrow-cli 9a8ef75's `codex` refuses that option by name,
 *    and names its tmux session for the agent, not `suite-agent`, so this
 *    unit supervises the bridge directly, with systemd's restart.
 * 3. Ready (status `ready`) is: the unit is active and `codex login status`
 *    exits 0. `burrow pane-status` reads a Claude pane and is not used.
 */
import { mkdirSync } from "node:fs";
import { SESSION, statusFile } from "./ids.ts";
import {
  codexEnv,
  codexHomeFor,
  ensureCodexLogin,
  writeStatusFile,
  type CodexLoginIo,
  type CodexLoginOptions,
} from "./codex_login.ts";

export const POLL_MS = 5_000;

export interface RunnerIo {
  spawn(argv: string[]): Promise<{ exitCode: number; stdout: string }>;
  sleep(ms: number): Promise<void>;
  log(line: string): void;
  stopping(): boolean;
}

/** One check. Returns false when the session is gone. */
export async function alive(io: RunnerIo, session: string): Promise<boolean> {
  const status = await io.spawn(["burrow", "pane-status", "--session", session, "--answer"]);
  if (status.exitCode === 0) return true;
  if (status.exitCode === 1) return false;
  // An older burrow-cli without pane-status (exit 2): fall back to tmux itself.
  return (await io.spawn(["tmux", "has-session", "-t", `=${session}`])).exitCode === 0;
}

export async function runAgent(io: RunnerIo, session: string = SESSION): Promise<number> {
  const launched = await io.spawn(["burrow", "claude", "--session", session]);
  // `burrow claude` ends by trying to attach, which fails with no terminal; its
  // exit code says nothing about the session. The session is the truth.
  io.log(`burrow claude returned ${launched.exitCode}`);
  for (;;) {
    if (io.stopping()) return 0;
    if (!(await alive(io, session))) {
      if (io.stopping()) return 0;
      io.log(`session ${session} is gone without a stop; exiting so systemd can restart it`);
      return 1;
    }
    await io.sleep(POLL_MS);
  }
}

/**
 * The codex loop (steps 1-3 above). `io.spawn` of the bridge returns when the
 * bridge ends; without a stop that is a failure, so systemd restarts it.
 */
export const CODEX_BRIDGE = ["burrow", "codex", "--no-session"];

export async function runCodexAgent(
  io: RunnerIo,
  login: CodexLoginIo,
  agentId: string,
  opts: CodexLoginOptions,
  runBridge: (argv: string[]) => Promise<number> = async (argv) => (await io.spawn(argv)).exitCode,
): Promise<number> {
  login.writeStatus({ state: "starting" });
  if (!(await ensureCodexLogin(agentId, login, opts))) return 0;
  login.writeStatus({ state: "ready" });
  const exitCode = await runBridge(CODEX_BRIDGE);
  if (io.stopping()) return 0;
  io.log(`burrow codex --no-session exited ${exitCode} without a stop; exiting so systemd can restart it`);
  login.writeStatus({ state: "starting", detail: "the Codex bridge exited" });
  return 1;
}

if (import.meta.main) {
  let stopping = false;
  const io: RunnerIo = {
    async spawn(argv) {
      const proc = Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
      const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
      return { exitCode, stdout };
    },
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    log: (line) => console.error(`burrow-agent: ${line}`),
    stopping: () => stopping,
  };
  process.on("SIGTERM", () => {
    stopping = true;
    // This agent's own tmux server only: TMUX_TMPDIR points at its runtime dir.
    Bun.spawnSync(["tmux", "kill-server"]);
    process.exit(0);
  });
  const agentId = process.env.BURROW_AGENT_ID ?? "";
  if (process.env.BURROW_AGENT_HARNESS === "codex") {
    const codexHome = codexHomeFor(process.cwd());
    mkdirSync(codexHome, { recursive: true, mode: 0o700 });
    // A stop's SIGTERM exits above; systemd's KillMode=control-group ends a
    // login or bridge child with the unit.
    const login: CodexLoginIo = {
      start(argv, env, onStdout) {
        const proc = Bun.spawn(argv, { env, stdin: "ignore", stdout: "pipe", stderr: "inherit" });
        const decoder = new TextDecoder();
        const pump = (async () => {
          for await (const chunk of proc.stdout) onStdout(decoder.decode(chunk, { stream: true }));
        })();
        return {
          exited: pump.then(() => proc.exited),
          kill: () => proc.kill(),
        };
      },
      async exitCode(argv, env) {
        const proc = Bun.spawn(argv, { env, stdin: "ignore", stdout: "ignore", stderr: "ignore" });
        return await proc.exited;
      },
      writeStatus: (status) => writeStatusFile(statusFile(agentId), status),
      now: () => Date.now(),
      sleep: io.sleep,
      log: io.log,
      stopping: io.stopping,
    };
    const opts = { codexBin: "codex", codexHome, env: codexEnv(process.env, codexHome) };
    // The bridge runs for the agent's life: its output goes to the journal, not a buffer.
    const runBridge = async (argv: string[]) => await Bun.spawn(argv, { stdin: "ignore", stdout: "inherit", stderr: "inherit" }).exited;
    process.exit(await runCodexAgent(io, login, agentId, opts, runBridge));
  }
  process.exit(await runAgent(io));
}
