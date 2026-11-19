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

import * as nodeFs from "node:fs";
import { burrowAgentsDir } from "./agents.ts";
import { connectionKey } from "./ids.ts";

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

/* ------------------------------------------------------------------------- */
/* Codex harness (core task 01a1f4c6 stage 2)                                 */
/* ------------------------------------------------------------------------- */

/*
 * A Codex agent's bridge (`burrow codex --no-session`) runs in the runner's
 * place with no tmux session, and burrow-cli's `codex` has no
 * `--remote-terminal`: only `burrow claude` records the opt-in. So for the
 * codex harness the runner provides both halves itself: a shell session named
 * SESSION for the terminal to attach to, and the `remoteTerminal` marker on
 * this agent folder's own record, in the format burrow-cli reads
 * (test/runner_terminal.test.ts reads it back through burrow-cli's own
 * reader, vendored at the pinned BURROW_CLI_REF). Who may open it is still
 * core's TerminalViewChannel join, on the runtime's CURRENT owner.
 */

export interface ShellSessionIo {
  spawn(argv: string[]): Promise<{ exitCode: number }>;
}

/** The tmux argv that makes the owner's shell session: detached, in the work dir, as a login shell. */
export function shellSessionArgv(session: string, workDir: string, shell: string): string[] {
  return ["tmux", "new-session", "-d", "-s", session, "-c", workDir, shell, "-l"];
}

/**
 * Make sure this agent's tmux server has `session`. TMUX_TMPDIR (units.ts
 * dropIn) points tmux at this agent's 0700 runtime dir. Returns true when it
 * had to create it. Never types into anything.
 */
export async function ensureShellSession(io: ShellSessionIo, session: string, workDir: string, shell: string): Promise<boolean> {
  if ((await io.spawn(["tmux", "has-session", "-t", `=${session}`])).exitCode === 0) return false;
  const made = await io.spawn(shellSessionArgv(session, workDir, shell));
  if (made.exitCode !== 0) throw new Error(`tmux new-session exited ${made.exitCode}`);
  return true;
}

/** The fs calls {@link markRemoteTerminal} makes, injectable so a test can see every path it opens. */
export interface RecordFs {
  readFileSync(path: string, encoding: "utf8"): string;
  writeFileSync(path: string, data: string, options: { mode: number }): void;
  chmodSync(path: string, mode: number): void;
  renameSync(from: string, to: string): void;
}

export type MarkResult = "marked" | "already" | "no-record";

/** This agent folder's record: `<home>/.config/burrow/agents/<connectionKey(work)>.json` (agents.ts writeConnection). */
export function agentRecordPath(home: string, workDir: string): string {
  return `${burrowAgentsDir({ home })}/${connectionKey(workDir)}.json`;
}

/**
 * Write `remoteTerminal: session` into this agent's OWN record, keeping every
 * other field. Mirrors burrow-cli src/terminal/host.ts setRemoteTerminal at
 * the pinned ref: no record for this exact folder is a refusal ("no-record"),
 * an unchanged marker writes nothing, and a change goes to `<path>.tmp-<pid>`
 * at 0600 then is renamed over the record. Only the record is ever opened;
 * the `<key>.credentials.json` beside it is never read or written.
 */
export function markRemoteTerminal(home: string, workDir: string, session: string, fs: RecordFs = nodeFs, pid: number = process.pid): MarkResult {
  const path = agentRecordPath(home, workDir);
  let prior: Record<string, unknown>;
  try {
    const parsed = JSON.parse(fs.readFileSync(path, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return "no-record";
    prior = parsed as Record<string, unknown>;
  } catch {
    return "no-record";
  }
  if (prior.dir !== workDir) return "no-record";
  if (prior.remoteTerminal === session) return "already";
  const next: Record<string, unknown> = { ...prior, remoteTerminal: session };
  const tmp = `${path}.tmp-${pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, path);
  return "marked";
}

export interface CodexTerminal {
  host: TerminalHostIo;
  shell: ShellSessionIo;
  home: string;
  workDir: string;
  /** The agent user's login shell (/bin/bash, users.ts). */
  loginShell: string;
  fs?: RecordFs;
}

/**
 * One pass: the shell session exists (an owner who typed `exit` gets a fresh
 * one), then the marker is on it (burrow watch clears it when the session it
 * served is gone). Never throws; logs only on a change of outcome.
 */
export async function assertCodexTerminal(t: CodexTerminal, session: string, log: (line: string) => void, last: { v: string }): Promise<void> {
  let outcome: string;
  try {
    const made = await ensureShellSession(t.shell, session, t.workDir, t.loginShell);
    const mark = markRemoteTerminal(t.home, t.workDir, session, t.fs);
    outcome = mark === "no-record" ? "no connection record for this folder yet; terminal marker not written" : "on";
    if (made) log(`terminal: shell session ${session} started in ${t.workDir}`);
  } catch (err) {
    outcome = `could not be set up (${err instanceof Error ? err.message : "error"})`;
  }
  if (outcome !== last.v) {
    log(`terminal: ${outcome}`);
    last.v = outcome;
  }
}
