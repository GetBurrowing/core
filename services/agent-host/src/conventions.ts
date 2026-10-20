/**
 * Burrow's conventions, loaded for every native agent whatever its owner
 * writes in CLAUDE.md (task 01a10322 stage 7, round 2).
 *
 * THE DEFECT. The owner edits an agent's work-dir CLAUDE.md in Agent files,
 * and that file is the agent's own. suite-cli never overwrites an existing
 * CLAUDE.md: it writes its conventions to SUITE_CONVENTIONS.md instead, which
 * loads only if CLAUDE.md says `@SUITE_CONVENTIONS.md`. Core's seeded identity
 * file does not, and an owner who replaces it will not, so the agent never
 * read "Always respond in channel": it heard the mention and answered in its
 * own terminal (gate case 7008, measured: the same agent with the import line
 * replied in 10 s).
 *
 * THE FIX. The host writes the agent's USER memory, `~/.claude/CLAUDE.md`, on
 * every start. Claude Code loads it in every session in addition to the
 * project's CLAUDE.md, and the owner's editor cannot reach it: file keys are
 * relative to the work dir (files.ts), and `~` is refused. No import line is
 * involved, so nothing the owner deletes can unload it.
 *
 * ONE COPY OF THE PROSE. The text is suite-cli's own `SUITE_CONVENTIONS`, read
 * from the pinned install (install-tools.sh puts burrow-cli's sources under
 * /usr/local/share/burrow/cli), not a second copy kept here. The image build
 * fails if that export cannot be loaded (Dockerfile). If it still cannot be
 * read at start, {@link FALLBACK} carries the one rule whose absence makes an
 * agent silent, and the host says so in its log.
 */
import { join } from "node:path";
import type { Runner } from "./exec.ts";
import type { AgentUser } from "./users.ts";

/** Where install-tools.sh installs burrow-cli's library (XDG_DATA_HOME=/usr/local/share; <data>/burrow/cli since 0.9.0). */
export const BURROW_CLI_LIB = "/usr/local/share/burrow/cli";

/** The agent's user-level memory file, relative to its home. */
export const USER_MEMORY = ".claude/CLAUDE.md";

export const HEADER = [
  "# Burrow conventions",
  "",
  "Written by Burrow's agent host every time this agent starts; edits here do not last.",
  "Your owner's instructions for you are in ~/work/CLAUDE.md, managed from Agent",
  "Resources. These conventions apply whatever that file says.",
  "",
].join("\n");

/**
 * Used only when suite-cli's text cannot be loaded. The one convention without
 * which a native agent fails silently: an answer that never reaches Burrow.
 */
export const FALLBACK = [
  "## Always respond in channel",
  "",
  "Every reply to a Burrow message goes into the Burrow channel with the `suite_reply`",
  "tool, using the `space_id` from the inbound `<channel>` tag. A terminal-only answer",
  "is an answer nobody received.",
  "",
].join("\n");

/**
 * suite-cli's `SUITE_CONVENTIONS`, or null when `lib` has no loadable
 * `src/claude_md.ts` exporting a non-empty string.
 */
export async function loadSuiteConventions(lib: string = BURROW_CLI_LIB): Promise<string | null> {
  try {
    const mod = (await import(join(lib, "src", "claude_md.ts"))) as { SUITE_CONVENTIONS?: unknown };
    const text = mod.SUITE_CONVENTIONS;
    return typeof text === "string" && text.trim() !== "" ? text : null;
  } catch {
    return null;
  }
}

/** The user memory file's content. Pure. */
export function renderUserMemory(conventions: string | null): string {
  const body = conventions ?? FALLBACK;
  return `${HEADER}\n${body.endsWith("\n") ? body : `${body}\n`}`;
}

/** The absolute path of `user`'s user memory file. */
export function userMemoryPath(user: AgentUser): string {
  return `${user.home}/${USER_MEMORY}`;
}

/**
 * Write the user memory file AS THE AGENT, through a temp file and a rename,
 * content on stdin. `~/.claude` is the agent's own directory, so the write is
 * the agent's: a symlink it planted there redirects only its own write.
 */
export async function writeUserMemory(runner: Runner, user: AgentUser, content: string): Promise<void> {
  const script =
    'set -e; umask 022; mkdir -p "$(dirname "$1")"; tmp="$1.tmp.$$"; cat > "$tmp"; chmod 0644 "$tmp"; mv -fT "$tmp" "$1"';
  const path = userMemoryPath(user);
  const r = await runner.run(["runuser", "-u", user.name, "--", "/bin/sh", "-c", script, "sh", path], { stdin: content });
  if (r.exitCode !== 0) throw new Error(`writing ${path} as ${user.name} failed: ${r.stderr.trim()}`);
}

/**
 * `bun run src/conventions.ts --check`: exit 1 unless suite-cli's conventions
 * load and carry the reply rule. The image build runs it (Dockerfile), so a
 * suite-cli re-pin that moves or renames the export fails the build instead
 * of shipping agents that fall back to {@link FALLBACK}.
 */
if (import.meta.main && process.argv.includes("--check")) {
  const text = await loadSuiteConventions();
  if (text === null || !text.includes("suite_reply")) {
    console.error(`conventions: could not load SUITE_CONVENTIONS from ${BURROW_CLI_LIB}/src/claude_md.ts`);
    process.exit(1);
  }
  console.error(`conventions: ${text.length} characters from ${BURROW_CLI_LIB}`);
}
