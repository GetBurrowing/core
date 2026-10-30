/**
 * Burrow's agent host: runs this install's native agents and takes its orders
 * from core (task 01a10322 stage 2).
 *
 * It dials OUT to `${BURROW_CORE_URL}/agent-host/websocket` with
 * `AGENT_HOST_TOKEN`, reconnecting with backoff, and core pushes commands.
 * Core is never given a way into this machine: no container-runtime socket and
 * no D-Bus is shared with it. The one exception is the install's opt-in
 * `[agents] full_root`, where the HOST (not core) holds the runtime socket and
 * acts on core's restart/deploy/rollback commands.
 *
 * Runs as root (a systemd service on `full_machine`, container root under the
 * container's systemd on `contained`; packaging is stage 3), because it
 * creates users and units. Each agent runs as its own user.
 *
 * Environment:
 *   BURROW_CORE_URL      core's base URL, e.g. http://core-platform:4000
 *   AGENT_HOST_TOKEN     the install's shared agent-host secret
 *   AGENT_HOST_PROFILE   "full_machine" | "contained", reported to core as is
 *   AGENT_HOST_FULL_ROOT "true" only when the install set [agents] full_root; reported in the
 *                        hello. The runtime socket (AGENT_HOST_RUNTIME_SOCKET) is mounted only then.
 */
import { resolve } from "node:path";
import { SecretRegistry, liveRunner } from "./exec.ts";
import { Host, WATCH_MS } from "./host.ts";
import { liveDockerFetch, socketPath } from "./docker.ts";
import { adoptLegacy, liveLegacyFs } from "./legacy.ts";
import { PhoenixChannel, agentHostUrl, bunSocket } from "./phoenix.ts";

const PROFILES = new Set(["full_machine", "contained"]);

function required(name: string): string {
  const v = process.env[name];
  if (v === undefined || v.trim() === "") {
    console.error(`agent-host: ${name} is not set`);
    process.exit(2);
  }
  return v.trim();
}

if (import.meta.main) {
  const coreUrl = required("BURROW_CORE_URL");
  const token = required("AGENT_HOST_TOKEN");
  const profile = process.env.AGENT_HOST_PROFILE?.trim() ?? "";
  if (!PROFILES.has(profile)) {
    console.error(`agent-host: AGENT_HOST_PROFILE must be full_machine or contained`);
    process.exit(2);
  }
  const log = (line: string): void => console.error(`agent-host: ${line}`);
  const secrets = new SecretRegistry();
  secrets.add(token);

  // The unit execs bun on the runner, as the agent. Both paths must be
  // readable by every agent user (they are, under /opt/burrow or /usr/local).
  const runnerCommand = [process.execPath, "run", resolve(import.meta.dir, "runner.ts")];
  if (runnerCommand.some((p) => /\s/.test(p))) {
    console.error("agent-host: install path contains whitespace; systemd ExecStart cannot carry it");
    process.exit(2);
  }

  const deps = { runner: liveRunner(secrets), secrets, runnerCommand, log };

  // Agents a pre-rename host runs as suite-agent@<id> move to burrow-agent@<id>
  // before any command arrives (legacy.ts). A failure is logged, not fatal.
  await adoptLegacy({ runner: deps.runner, fs: liveLegacyFs, runnerCommand, log }).catch((e: unknown) =>
    log(`legacy adoption failed: ${String(e)}`),
  );

  const channel: PhoenixChannel = new PhoenixChannel({
    url: agentHostUrl(coreUrl),
    headers: { "x-agent-host-token": token },
    topic: "agent_host:control",
    joinPayload: () => host.hello(),
    socket: bunSocket,
    log,
    onJoined: () => void host.inventory().catch((e: unknown) => log(`inventory failed: ${String(e)}`)),
  });
  const fullRoot = process.env.AGENT_HOST_FULL_ROOT?.trim() === "true";
  const host = new Host(deps, channel, profile, undefined, fullRoot, fullRoot ? liveDockerFetch(socketPath()) : null);

  channel.on("agent.start", (p) => void host.handleStart(p));
  channel.on("agent.restart", (p) => void host.handleRestart(p));
  channel.on("agent.stop", (p) => void host.handleStop(p));
  channel.on("agent.logs", (p) => void host.handleLogs(p).catch((e: unknown) => log(`logs failed: ${String(e)}`)));
  channel.on("agent.pane", (p) => void host.handlePane(p).catch((e: unknown) => log(`pane failed: ${String(e)}`)));
  channel.on("agent.file_read", (p) => void host.handleFileRead(p).catch((e: unknown) => log(`file read failed: ${String(e)}`)));
  channel.on("agent.check_auth", (p) => void host.handleCheckAuth(p));
  channel.on("host.env_names", (p) => void host.handleEnvNames(p).catch((e: unknown) => log(`env_names failed: ${String(e)}`)));
  channel.on("host.admin", (p) => void host.handleAdmin(p).catch((e: unknown) => log(`admin failed: ${String(e)}`)));

  log(`dialling ${agentHostUrl(coreUrl)} as profile ${profile}`);
  channel.connect();

  setInterval(() => {
    if (channel.isJoined()) void host.watch().catch((e: unknown) => log(`watch failed: ${String(e)}`));
  }, WATCH_MS);
}
