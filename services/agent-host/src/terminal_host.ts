/**
 * The owner's remote terminal for a hosted Claude agent (core task 01a1f4c6).
 *
 * `burrow claude --remote-terminal` (runner.ts CLAUDE_LAUNCH) only RECORDS the
 * opt-in, as `remoteTerminal` on this agent folder's record. The terminal is
 * SERVED by burrow-cli's host manager inside `burrow watch`, which joins
 * `terminal:<runtime_id>` on the runtime socket and attaches a tmux client to
 * the named session when the owner opens it. Who may open it is core's
 * TerminalViewChannel join, on the runtime's CURRENT owner; nothing here
 * decides that.
 *
 * TERMINAL_HOST runs as a child of the runner: same unit, same cgroup, so
 * KillMode=control-group ends it on a stop. It inherits HOME, TMUX_TMPDIR and
 * PATH from the unit's drop-in (units.ts dropIn), so it reads this agent's
 * record under ~/.config/burrow/agents and talks to this agent's tmux server.
 *
 * - `--host-only` (burrow-cli 0.19.0): the host connections and nothing else.
 *   No halt sweep, no dialog answers: it never sends a key to the pane, which
 *   keeps runner.ts's rule that nothing here types into it. burrow-cli tests
 *   pin that (test/claude_dialogs.test.ts, "watch --host-only never types").
 * - `--no-install`: otherwise watch would write a systemd user unit for itself
 *   in the agent's home.
 * - No token in argv: watch reads the folder's own credentials file.
 *
 * The agent never depends on it: a terminal host that will not start, or that
 * exits (watch exits 1 on its own RSS ceiling by design), is logged and
 * started again after TERMINAL_HOST_BACKOFF_MS. It never ends the runner.
 */

export const TERMINAL_HOST = ["burrow", "watch", "--no-install", "--host-only", "--interval", "10"] as const;
export const TERMINAL_HOST_BACKOFF_MS = 5_000;

export interface TerminalHostIo {
  /** Start `argv` as a child; `exited` resolves with its exit code. May throw. */
  start(argv: string[]): { exited: Promise<number> };
  sleep(ms: number): Promise<void>;
  log(line: string): void;
  stopping(): boolean;
}

/**
 * Keep TERMINAL_HOST running until the runner stops. Never rejects. Logs
 * argv and exit codes only.
 */
export async function superviseTerminalHost(io: TerminalHostIo): Promise<void> {
  const argv = [...TERMINAL_HOST];
  for (;;) {
    if (io.stopping()) return;
    let outcome: string;
    try {
      io.log(`terminal host: starting ${argv.join(" ")}`);
      outcome = `exited ${await io.start(argv).exited}`;
    } catch (err) {
      outcome = `could not start (${err instanceof Error ? err.name : "error"})`;
    }
    if (io.stopping()) return;
    io.log(`terminal host ${outcome}; starting it again in ${TERMINAL_HOST_BACKOFF_MS / 1000}s (the agent keeps running)`);
    try {
      await io.sleep(TERMINAL_HOST_BACKOFF_MS);
    } catch {
      return;
    }
  }
}
