/**
 * An agent's recent pane text, for Suite's read-only "Recent output"
 * disclosure (core task 01a10322 stage 6).
 *
 * READ ONLY. This captures the pane; nothing in this daemon ever types into
 * it. There is no command from core that carries keystrokes, and there must
 * not be: a Claude login code typed into Suite and relayed here would be Suite
 * intermediating a Claude login, which Anthropic's terms forbid.
 *
 * WHAT IT WITHHOLDS. A pane that shows a Claude login screen (the method
 * chooser, the sign-in URL and paste prompt, the API-key confirmation) is not
 * sent at all: `hidden: "login"`, no lines. Every other line is scrubbed of
 * anything shaped like a credential. Core applies the same rules again
 * (`Platform.AgentHost.Redact`), so neither side is trusted alone.
 */
import type { Runner } from "./exec.ts";
import { SESSION, isAgentId, runDir, userName } from "./ids.ts";

export const MAX_LINES = 200;
export const MAX_LINE = 500;

export const LOGIN_MARKERS = [
  "Select login method",
  "Paste code here",
  "Browser didn't open? Use the url below to sign in",
  "/oauth/authorize",
  "/oauth/code/callback",
  "Detected a custom API key in your environment",
] as const;

const SCRUBS: [RegExp, string][] = [
  // `+`, not `*`: scrubbing is idempotent, so core's second pass over this
  // output leaves "sk-ant-[redacted]" as it is.
  [/sk-ant-[A-Za-z0-9_.-]+/g, "sk-ant-[redacted]"],
  [/\b((?:ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_[A-Z_]+)\s*[:=]\s*)\S+/g, "$1[redacted]"],
  [/([?&](?:code|state|code_challenge)=)[^&\s]+/g, "$1[redacted]"],
  [/\b(Bearer\s+)\S+/gi, "$1[redacted]"],
];

export interface PaneOutput {
  lines: string[];
  hidden: "login" | null;
}

export function isLoginScreen(lines: string[]): boolean {
  return lines.some((l) => LOGIN_MARKERS.some((m) => l.includes(m)));
}

export function scrubLine(line: string): string {
  let out = line;
  for (const [re, rep] of SCRUBS) out = out.replace(re, rep);
  return out.slice(0, MAX_LINE);
}

/** Captured text → what may leave this machine. Pure. */
export function redactPane(text: string, statusSaysLogin: boolean): PaneOutput {
  const lines = text.split("\n").map((l) => l.trimEnd());
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  if (statusSaysLogin || isLoginScreen(lines)) return { lines: [], hidden: "login" };
  return { lines: lines.slice(-MAX_LINES).map(scrubLine), hidden: null };
}

/** The argv that captures the last `n` lines of the agent's pane, as the agent. */
export function captureArgv(agentId: string, n: number): string[] {
  if (!isAgentId(agentId)) throw new Error("not an agent id");
  const lines = Math.max(1, Math.min(MAX_LINES, Math.floor(n)));
  return [
    "runuser",
    "-u",
    userName(agentId),
    "--",
    "env",
    `TMUX_TMPDIR=${runDir(agentId)}`,
    "tmux",
    "capture-pane",
    "-p",
    "-J",
    "-t",
    `=${SESSION}:`,
    "-S",
    `-${lines}`,
  ];
}

export async function agentPane(runner: Runner, agentId: string, n: number, statusSaysLogin: boolean): Promise<PaneOutput> {
  if (statusSaysLogin) return { lines: [], hidden: "login" };
  const r = await runner.run(captureArgv(agentId, n));
  if (r.exitCode !== 0) return { lines: [], hidden: null };
  return redactPane(r.stdout, false);
}
