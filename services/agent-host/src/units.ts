/**
 * The systemd units: one template, `burrow-agent@.service`, and one drop-in per
 * agent naming its user.
 *
 * Why systemd: the same unit works on `full_machine` (the host's systemd) and
 * on `contained` (a systemd-init container image, stage 3), and it gives
 * journald logs, cgroup limits and restart-on-failure for free, so this daemon
 * does not re-implement supervision.
 *
 * Why a drop-in: `User=` cannot come from an EnvironmentFile and no systemd
 * specifier maps an agent id to `agent-<short id>`, so each instance gets
 * `burrow-agent@<id>.service.d/10-agent.conf` with its User, Group, home and
 * runtime dir.
 */
import { ENV_DIR, SESSION, homeDir, runDir, userName, workDir, AGENTS_GROUP } from "./ids.ts";

/** Where both capability profiles install this daemon (stage 3 packaging). */
export const PACKAGED_RUNNER = ["/usr/local/bin/bun", "run", "/opt/burrow/agent-host/src/runner.ts"];

/**
 * The template. `%i` is the agent id. `runner` is the absolute command the
 * unit execs as the agent (see runner.ts).
 *
 * `Restart=on-failure`: the runner exits 1 when the agent's tmux session
 * disappears without a stop, which systemd then restarts; a stop is SIGTERM,
 * which the runner turns into a clean exit 0.
 *
 * packaging/burrow-agent@.service is this function's output for
 * {@link PACKAGED_RUNNER}, shipped in the image and in full_machine's
 * user-data; test/unit.test.ts fails if the two differ by a byte.
 */
export function templateUnit(runner: string[]): string {
  return [
    "# Managed by Burrow's agent host. One instance per native agent; %i is the agent id.",
    "# The per-agent drop-in in burrow-agent@<id>.service.d/ sets User, Group and paths.",
    "[Unit]",
    "Description=Burrow native agent %i",
    "After=network-online.target",
    "Wants=network-online.target",
    "StartLimitIntervalSec=300",
    "StartLimitBurst=5",
    "",
    "[Service]",
    "Type=simple",
    `EnvironmentFile=${ENV_DIR}/%i.env`,
    "Environment=BURROW_AGENT_ID=%i",
    "Environment=SUITE_AGENT_ID=%i",
    `Environment=BURROW_AGENT_SESSION=${SESSION}`,
    `Environment=SUITE_AGENT_SESSION=${SESSION}`,
    // Nobody can type into a native agent's pane: suite-cli marks Claude
    // Code's first-run onboarding done before launch (hasCompletedOnboarding,
    // read from the 2.1.295 binary), so theme / security notes never appear.
    "Environment=BURROW_UNATTENDED=1",
    "Environment=SUITE_UNATTENDED=1",
    // The CLIs are pinned by the install (versions.env) and live in /usr/local,
    // which no agent may write: an auto-update could only fail, noisily.
    "Environment=DISABLE_AUTOUPDATER=1",
    // Node reads only its bundled roots without this; the system bundle carries
    // the install's internal root CA on a full_machine install with tls internal.
    "Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
    `ExecStart=${runner.join(" ")}`,
    "Restart=on-failure",
    "RestartSec=5",
    "KillMode=control-group",
    "TimeoutStopSec=30",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}

export function dropIn(agentId: string): string {
  const home = homeDir(agentId);
  return [
    "# Managed by Burrow's agent host.",
    "[Service]",
    `User=${userName(agentId)}`,
    `Group=${AGENTS_GROUP}`,
    `WorkingDirectory=${workDir(agentId)}`,
    `Environment=HOME=${home}`,
    `Environment=USER=${userName(agentId)}`,
    // suite-cli calls plain `tmux`; TMUX_TMPDIR is the one knob that moves the
    // server socket for every such call, into this agent's 0700 runtime dir.
    `Environment=TMUX_TMPDIR=${runDir(agentId)}`,
    `Environment=PATH=${home}/.local/bin:/usr/local/bin:/usr/bin:/bin`,
    "",
  ].join("\n");
}
