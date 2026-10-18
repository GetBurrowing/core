/**
 * One OS user per agent.
 *
 * On an agent's first start: user `agent-<short id>` (see ids.ts) in group
 * `suite-agents`, with a 0700 home and a `work` folder; linger enabled, so the
 * agent's own `systemctl --user` services and crontab survive restarts; and a
 * 0700 runtime dir at /run/suite-agents/<agent id> for its tmux server.
 *
 * WHAT THIS IS NOT. Separate users stop one agent from reading or clobbering
 * another's files BY ACCIDENT. They are not a security boundary: an install is
 * one trust group, and an agent with sudo (which the install provisions) can
 * read every other agent's home, env file and tokens.
 *
 * Idempotent: every start calls {@link ensureAgentUser}, and an existing user
 * is reused, its modes re-asserted.
 */
import { AGENTS_GROUP, RUN_DIR, homeDir, runDir, userName, workDir } from "./ids.ts";
import type { Runner } from "./exec.ts";

export interface AgentUser {
  name: string;
  uid: number;
  gid: number;
  home: string;
  work: string;
  runDir: string;
}

async function must(runner: Runner, argv: string[], what: string): Promise<string> {
  const r = await runner.run(argv);
  if (r.exitCode !== 0) throw new Error(`${what} failed (exit ${r.exitCode}): ${r.stderr.trim()}`);
  return r.stdout;
}

async function idOf(runner: Runner, flag: "-u" | "-g", name: string): Promise<number> {
  return Number.parseInt((await must(runner, ["id", flag, name], `id ${flag} ${name}`)).trim(), 10);
}

/** The uid owning `home` when it is a real directory (not a symlink), else null. */
async function homeOwner(runner: Runner, home: string): Promise<number | null> {
  const r = await runner.run(["stat", "--format", "%F %u", home]);
  if (r.exitCode !== 0) return null;
  // `stat` without -L describes a symlink as "symbolic link", never its target.
  const m = /^(.+) (\d+)$/.exec(r.stdout.trim());
  if (m === null || m[1] !== "directory") return null;
  const n = Number.parseInt(m[2] ?? "", 10);
  return Number.isInteger(n) && n > 0 ? n : null;
}

export async function ensureGroup(runner: Runner): Promise<void> {
  const r = await runner.run(["getent", "group", AGENTS_GROUP]);
  if (r.exitCode !== 0) await must(runner, ["groupadd", "--system", AGENTS_GROUP], "groupadd");
}

export async function ensureAgentUser(runner: Runner, agentId: string): Promise<AgentUser> {
  const name = userName(agentId);
  const home = homeDir(agentId);
  const work = workDir(agentId);
  const run = runDir(agentId);

  await ensureGroup(runner);
  const exists = (await runner.run(["getent", "passwd", name])).exitCode === 0;
  if (!exists) {
    // A home with no user: on `contained` the homes are a volume and
    // /etc/passwd is the image's, so every image update drops the users and
    // keeps their homes. Re-create the user with the uid that owns its home,
    // when that uid is free, so its files stay its own (stage 3).
    const owner = await homeOwner(runner, home);
    const reuse = owner !== null && (await runner.run(["getent", "passwd", String(owner)])).exitCode !== 0;
    const homeArgs = reuse ? ["--uid", String(owner), "--no-create-home"] : ["--create-home"];
    await must(
      runner,
      ["useradd", ...homeArgs, "--home-dir", home, "--shell", "/bin/bash", "--gid", AGENTS_GROUP, "--comment", `Burrow agent ${agentId}`, name],
      "useradd",
    );
  }
  const uid = await idOf(runner, "-u", name);
  const gid = await idOf(runner, "-g", name);

  // A home some other uid owns (its old uid was taken): hand the tree back.
  // `chown -R` does not follow symlinks inside the tree.
  const owner = await homeOwner(runner, home);
  if (owner !== null && owner !== uid) {
    await must(runner, ["chown", "-R", `${name}:${AGENTS_GROUP}`, home], "chown home");
  }

  // Re-asserted every time: a mode someone loosened by hand comes back.
  await must(runner, ["chmod", "0700", home], "chmod home");
  await must(runner, ["install", "-d", "-m", "0700", "-o", name, "-g", AGENTS_GROUP, work], "install work dir");

  // /run is a tmpfs: the per-agent dir is recreated on every start.
  await must(runner, ["install", "-d", "-m", "0711", "-o", "root", "-g", "root", RUN_DIR], "install run root");
  await must(runner, ["install", "-d", "-m", "0700", "-o", name, "-g", AGENTS_GROUP, run], "install run dir");

  // Linger: the agent's own user services and timers outlive its sessions.
  // Best effort where logind is absent (a container without systemd): the
  // agent still runs, only its user services would not survive.
  const linger = await runner.run(["loginctl", "enable-linger", name]);
  if (linger.exitCode !== 0) {
    console.error(`agent-host: loginctl enable-linger ${name} failed: ${linger.stderr.trim()}`);
  }

  return { name, uid, gid, home, work, runDir: run };
}
