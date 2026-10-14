/**
 * What `suite-agent@<id>.service` runs, AS THE AGENT'S OWN USER.
 *
 * 1. `suite claude --session suite-agent` in the agent's work dir, with no
 *    terminal. suite-cli does all the Claude wiring (plugin checkout, MCP
 *    entries, CLAUDE.md if absent), creates the tmux session, answers the
 *    launch dialogs it knows, and returns. Its tmux server's socket is under
 *    $TMUX_TMPDIR, this agent's 0700 runtime dir (see units.ts).
 * 2. Every few seconds, `suite pane-status --session suite-agent --answer`:
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
 */
import { SESSION } from "./ids.ts";

export const POLL_MS = 5_000;

export interface RunnerIo {
  spawn(argv: string[]): Promise<{ exitCode: number; stdout: string }>;
  sleep(ms: number): Promise<void>;
  log(line: string): void;
  stopping(): boolean;
}

/** One check. Returns false when the session is gone. */
export async function alive(io: RunnerIo, session: string): Promise<boolean> {
  const status = await io.spawn(["suite", "pane-status", "--session", session, "--answer"]);
  if (status.exitCode === 0) return true;
  if (status.exitCode === 1) return false;
  // An older suite-cli without pane-status (exit 2): fall back to tmux itself.
  return (await io.spawn(["tmux", "has-session", "-t", `=${session}`])).exitCode === 0;
}

export async function runAgent(io: RunnerIo, session: string = SESSION): Promise<number> {
  const launched = await io.spawn(["suite", "claude", "--session", session]);
  // `suite claude` ends by trying to attach, which fails with no terminal; its
  // exit code says nothing about the session. The session is the truth.
  io.log(`suite claude returned ${launched.exitCode}`);
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

if (import.meta.main) {
  let stopping = false;
  const io: RunnerIo = {
    async spawn(argv) {
      const proc = Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
      const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
      return { exitCode, stdout };
    },
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    log: (line) => console.error(`suite-agent: ${line}`),
    stopping: () => stopping,
  };
  process.on("SIGTERM", () => {
    stopping = true;
    // This agent's own tmux server only: TMUX_TMPDIR points at its runtime dir.
    Bun.spawnSync(["tmux", "kill-server"]);
    process.exit(0);
  });
  process.exit(await runAgent(io));
}
