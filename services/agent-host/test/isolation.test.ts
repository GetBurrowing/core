/**
 * Per-agent OS users, measured on a real systemd (task 01a10322 stage 2).
 *
 * Runs ONLY inside the throwaway systemd test container (see
 * test/isolation/Containerfile and run.sh), as root, with
 * AGENT_HOST_ISOLATION=1. Without that variable the whole file is skipped and
 * SAYS so; with it set but not root, it fails rather than skipping.
 *
 * What it shows, each with a positive control (the owner CAN), so a denial is
 * not merely a file that is not there:
 *   - each agent's home is 0700 and its own; agent B's uid cannot read agent
 *     A's credentials, env file or tmux socket;
 *   - the unit really runs as the agent's uid;
 *   - no runtime token appears in any argv this host spawned, nor in any
 *     process command line on the machine while the agents run;
 *   - a unit that keeps exiting without a stop is reported `crashed`, a stop
 *     reads `stopped`, and suite-cli's needs_login status reads `needs_login`.
 *
 * The isolation is against ACCIDENTAL crossing. It is not a security
 * boundary: an agent with sudo reads all of this.
 *
 * `suite` is a stub here (test/isolation/suite-stub.sh): it starts a tmux
 * session the way `suite claude` does and answers `pane-status` the way
 * suite-cli does. The real Claude Code is not run.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, readFileSync, readdirSync, statSync, writeFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { SecretRegistry, assertNoSecretsInArgv, liveRunner, recordingRunner } from "../src/exec.ts";
import { Host, type Transport } from "../src/host.ts";
import { observeAgent, type AgentsDeps, type Observation } from "../src/agents.ts";
import { ensureAgentUser } from "../src/users.ts";
import { appliedFile, writeAgentFiles } from "../src/files.ts";
import { connectionKey, envFile, homeDir, runDir, unitName, userName, workDir } from "../src/ids.ts";
import { renderUserMemory } from "../src/conventions.ts";

const ENABLED = process.env.AGENT_HOST_ISOLATION === "1";
const isRoot = typeof process.getuid === "function" && process.getuid() === 0;

if (!ENABLED) {
  console.error("isolation.test.ts: SKIPPED (set AGENT_HOST_ISOLATION=1 inside the systemd test container to run it)");
}

const d = ENABLED ? describe : describe.skip;

const A = "01a10322-0000-7000-8000-00000000000a";
const B = "01a10322-0000-7000-8000-00000000000b";
const TOK_A = "tokA-01a10322-ISOLATION-aaaaaaaaaaaaaaaaaaaaaaaa";
const TOK_B = "tokB-01a10322-ISOLATION-bbbbbbbbbbbbbbbbbbbbbbbb";

const CONVENTIONS = "## Always respond in channel\n\nEvery reply goes through `suite_reply`. ISOLATION-CONVENTIONS-01a10322\n";

const secrets = new SecretRegistry();
const seen: string[][] = [];
const runner = recordingRunner(liveRunner(secrets), seen);
const deps: AgentsDeps = {
  runner,
  secrets,
  runnerCommand: [process.execPath, "run", resolve(import.meta.dir, "..", "src", "runner.ts")],
  log: (l) => console.error(`agent-host(test): ${l}`),
  // suite-cli is a stub here; its conventions text is too.
  conventions: async () => CONVENTIONS,
};
const pushed: { event: string; payload: unknown }[] = [];
const transport: Transport = {
  push: async (event, payload) => {
    pushed.push({ event, payload });
    return "ok";
  },
};
const host = new Host(deps, transport, "contained");

const sh = (argv: string[]) => Bun.spawnSync(argv, { stdout: "pipe", stderr: "pipe" });
const asUser = (user: string, argv: string[]) => sh(["runuser", "-u", user, "--", ...argv]);
const text = (b: Uint8Array) => new TextDecoder().decode(b);

async function until(what: string, fn: () => Promise<boolean> | boolean, ms = 60_000): Promise<void> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await fn()) return;
    await Bun.sleep(500);
  }
  throw new Error(`timed out waiting for ${what}`);
}

const startPayload = (agentId: string, token: string) => ({
  agent_id: agentId,
  runtime_id: `iso-${agentId.slice(-1)}-native-01a10322`,
  runtime_token: token,
  harness: "claude_code",
  core_url: "http://core-platform:4000",
  env: { ANTHROPIC_BASE_URL: `http://example.invalid/${agentId.slice(-1)}` },
});

const tmuxSocket = (agentId: string, uid: number) => `${runDir(agentId)}/tmux-${uid}/default`;
const uidOf = (user: string) => Number.parseInt(text(sh(["id", "-u", user]).stdout).trim(), 10);

d("per-agent OS users on a real systemd", () => {
  test("runs as root in the systemd container", () => {
    expect(isRoot).toBe(true);
    expect(existsSync("/run/systemd/system")).toBe(true);
  });

  test("starting two agents gives two users, each running its own unit", async () => {
    await host.handleStart(startPayload(A, TOK_A));
    await host.handleStart(startPayload(B, TOK_B));
    for (const id of [A, B]) {
      await until(`${id} active`, () => text(sh(["systemctl", "is-active", unitName(id)]).stdout).trim() === "active");
      await until(`${id} tmux socket`, () => existsSync(tmuxSocket(id, uidOf(userName(id)))));
    }
    expect(userName(A)).not.toBe(userName(B));
    expect(uidOf(userName(A))).not.toBe(uidOf(userName(B)));
  }, 90_000);

  test("the unit's main process runs as the agent's uid", () => {
    for (const id of [A, B]) {
      const pid = text(sh(["systemctl", "show", unitName(id), "--property=MainPID", "--value"]).stdout).trim();
      const status = readFileSync(`/proc/${pid}/status`, "utf8");
      const uidLine = status.split("\n").find((l) => l.startsWith("Uid:"))!;
      expect(uidLine.split(/\s+/)[1]).toBe(String(uidOf(userName(id))));
    }
  });

  test("homes are 0700 and owned by their agent", () => {
    for (const id of [A, B]) {
      const st = statSync(homeDir(id));
      expect(st.mode & 0o777).toBe(0o700);
      expect(st.uid).toBe(uidOf(userName(id)));
    }
  });

  test("B cannot read A's credentials; A can (positive control)", () => {
    const creds = `${homeDir(A)}/.config/burrow/agents/${connectionKey(workDir(A))}.credentials.json`;
    const own = asUser(userName(A), ["cat", creds]);
    expect(own.exitCode).toBe(0);
    expect(text(own.stdout)).toContain(TOK_A);
    expect(statSync(creds).mode & 0o777).toBe(0o600);

    const other = asUser(userName(B), ["cat", creds]);
    expect(other.exitCode).not.toBe(0);
    expect(text(other.stderr)).toContain("Permission denied");
    const list = asUser(userName(B), ["ls", homeDir(A)]);
    expect(list.exitCode).not.toBe(0);
  });

  test("B cannot read A's env file; A can (positive control)", () => {
    const st = statSync(envFile(A));
    expect(st.mode & 0o777).toBe(0o600);
    expect(st.uid).toBe(uidOf(userName(A)));
    const own = asUser(userName(A), ["cat", envFile(A)]);
    expect(own.exitCode).toBe(0);
    expect(text(own.stdout)).toContain("ANTHROPIC_BASE_URL='http://example.invalid/a'");
    expect(text(own.stdout)).not.toContain("example.invalid/b");
    const other = asUser(userName(B), ["cat", envFile(A)]);
    expect(other.exitCode).not.toBe(0);
    expect(text(other.stderr)).toContain("Permission denied");
  });

  test("B cannot reach A's tmux server; A can (positive control)", () => {
    const sock = tmuxSocket(A, uidOf(userName(A)));
    expect(statSync(runDir(A)).mode & 0o777).toBe(0o700);
    const own = asUser(userName(A), ["tmux", "-S", sock, "list-sessions"]);
    expect(own.exitCode).toBe(0);
    expect(text(own.stdout)).toContain("suite-agent");
    const other = asUser(userName(B), ["tmux", "-S", sock, "list-sessions"]);
    expect(other.exitCode).not.toBe(0);
    expect(asUser(userName(B), ["ls", runDir(A)]).exitCode).not.toBe(0);
  });

  test("no token was in any argv the host spawned", () => {
    expect(seen.length).toBeGreaterThan(10);
    for (const argv of seen) {
      for (const arg of argv) {
        expect(arg.includes(TOK_A) || arg.includes(TOK_B)).toBe(false);
      }
    }
    // Positive control: the same check refuses an argv that carries one.
    expect(() => assertNoSecretsInArgv(["x", TOK_A], secrets)).toThrow();
  });

  test("no token is in any process command line on the machine", async () => {
    const scan = (needle: string): number[] => {
      const hits: number[] = [];
      for (const pid of readdirSync("/proc").filter((p) => /^\d+$/.test(p))) {
        try {
          if (readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(needle)) hits.push(Number(pid));
        } catch {
          // gone
        }
      }
      return hits;
    };
    // Positive control: a process with a planted marker in argv IS found.
    const marker = "marker-01a10322-cmdline-scan";
    const planted = Bun.spawn(["sh", "-c", "sleep 30", marker]);
    await Bun.sleep(200);
    expect(scan(marker).length).toBeGreaterThan(0);
    planted.kill();
    expect(scan(TOK_A)).toEqual([]);
    expect(scan(TOK_B)).toEqual([]);
  });

  test("suite-cli's needs_login status reads needs_login, with its step and never its login url", async () => {
    writeFileSync("/tmp/suite-stub-login", "1");
    try {
      await until("needs_login", async () => (await observeAgent(deps, A)).state === "needs_login", 30_000);
      const o = await observeAgent(deps, A);
      expect(o.login).toEqual({ step: "login_url" });
      expect(JSON.stringify(o)).not.toContain("oauth");
    } finally {
      rmSync("/tmp/suite-stub-login", { force: true });
    }
    await until("running again", async () => (await observeAgent(deps, A)).state === "running", 30_000);
  }, 70_000);

  test("a stop reads stopped", async () => {
    await host.handleStop({ agent_id: B });
    expect((await observeAgent(deps, B)).state).toBe("stopped");
    const last = pushed.filter((p) => p.event === "agent.state").at(-1)!.payload as Observation;
    expect(last).toMatchObject({ agent_id: B, state: "stopped" });
  });

  test("a unit that keeps exiting without a stop is reported crashed", async () => {
    // The stub's `suite claude` now creates no session, so the runner exits 1
    // on every start until systemd's start limit marks the unit failed.
    writeFileSync("/tmp/suite-stub-fail", "1");
    try {
      sh(["runuser", "-u", userName(A), "--", "env", `TMUX_TMPDIR=${runDir(A)}`, "tmux", "kill-server"]);
      await until("crashed", async () => (await observeAgent(deps, A)).state === "crashed", 80_000);
      await host.watch();
      const last = pushed.filter((p) => (p.payload as Observation).agent_id === A).at(-1)!.payload as Observation;
      expect(last.state).toBe("crashed");
    } finally {
      rmSync("/tmp/suite-stub-fail", { force: true });
    }
  }, 90_000);

  afterAll(async () => {
    for (const id of [A, B]) await host.handleStop({ agent_id: id });
  });
});

// Stage 3 (contained): the homes are a volume and /etc/passwd is the image's,
// so an image update drops every agent user and keeps every home. The next
// start must give the agent its own files back.
const C = "01a10322-0000-7000-8000-00000000000c";
const D = "01a10322-0000-7000-8000-00000000000d";
const SQUATTER = "squat-01a10322";

d("an agent whose user vanished but whose home survived (contained image update)", () => {
  const marker = () => `${homeDir(C)}/marker-01a10322`;

  test("re-created with the uid that owns its home", async () => {
    const first = await ensureAgentUser(runner, C);
    // D is newer than C, so after C's user is deleted useradd's next uid is
    // D's + 1, NOT C's old uid: without the reuse the uid would change.
    await ensureAgentUser(runner, D);
    expect(asUser(userName(C), ["sh", "-c", `echo mine > ${marker()}`]).exitCode).toBe(0);
    expect(sh(["userdel", userName(C)]).exitCode).toBe(0);
    expect(statSync(homeDir(C)).uid).toBe(first.uid);

    const again = await ensureAgentUser(runner, C);
    expect(again.uid).toBe(first.uid);
    expect(text(asUser(userName(C), ["cat", marker()]).stdout).trim()).toBe("mine");
  });

  test("when its old uid was taken meanwhile, the home is handed to the new uid", async () => {
    const old = uidOf(userName(C));
    expect(sh(["userdel", userName(C)]).exitCode).toBe(0);
    expect(sh(["useradd", "--no-create-home", "--uid", String(old), SQUATTER]).exitCode).toBe(0);

    const again = await ensureAgentUser(runner, C);
    expect(again.uid).not.toBe(old);
    expect(statSync(homeDir(C)).uid).toBe(again.uid);
    expect(statSync(marker()).uid).toBe(again.uid);
    // Positive control for the ownership check: the squatter is denied, C reads.
    expect(asUser(SQUATTER, ["cat", marker()]).exitCode).not.toBe(0);
    expect(text(asUser(userName(C), ["cat", marker()]).stdout).trim()).toBe("mine");
  });

  afterAll(() => {
    for (const u of [SQUATTER, userName(C), userName(D)]) sh(["userdel", "-r", u]);
  });
});

// Stage 5: the agent's own files, written into its work dir as its uid.
const E = "01a10322-0000-7000-8000-00000000000e";

d("agent files are written as the agent, inside its work dir only", () => {
  const work = () => workDir(E);

  test("POSITIVE CONTROL: a nested valid key writes the exact bytes, owned by the agent, 0644", async () => {
    const user = await ensureAgentUser(runner, E);
    // Bytes a shell or an encoding step would mangle: no trailing newline,
    // a NUL-free binary-ish mix, quotes, $(), backslashes, a multi-byte char.
    const content = `{"hooks": {}}\n$(touch /tmp/pwned-01a10322) \\ 'q' "d" \u00e9\t`;
    const res = await writeAgentFiles(runner, user, [
      { key: ".claude/settings.json", content, version: 7 },
      { key: "notes/deep/x.md", content: "deep", version: 1 },
    ]);
    expect(res.rejected).toEqual([]);
    expect(res.applied).toEqual({ ".claude/settings.json": 7, "notes/deep/x.md": 1 });
    const path = `${work()}/.claude/settings.json`;
    expect(Buffer.compare(readFileSync(path), Buffer.from(content, "utf8"))).toBe(0);
    expect(existsSync("/tmp/pwned-01a10322")).toBe(false);
    for (const p of [path, `${work()}/.claude`, `${work()}/notes/deep/x.md`, `${work()}/notes/deep`]) {
      expect(statSync(p).uid).toBe(user.uid);
    }
    expect(statSync(path).mode & 0o777).toBe(0o644);
    // No temp file is left beside it.
    expect(readdirSync(`${work()}/.claude`)).toEqual(["settings.json"]);
  });

  test("a second write replaces the file in place", async () => {
    const user = await ensureAgentUser(runner, E);
    await writeAgentFiles(runner, user, [{ key: ".claude/settings.json", content: "{}", version: 8 }]);
    expect(readFileSync(`${work()}/.claude/settings.json`, "utf8")).toBe("{}");
  });

  test("traversal keys are refused and nothing lands outside work/", async () => {
    const user = await ensureAgentUser(runner, E);
    const res = await writeAgentFiles(runner, user, [
      { key: "../escaped-01a10322", content: "x", version: 1 },
      { key: "a/../../escaped-01a10322", content: "x", version: 1 },
      { key: "/tmp/escaped-01a10322", content: "x", version: 1 },
    ]);
    expect(res.applied).toEqual({});
    expect(res.rejected).toHaveLength(3);
    expect(existsSync(`${homeDir(E)}/escaped-01a10322`)).toBe(false);
    expect(existsSync("/tmp/escaped-01a10322")).toBe(false);
  });

  test("a symlinked directory that leaves work/ is refused, not followed", async () => {
    const user = await ensureAgentUser(runner, E);
    // The agent itself plants `work/linked -> ~/outside` (a real dir it owns).
    expect(asUser(user.name, ["mkdir", "-p", `${homeDir(E)}/outside`]).exitCode).toBe(0);
    expect(asUser(user.name, ["ln", "-sfn", `${homeDir(E)}/outside`, `${work()}/linked`]).exitCode).toBe(0);
    const res = await writeAgentFiles(runner, user, [{ key: "linked/settings.json", content: "{}", version: 1 }]);
    expect(res.applied).toEqual({});
    expect(res.rejected[0]?.reason).toContain("escapes the work dir");
    expect(existsSync(`${homeDir(E)}/outside/settings.json`)).toBe(false);
  });

  test("a symlink at the file itself is refused, and its target is untouched", async () => {
    const user = await ensureAgentUser(runner, E);
    const target = `${homeDir(E)}/outside/target.md`;
    expect(asUser(user.name, ["sh", "-c", `printf original > ${target}`]).exitCode).toBe(0);
    expect(asUser(user.name, ["ln", "-sfn", target, `${work()}/CLAUDE.md`]).exitCode).toBe(0);
    const res = await writeAgentFiles(runner, user, [{ key: "CLAUDE.md", content: "replaced", version: 1 }]);
    expect(res.applied).toEqual({});
    expect(readFileSync(target, "utf8")).toBe("original");
    expect(lstatSync(`${work()}/CLAUDE.md`).isSymbolicLink()).toBe(true);
    rmSync(`${work()}/CLAUDE.md`);
  });

  test("a symlink to /etc is refused even though the agent could not write there anyway", async () => {
    const user = await ensureAgentUser(runner, E);
    expect(asUser(user.name, ["ln", "-sfn", "/etc", `${work()}/etc`]).exitCode).toBe(0);
    const res = await writeAgentFiles(runner, user, [{ key: "etc/suite-01a10322", content: "x", version: 1 }]);
    expect(res.applied).toEqual({});
    expect(existsSync("/etc/suite-01a10322")).toBe(false);
  });

  test("a start writes the files before the unit, and reports files_applied", async () => {
    const files = [
      { key: "CLAUDE.md", content: "# E\n", version: 3 },
      { key: ".claude/settings.json", content: "{}", version: 9 },
      { key: "../nope", content: "x", version: 1 },
    ];
    await host.handleStart({ ...startPayload(E, "tokE-01a10322-ISOLATION-eeeeeeeeeeeeeeeeeeeeeeee"), files });
    expect(readFileSync(`${work()}/CLAUDE.md`, "utf8")).toBe("# E\n");
    const applied = { "CLAUDE.md": 3, ".claude/settings.json": 9 };
    // Root-owned, 0600: the agent cannot forge what core is told it applied.
    expect(statSync(appliedFile(E)).uid).toBe(0);
    expect(statSync(appliedFile(E)).mode & 0o777).toBe(0o600);
    expect(JSON.parse(readFileSync(appliedFile(E), "utf8"))).toEqual(applied);
    expect((await observeAgent(deps, E)).files_applied).toEqual(applied);
    const last = pushed.filter((p) => (p.payload as Observation).agent_id === E).at(-1)!.payload as Observation;
    expect(last.files_applied).toEqual(applied);
  }, 60_000);

  // Stage 7 round 2, gate case 7008: an owner who replaces CLAUDE.md (here
  // "# E", with no `@SUITE_CONVENTIONS.md`) must not unload the conventions.
  test("an owner-replaced CLAUDE.md still leaves Burrow's conventions in the agent's user memory", async () => {
    const memory = `${homeDir(E)}/.claude/CLAUDE.md`;
    expect(readFileSync(`${work()}/CLAUDE.md`, "utf8")).toBe("# E\n");
    expect(readFileSync(memory, "utf8")).toBe(renderUserMemory(CONVENTIONS));
    expect(readFileSync(memory, "utf8")).toContain("suite_reply");
    expect(statSync(memory).uid).toBe(uidOf(userName(E)));
    // Written before the unit restarted, so the session that starts reads it.
    const write = seen.findLastIndex((a) => a[0] === "runuser" && a.includes(memory));
    const restart = seen.findLastIndex((a) => a[0] === "systemctl" && a[1] === "restart" && a[2] === unitName(E));
    expect(write).toBeGreaterThanOrEqual(0);
    expect(write).toBeLessThan(restart);

    // The agent (or anything) overwrites it; the next start puts it back.
    expect(asUser(userName(E), ["sh", "-c", `printf gone > ${memory}`]).exitCode).toBe(0);
    await host.handleStart({ ...startPayload(E, "tokE-01a10322-ISOLATION-eeeeeeeeeeeeeeeeeeeeeeee"), files: [{ key: "CLAUDE.md", content: "# E\n", version: 3 }] });
    expect(readFileSync(memory, "utf8")).toBe(renderUserMemory(CONVENTIONS));
  }, 60_000);

  afterAll(async () => {
    await host.handleStop({ agent_id: E });
    sh(["userdel", "-r", userName(E)]);
    rmSync(appliedFile(E), { force: true });
  });
});
