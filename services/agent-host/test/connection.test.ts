/**
 * The connection a start writes (agents.ts writeConnection), for real on disk:
 * burrow-cli 0.9.0+ reads `~/.config/burrow/agents/` only, and keeps an MCP
 * entry whose token it cannot see is stale. Two starts with a rotated token
 * must leave the new token in both places, and nothing else changed.
 *
 * runuser is root-only: the runner strips it and runs the rest as this user.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import type { Runner } from "../src/exec.ts";
import { CHANNEL_SERVER, TOOLS_SERVER, burrowAgentsDir, refreshedClaudeJson, renderAgentRecord, writeConnection } from "../src/agents.ts";
import { connectionKey } from "../src/ids.ts";
import type { AgentUser } from "../src/users.ts";

const TOKEN_1 = `tok-one-${"a".repeat(24)}`;
const TOKEN_2 = `tok-two-${"b".repeat(24)}`;
const URL = "https://burrow.example.test";

const runner: Runner = {
  async run(argv, options = {}) {
    const real = argv[0] === "runuser" ? argv.slice(argv.indexOf("--") + 1) : argv;
    const proc = Bun.spawn(real, {
      stdin: options.stdin === undefined ? "ignore" : new Blob([options.stdin]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    return { exitCode, stdout, stderr };
  },
};

let home: string;
let user: AgentUser;
const logs: string[] = [];
const deps = { runner, log: (l: string) => logs.push(l) };
const cmd = (token: string) => ({ agent_id: "a1", runtime_id: "burrow-native-test", runtime_token: token, core_url: URL });

function claudeJson(work: string, token: string): Record<string, unknown> {
  return {
    numStartups: 7,
    mcpServers: { userwide: { command: "x", env: { BURROW_TOKEN: "user-scope-untouched" } } },
    projects: {
      [work]: {
        allowedTools: ["Bash"],
        mcpServers: {
          [CHANNEL_SERVER]: {
            type: "stdio",
            command: "bun",
            args: ["/usr/local/share/burrow/plugins/burrow-channel-claude-code/index.ts"],
            env: { BURROW_URL: "wss://burrow.example.test/runtime/ws", BURROW_RUNTIME_ID: "burrow-native-test", BURROW_TOKEN: token, BURROW_ALLOW_PERMISSION_RELAY: "0" },
          },
          [TOOLS_SERVER]: { type: "http", url: "https://burrow.example.test/mcp", headers: { Authorization: `Bearer ${token}`, "X-Other": "kept" } },
          other: { type: "stdio", command: "other", env: { BURROW_TOKEN: "not-ours" } },
          otherhttp: { type: "http", url: "https://elsewhere.test", headers: { Authorization: "Bearer not-ours" } },
        },
      },
      "/somewhere/else": {
        mcpServers: { [CHANNEL_SERVER]: { command: "bun", env: { BURROW_TOKEN: "other-project" } } },
      },
    },
  };
}

beforeEach(() => {
  home = mkdtempSync(resolve(tmpdir(), "agent-conn-"));
  const work = resolve(home, "work");
  mkdirSync(work);
  user = { name: "agent-test", uid: process.getuid?.() ?? 0, gid: process.getgid?.() ?? 0, home, work, runDir: resolve(home, "run") };
  logs.length = 0;
});
afterEach(() => rmSync(home, { recursive: true, force: true }));

const credsPath = () => `${burrowAgentsDir(user)}/${connectionKey(user.work)}.credentials.json`;
const recordPath = () => `${burrowAgentsDir(user)}/${connectionKey(user.work)}.json`;
const readJson = (p: string) => JSON.parse(readFileSync(p, "utf8"));

describe("writeConnection: two starts with a rotated token", () => {
  test("burrow-dir creds and the MCP entries hold the NEW token; nothing else in .claude.json moves; no suite dir", async () => {
    writeFileSync(resolve(home, ".claude.json"), JSON.stringify(claudeJson(user.work, TOKEN_1), null, 2), { mode: 0o600 });

    await writeConnection(deps, user, cmd(TOKEN_1));
    expect(readJson(credsPath())).toEqual({ token: TOKEN_1, headers: {} });
    await writeConnection(deps, user, cmd(TOKEN_2));

    // The credentials burrow-cli reads.
    expect(readJson(credsPath())).toEqual({ token: TOKEN_2, headers: {} });
    expect(statSync(credsPath()).mode & 0o777).toBe(0o600);
    const record = readJson(recordPath());
    expect(record).toEqual({ dir: user.work, burrowUrl: URL, runtimeId: "burrow-native-test", headerNames: [] });
    expect(statSync(recordPath()).mode & 0o777).toBe(0o600);

    // The legacy dir is never written.
    expect(existsSync(resolve(home, ".config/suite"))).toBe(false);

    // The MCP entries carry the new token...
    const after = readJson(resolve(home, ".claude.json"));
    const servers = after.projects[user.work].mcpServers;
    expect(servers[CHANNEL_SERVER].env.BURROW_TOKEN).toBe(TOKEN_2);
    expect(servers[TOOLS_SERVER].headers.Authorization).toBe(`Bearer ${TOKEN_2}`);
    expect(statSync(resolve(home, ".claude.json")).mode & 0o777).toBe(0o600);

    // ...and everything else is exactly as it was.
    const expected = claudeJson(user.work, TOKEN_2);
    expect(after).toEqual(expected);
    expect(JSON.stringify(after)).not.toContain(TOKEN_1);
    // No temp files left behind.
    expect(existsSync(`${credsPath()}.tmp`)).toBe(false);
  });

  test("no .claude.json: nothing is created (burrow-cli registers the entries)", async () => {
    await writeConnection(deps, user, cmd(TOKEN_2));
    expect(existsSync(resolve(home, ".claude.json"))).toBe(false);
    expect(readJson(credsPath()).token).toBe(TOKEN_2);
  });

  test("a record burrow-cli wrote keeps its own fields and loses suiteUrl and token refs", async () => {
    mkdirSync(burrowAgentsDir(user), { recursive: true });
    writeFileSync(
      recordPath(),
      JSON.stringify({ dir: user.work, suiteUrl: "https://old.test", runtimeId: "old", headerNames: [], tokenRef: "file:/x", configAccess: "admins", remoteTerminal: "s1" }),
    );
    await writeConnection(deps, user, cmd(TOKEN_2));
    expect(readJson(recordPath())).toEqual({
      dir: user.work,
      burrowUrl: URL,
      runtimeId: "burrow-native-test",
      headerNames: [],
      configAccess: "admins",
      remoteTerminal: "s1",
    });
  });
});

describe("refreshedClaudeJson", () => {
  test("unchanged token, not JSON, or no projects: null (no write)", () => {
    const text = JSON.stringify(claudeJson("/w", TOKEN_2));
    expect(refreshedClaudeJson(text, "/w", TOKEN_2)).toBeNull();
    expect(refreshedClaudeJson("{not json", "/w", TOKEN_2)).toBeNull();
    expect(refreshedClaudeJson("{}", "/w", TOKEN_2)).toBeNull();
  });

  test("an env reference is left alone; a pre-0.11 SUITE_TOKEN copy is refreshed too", () => {
    const j = claudeJson("/w", TOKEN_1) as { projects: Record<string, { mcpServers: Record<string, { env?: Record<string, string>; headers?: Record<string, string> }> }> };
    j.projects["/w"]!.mcpServers[CHANNEL_SERVER]!.env!.SUITE_TOKEN = TOKEN_1;
    j.projects["/w"]!.mcpServers[TOOLS_SERVER]!.headers!.Authorization = "Bearer ${BURROW_TOKEN}";
    const out = JSON.parse(refreshedClaudeJson(JSON.stringify(j), "/w", TOKEN_2)!);
    expect(out.projects["/w"].mcpServers[CHANNEL_SERVER].env.SUITE_TOKEN).toBe(TOKEN_2);
    expect(out.projects["/w"].mcpServers[TOOLS_SERVER].headers.Authorization).toBe("Bearer ${BURROW_TOKEN}");
  });

  test("renderAgentRecord ignores a record for another folder", () => {
    const r = JSON.parse(renderAgentRecord(JSON.stringify({ dir: "/other", configAccess: "admins" }), "/w", URL, "r"));
    expect(r).toEqual({ dir: "/w", burrowUrl: URL, runtimeId: "r", headerNames: [] });
  });
});
