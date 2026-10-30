/**
 * Adoption of pre-rename `suite-agent@<id>` units (src/legacy.ts), against a
 * fake file system and a recording runner, as unit.test.ts fakes its runner.
 * No root, no systemd.
 */
import { describe, expect, test } from "bun:test";
import type { Runner } from "../src/exec.ts";
import { appliedFile } from "../src/files.ts";
import { UNIT_DIR, UNIT_TEMPLATE, dropInDir, envFile, unitName } from "../src/ids.ts";
import { LEGACY_ENV_DIR, adoptLegacy, legacyDropInDir, legacyUnitName, type LegacyFs } from "../src/legacy.ts";
import { PACKAGED_RUNNER, dropIn, templateUnit } from "../src/units.ts";

const A = "01a14dd8-0000-7000-8000-00000000000a";
const B = "01a14dd8-0000-7000-8000-00000000000b";

interface Entry {
  content: string;
  mode: number;
  uid: number;
  gid: number;
}

class FakeFs implements LegacyFs {
  readonly files = new Map<string, Entry>();
  readonly dirs = new Set<string>();

  put(path: string, content: string, mode = 0o644, uid = 0, gid = 0): void {
    this.files.set(path, { content, mode, uid, gid });
    this.addParents(path);
  }
  private addParents(path: string): void {
    for (let d = path.slice(0, path.lastIndexOf("/")); d !== ""; d = d.slice(0, d.lastIndexOf("/"))) this.dirs.add(d);
  }
  readdir(path: string): string[] {
    const names = new Set<string>();
    for (const p of [...this.files.keys(), ...this.dirs]) {
      if (p.startsWith(`${path}/`)) names.add(p.slice(path.length + 1).split("/")[0]!);
    }
    return [...names];
  }
  exists(path: string): boolean {
    return this.files.has(path) || this.dirs.has(path);
  }
  readFile(path: string): string {
    const e = this.files.get(path);
    if (e === undefined) throw new Error(`ENOENT ${path}`);
    return e.content;
  }
  writeFile(path: string, content: string, mode: number): void {
    const old = this.files.get(path);
    this.put(path, content, mode, old?.uid ?? 0, old?.gid ?? 0);
  }
  stat(path: string): { mode: number; uid: number; gid: number } {
    const e = this.files.get(path);
    if (e === undefined) throw new Error(`ENOENT ${path}`);
    return { mode: e.mode, uid: e.uid, gid: e.gid };
  }
  mkdir(path: string, _mode: number): void {
    this.dirs.add(path);
    this.addParents(path);
  }
  // A real rename keeps the inode; this fake deliberately does NOT carry mode
  // or owner, so the test sees only what legacy.ts re-asserts.
  rename(from: string, to: string): void {
    const e = this.files.get(from);
    if (e === undefined) throw new Error(`ENOENT ${from}`);
    this.files.delete(from);
    this.put(to, e.content, 0o644, 0, 0);
  }
  chown(path: string, uid: number, gid: number): void {
    const e = this.files.get(path)!;
    e.uid = uid;
    e.gid = gid;
  }
  chmod(path: string, mode: number): void {
    this.files.get(path)!.mode = mode;
  }
  remove(path: string): void {
    for (const p of [...this.files.keys()]) if (p === path || p.startsWith(`${path}/`)) this.files.delete(p);
    for (const p of [...this.dirs]) if (p === path || p.startsWith(`${path}/`)) this.dirs.delete(p);
  }
}

