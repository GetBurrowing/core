# agent-host

Runs a Burrow install's native agents (core task 01a10322). TypeScript on bun.

- It dials **out** to core at `${BURROW_CORE_URL}/agent-host/websocket` and
  presents `AGENT_HOST_TOKEN` in the `x-agent-host-token` header. Core pushes
  commands down that channel. Core is never given a container-runtime socket
  or the host's D-Bus.
- Every agent is a systemd unit, `suite-agent@<agent id>.service`, running as
  its own OS user `agent-<last 12 hex of the id>`. The user has a 0700 home, a
  0600 env file at `/etc/suite-agents/<id>.env` and a 0700 tmux dir at
  `/run/suite-agents/<id>`. The unit runs the real Claude Code through
  `suite claude`. suite-cli does the wiring, answers the launch dialogs, and
  classifies the pane (`suite pane-status`). This daemon has no pane
  classifier of its own.
- **Per-agent users stop agents from crossing into each other BY ACCIDENT.
  They are not a security boundary.** An install is one trust group, and an
  agent with sudo can read every other agent's home, env file and tokens.
- This daemon never types into an agent's pane and never handles a Claude
  login code. It relays what suite-cli's status file reports: that a login is
  needed. Burrow does not offer a Claude subscription login (it would need the
  person's code relayed into the CLI, which Anthropic's terms forbid); a
  native agent logs in with an Anthropic API key a manager saves in Burrow,
  which reaches ONLY that agent's 0600 env file as `ANTHROPIC_API_KEY`
  (stage 6). suite-cli answers Claude Code's "use this API key?" prompt for
  that key only.
- `agent.pane` returns the agent's recent pane text for Burrow's read-only
  "Recent output" (`src/pane.ts`): captured as the agent, withheld whole
  while a login screen is up, scrubbed of credential-shaped strings.

Environment: `BURROW_CORE_URL` (the legacy `SUITE_CORE_URL` is still read, with a
deprecation line), `AGENT_HOST_TOKEN`, and `AGENT_HOST_PROFILE`
(`full_machine` or `contained`). The profile is reported to core as is, and
core does not branch on it.

## Capability profiles (stage 3)

The profile is install config, chosen once (`[agents] profile` in the install
manifest, deployment/schema/install-manifest.md) and realised by packaging.
Both profiles run the same daemon, the same `suite-agent-host.service`, the
same `suite-agent@.service` template (packaging/), the same sudoers grant and
the same tools at the versions in `versions.env`, installed by
`packaging/install-tools.sh`. Node comes from nodejs.org, not apt, because
Claude Code 2.x needs node 22 and neither Debian bookworm nor Ubuntu noble
ships it.

- **full_machine** (VMs we provision): the daemon is a root systemd service on
  the HOST, so an agent's `sudo apt-get install` and `sudo systemctl` act on the
  real machine. suite_install renders it into cloud-init user-data; at first
  boot a setup unit copies `/opt/suite/agent-host` out of this image and runs
  `install-tools.sh`. Agents reach core at the install's public URL through
  Caddy, like a federated agent.
- **contained** (shared hosts such as fabrikam on moon): this directory's
  `Dockerfile`, a systemd-init image (systemd is PID 1; podman's systemd mode).
  Agents use the same `sudo systemctl`, `systemctl --user` and `crontab` as on
  full_machine. The container joins ONLY the agents network, created with
  `isolate=strict`; core-platform joins both. Measured on moon
  (`test/contained/reachability.sh`): the agent host reaches core-platform:4000
  and the internet, and not Postgres, by name or by address. With
  `isolate=true` or no isolation it DOES reach Postgres by address, because
  `true` only separates networks that both set it. `/home` is a volume; an
  image update re-creates each agent's user with the uid that owns its home.
  Packages an agent installs live in the image layer and go with an update.

**Isolation limit (option A).** An install is one trust group. Per-agent users
stop accidental crossing, not malicious crossing. On full_machine an agent
with sudo is root over the WHOLE install: other agents' homes, env and tokens,
and core-platform's secrets.env and Postgres through docker. On contained an
agent is root over the agent container (every agent's home), and not over the
host or Postgres, because under rootless podman container root is not host
root.

The image is pushed by CI (`build-and-push-agent-host`) as
`docker.io/example/suite-agent-host:latest` and `:<sha>` only when a push to
main changes `services/agent-host/**`, because every push restarts every agent
on an `AutoUpdate=registry` host.

## Tests

These run on moon, never on hive:

    bash test/isolation/run.sh <path to this directory>
    bash test/contained/reachability.sh <agent-host image> [strict|true|none]

It builds a throwaway systemd-init image and runs `bunx tsc --noEmit`, the
unit tests and the isolation test (`AGENT_HOST_ISOLATION=1`) as root inside a
container. The isolation test proves that one agent's uid cannot read another
agent's home, credentials, env file or tmux socket, with the owner reading
each one as the positive control. It also checks that no token appears in any
spawned argv or any process command line. Everything is named with the task id
and removed on exit.
