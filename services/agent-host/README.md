# agent-host

Runs a Burrow install's native agents (core task 01a10322). TypeScript on bun.

- It dials **out** to core at `${BURROW_CORE_URL}/agent-host/websocket` and
  presents `AGENT_HOST_TOKEN` in the `x-agent-host-token` header. Core pushes
  commands down that channel. Core is never given a container-runtime socket
  or the host's D-Bus (the opt-in "Full root" below puts the socket in the host,
  never in core).
- Every agent is a systemd unit, `burrow-agent@<agent id>.service`, running as
  its own OS user `agent-<last 12 hex of the id>`. The user has a 0700 home, a
  0600 env file at `/etc/burrow-agents/<id>.env` and a 0700 tmux dir at
  `/run/burrow-agents/<id>`. The unit runs the real Claude Code through
  `burrow claude`. burrow-cli does the wiring, answers the launch dialogs, and
  classifies the pane (`burrow pane-status`). This daemon has no pane
  classifier of its own.
- **Per-agent users stop agents from crossing into each other BY ACCIDENT.
  They are not a security boundary.** An install is one trust group, and an
  agent with sudo can read every other agent's home, env file and tokens.
- This daemon never types into an agent's pane and never handles a Claude
  login code. It relays what suite-cli's status file reports: that a login is
  needed, and the step's name. Never a login URL or code: whatever else the
  status file holds stays on this host (core task 01a17b10). Burrow does not
  offer a Claude subscription login through its UI (it would need the
  person's code relayed into the CLI, which Anthropic's terms forbid). By
  default (`api_key` login mode) a native agent logs in with an Anthropic API
  key a manager saves in Burrow,
  which reaches ONLY that agent's 0600 env file as `ANTHROPIC_API_KEY`
  (stage 6). suite-cli answers Claude Code's "use this API key?" prompt for
  that key only. The other mode, `operator`, is below.
- `agent.pane` returns the agent's recent pane text for Burrow's read-only
  "Recent output" (`src/pane.ts`): captured as the agent, withheld whole
  while a login screen is up, scrubbed of credential-shaped strings.

Environment: `BURROW_CORE_URL`, `AGENT_HOST_TOKEN`, and `AGENT_HOST_PROFILE`
(`full_machine` or `contained`). The profile is reported to core as is, and
core does not branch on it.

## Capability profiles (stage 3)

The profile is install config, chosen once (`[agents] profile` in the install
manifest, deployment/schema/install-manifest.md) and realised by packaging.
Both profiles run the same daemon, the same `burrow-agent-host.service`, the
same `burrow-agent@.service` template (packaging/), the same sudoers grant and
the same tools at the versions in `versions.env`, installed by
`packaging/install-tools.sh`. Node comes from nodejs.org, not apt, because
Claude Code 2.x needs node 22 and neither Debian bookworm nor Ubuntu noble
ships it.

- **full_machine** (VMs we provision): the daemon is a root systemd service on
  the HOST, so an agent's `sudo apt-get install` and `sudo systemctl` act on the
  real machine. burrow_install renders it into cloud-init user-data; at first
  boot a setup unit copies `/opt/burrow/agent-host` out of this image and runs
  `install-tools.sh`. Agents reach core at the install's public URL through
  Caddy, like a federated agent.
- **contained** (shared hosts such as the root install on test-host): this directory's
  `Dockerfile`, a systemd-init image (systemd is PID 1; podman's systemd mode).
  Agents use the same `sudo systemctl`, `systemctl --user` and `crontab` as on
  full_machine. The container joins ONLY the agents network, created with
  `isolate=strict`; core-platform joins both. Measured on test-host
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
`ghcr.io/getburrowing/burrow-agent-host:latest` and `:<sha>`, and under its
pre-rename name `suite-agent-host` (GHCR and Docker Hub) for hosts installed
before the rename, only when a push to main changes `services/agent-host/**`,
because every push restarts every agent on an `AutoUpdate=registry` host.

## Operator login

An install opts in with `[agents] login = "operator"` in its manifest (the
default is `api_key`). The installer renders that into core's env as
`NATIVE_AGENT_LOGIN=operator`. In this mode core sends no API key in
`agent.start`, even when one is saved, and does not read the Vault for it.
The agent's pane stops at Claude Code's own login screen and waits for a
person.

A person with shell access to the machine attaches to the agent's pane and
logs in there. Exec into the agent-host container, become the agent's user
with its tmux dir, and attach to its session:

    docker exec -it <agent-host container> \
      runuser -u agent-<12 hex> -- \
      env TMUX_TMPDIR=/run/burrow-agents/<agent id> \
      tmux attach -t suite-agent

Use `podman exec` where the install runs podman. `<agent id>` is the agent's
full id and `<12 hex>` is its last 12 hex characters. On `full_machine` there
is no container, so run the `runuser` line on the host. Detach with `Ctrl-b d`
and leave the session running.

Claude Code shows its login URL in that pane. The person opens it, and then
types the code into Claude Code's own prompt in the attached pane. Burrow
never sees the code or the URL: the host passes core only the login step's
name, and "Recent output" stays withheld while a login screen is up
(`src/pane.ts`).

## Full root (opt-in)

Off by default (`[agents] full_root = false` in the install manifest). Core is never
given the container-runtime socket; when the install turns this on, the HOST holds it and
acts on core's `host.admin` command (restart, deploy or rollback of a compose service).

- `contained`: the render mounts exactly one socket (`/var/run/docker.sock`) into this
  container and sets `AGENT_HOST_FULL_ROOT=true`. Nothing is mounted otherwise.
- `full_machine`: no mount (the host is already root); the host env file gets
  `AGENT_HOST_FULL_ROOT=true`.
- The hello carries `full_root`. With it off, `host.admin` answers `requires_full_root`
  and the socket is never touched. `host.env_names` returns the NAMES in an agent's env
  file, never values.

The `admin_rpc` tool evaluates code in the running core release. That is a shell inside
core and is NOT gated by `full_root`; the key governs only the runtime socket.

## Hosts installed before the rename

At start, before it takes any command, the daemon adopts agents a
pre-rename host runs as `suite-agent@<id>` (`src/legacy.ts`): it writes the
`burrow-agent@<id>` drop-in, moves `/etc/suite-agents/<id>.env` to
`/etc/burrow-agents/` (mode and owner kept), runs one `systemctl
daemon-reload`, stops and disables `suite-agent@<id>`, and enables and starts
`burrow-agent@<id>`. A `suite-agents` group with no `burrow-agents` beside it
is renamed with `groupmod -n`, which keeps the gid. A second start finds
nothing to adopt and runs no command.

## Tests

These run on test-host, never on build-host:

    bash test/isolation/run.sh <path to this directory>
    bash test/contained/reachability.sh <agent-host image> [strict|true|none]

It builds a throwaway systemd-init image and runs `bunx tsc --noEmit`, the
unit tests and the isolation test (`AGENT_HOST_ISOLATION=1`) as root inside a
container. The isolation test proves that one agent's uid cannot read another
agent's home, credentials, env file or tmux socket, with the owner reading
each one as the positive control. It also checks that no token appears in any
spawned argv or any process command line. Everything is named with the task id
and removed on exit.