/** Records every argv. `groupmod -n NEW OLD` is applied to the fake /etc/group, as the real one would be. */
function recorder(fs: FakeFs): Runner & { calls: string[][] } {
  const calls: string[][] = [];
  return {
    calls,
    async run(argv) {
      calls.push([...argv]);
      if (argv[0] === "groupmod" && argv[1] === "-n") {
        const text = fs.readFile("/etc/group").replace(new RegExp(`^${argv[3]}:`, "m"), `${argv[2]}:`);
        fs.put("/etc/group", text);
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  };
}

const LEGACY_CONF = "# legacy drop-in\n[Service]\nUser=agent-x\nGroup=suite-agents\n";

/** A pre-rename host with legacy agents `ids`, each with an env file owned by the agent. */
function legacyHost(ids: string[], groups = "root:x:0:\nsuite-agents:x:990:\n"): FakeFs {
  const fs = new FakeFs();
  fs.put("/etc/group", groups);
  fs.put(`${UNIT_DIR}/suite-agent@.service`, "# legacy template\n");
  ids.forEach((id, i) => {
    fs.put(`${legacyDropInDir(id)}/10-agent.conf`, LEGACY_CONF);
    fs.put(`${LEGACY_ENV_DIR}/${id}.env`, `LEGACY_AGENT_ID=${id}\n`, 0o600, 1001 + i, 990);
    fs.put(`${LEGACY_ENV_DIR}/${id}.files.json`, '{"CLAUDE.md":3}\n', 0o600, 0, 0);
  });
  return fs;
}

async function adopt(fs: FakeFs, runner = recorder(fs)) {
  const logs: string[] = [];
  const adopted = await adoptLegacy({ runner, fs, runnerCommand: PACKAGED_RUNNER, log: (l) => logs.push(l) });
  return { adopted, logs, calls: runner.calls, systemctl: runner.calls.filter((c) => c[0] === "systemctl") };
}

const idx = (calls: string[][], argv: string[]) => calls.findIndex((c) => c.join(" ") === argv.join(" "));

describe("legacy suite-agent@ adoption", () => {
  test("adopts two legacy agents with ONE daemon-reload, legacy stopped and disabled before burrow starts", async () => {
    const fs = legacyHost([A, B]);
    const { adopted, logs, calls, systemctl } = await adopt(fs);

    expect(adopted).toEqual([A, B]);
    expect(systemctl.filter((c) => c[1] === "daemon-reload")).toHaveLength(1);
    const reload = idx(calls, ["systemctl", "daemon-reload"]);
    for (const id of [A, B]) {
      const stop = idx(calls, ["systemctl", "stop", legacyUnitName(id)]);
      const disable = idx(calls, ["systemctl", "disable", legacyUnitName(id)]);
      const start = idx(calls, ["systemctl", "enable", "--now", unitName(id)]);
      expect([stop, disable, start].every((i) => i >= 0)).toBe(true);
      expect(reload).toBeLessThan(start);
      expect(stop).toBeLessThan(start);
      expect(disable).toBeLessThan(start);
      // The burrow drop-in, the burrow template, and no legacy drop-in left.
      expect(fs.readFile(`${dropInDir(id)}/10-agent.conf`)).toBe(dropIn(id));
      expect(fs.exists(legacyDropInDir(id))).toBe(false);
      expect(logs.filter((l) => l.includes(id))).toHaveLength(1);
    }
    expect(fs.readFile(`${UNIT_DIR}/${UNIT_TEMPLATE}`)).toBe(templateUnit(PACKAGED_RUNNER));
    // Exactly these systemctl calls: one reload, then three per agent.
    expect(systemctl).toHaveLength(1 + 3 * 2);
  });

  test("moves each env file into /etc/burrow-agents keeping its mode and owner, and the files record beside it", async () => {
    const fs = legacyHost([A, B]);
    await adopt(fs);
    for (const [i, id] of [A, B].entries()) {
      expect(fs.exists(`${LEGACY_ENV_DIR}/${id}.env`)).toBe(false);
      expect(fs.files.get(envFile(id))).toEqual({ content: `LEGACY_AGENT_ID=${id}\n`, mode: 0o600, uid: 1001 + i, gid: 990 });
      expect(fs.exists(`${LEGACY_ENV_DIR}/${id}.files.json`)).toBe(false);
      expect(fs.files.get(appliedFile(id))?.content).toBe('{"CLAUDE.md":3}\n');
    }
  });

  test("renames the suite-agents group (gid kept) before anything is owned by burrow-agents", async () => {
    const { calls } = await adopt(legacyHost([A]));
    const groupmod = idx(calls, ["groupmod", "-n", "burrow-agents", "suite-agents"]);
    expect(groupmod).toBe(0);
    expect(calls.filter((c) => c[0] === "groupmod")).toHaveLength(1);
  });

  test("leaves the group alone when burrow-agents already exists", async () => {
    const { calls } = await adopt(legacyHost([A], "suite-agents:x:990:\nburrow-agents:x:991:\n"));
    expect(calls.filter((c) => c[0] === "groupmod")).toHaveLength(0);
  });

  test("a second start finds nothing to adopt and runs no command at all", async () => {
    const fs = legacyHost([A, B]);
    const first = await adopt(fs);
    expect(first.systemctl.length).toBeGreaterThan(0);
    const second = await adopt(fs);
    expect(second.adopted).toEqual([]);
    expect(second.calls).toEqual([]);
  });

  test("a host with no legacy units runs no command", async () => {
    const fs = new FakeFs();
    fs.put("/etc/group", "root:x:0:\nburrow-agents:x:990:\n");
    fs.put(`${dropInDir(A)}/10-agent.conf`, dropIn(A));
    fs.put(envFile(A), "BURROW_AGENT_ID=x\n", 0o600, 1001, 990);
    const { adopted, calls } = await adopt(fs);
    expect(adopted).toEqual([]);
    expect(calls).toEqual([]);
    // Positive control: the same host with one legacy drop-in added does act.
    fs.put(`${legacyDropInDir(B)}/10-agent.conf`, LEGACY_CONF);
    expect((await adopt(fs)).calls.length).toBeGreaterThan(0);
  });

  test("a burrow drop-in that already exists is not overwritten", async () => {
    const fs = legacyHost([A]);
    const mine = "# hand-edited burrow drop-in\n";
    fs.put(`${dropInDir(A)}/10-agent.conf`, mine);
    const { adopted } = await adopt(fs);
    expect(adopted).toEqual([A]);
    expect(fs.readFile(`${dropInDir(A)}/10-agent.conf`)).toBe(mine);
  });
});
