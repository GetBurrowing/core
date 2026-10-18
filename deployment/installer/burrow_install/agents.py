"""Native agents' packaging for the ``single-host`` target (core task 01a10322 stage 3).

The capability profile is install config (``[agents] profile``), realised here
and in the registry. Core never branches on it; the agent host reports it.

``full_machine``: the agent host is a ROOT systemd service on the HOST, not a
container, so an agent's ``sudo apt-get install`` and ``sudo systemctl`` act on
the real machine. This module renders, into cloud-init user-data:

- ``/etc/sudoers.d/burrow-agents``: passwordless sudo for group burrow-agents;
- ``burrow-agent-host.service`` and the agent host's ``burrow-agent@.service`` template;
- ``burrow-agent-host-setup.service`` + ``bin/burrow-agent-host-setup``, which at
  first boot copy the daemon out of the agent-host image (the same artefact
  ``contained`` runs) and install the tools pinned in ``versions.env``;
- ``/etc/burrow-agent-host.env`` (0600 root): AGENT_HOST_TOKEN, the profile and
  the install's public URL. Agents reach core there, through Caddy, exactly as a
  federated agent does; an internal root CA is put in the system trust store.

ISOLATION LIMIT (option A). An install is one trust group. Per-agent users
stop accidental crossing, not malicious crossing. On full_machine an agent
with sudo is root over the WHOLE install: other agents' homes, env and tokens,
and core-platform's secrets.env and Postgres through docker.

``contained`` is a registry service (``registry.AGENT_HOST``); the only thing
it needs from this module is :func:`systemd_init_compose`.

The packaged texts below are byte-for-byte copies of files under
services/agent-host/ (the image ships the originals);
tests/test_agents_render.py fails on any drift.
"""

INSTALL_ROOT = "/opt/burrow"

# services/agent-host/versions.env, verbatim.
VERSIONS_ENV = """\
# Tool versions the agent host installs, in BOTH capability profiles
# (core task 01a10322 stage 3). One value per line, NAME=value, no quotes.
#
#   contained     Dockerfile runs packaging/install-tools.sh against this file.
#   full_machine  burrow_install renders this file verbatim into cloud-init
#                 user-data (/etc/burrow-agent-host/versions.env), and the host's
#                 setup unit runs the same install-tools.sh against it.
#
# deployment/installer/tests/test_agents_render.py fails if the installer's
# copy (burrow_install/agents.py VERSIONS_ENV) differs from this file by a byte.
#
# Claude Code 2.x needs node >= 22 (npm view @anthropic-ai/claude-code engines),
# which neither Debian bookworm nor Ubuntu noble ship, so node is pinned here
# and installed from nodejs.org, not apt.
NODE_VERSION=22.23.3
BUN_VERSION=1.4.2
CLAUDE_CODE_VERSION=2.1.295
CODEX_VERSION=0.162.0
# suite-cli has no release tags; this is PR #33 at 0.8.0 (Startup-Suite/suite-cli 3f80728): re-pin to its merge commit.
BURROW_CLI_REF=3f8072830bea22f45584d00a5b6611bee05a05f8
SUITE_CLI_REF=3f8072830bea22f45584d00a5b6611bee05a05f8
"""

# services/agent-host/packaging/sudoers-burrow-agents, verbatim.
SUDOERS = """\
# Installed by Burrow's agent host packaging (core task 01a10322 stage 3).
# Native agents do anything that needs root themselves, with this grant.
# An install is ONE trust group: an agent with this grant can read every other
# agent's home, env file and tokens. Per-agent users are not a security boundary.
%burrow-agents ALL=(ALL) NOPASSWD:ALL
"""

# services/agent-host/packaging/burrow-agent-host.service, verbatim.
HOST_UNIT = """\
# Burrow's agent host (core task 01a10322). The same unit in both capability
# profiles: on full_machine it is a host service, on contained it runs under
# the agent-host container's systemd.
#
# Configuration comes from /etc/burrow-agent-host.env (full_machine: written by
# burrow_install, 0600 root) or, on contained, from the container's environment,
# which PassEnvironment hands through from systemd. The image sets
# AGENT_HOST_PROFILE=contained; Environment/EnvironmentFile win over it.
[Unit]
Description=Burrow agent host
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
PassEnvironment=BURROW_CORE_URL SUITE_CORE_URL AGENT_HOST_TOKEN AGENT_HOST_PROFILE
EnvironmentFile=-/etc/burrow-agent-host.env
# Node and bun read only their bundled roots without this; the system bundle
# carries an install's internal root CA once update-ca-certificates has run.
Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
ExecStart=/usr/local/bin/bun run /opt/burrow/agent-host/src/main.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""

# services/agent-host/packaging/burrow-agent@.service, verbatim. The agent host
# writes the same text on every start (src/units.ts templateUnit), so shipping
# it here only means the unit exists before the first agent does.
AGENT_TEMPLATE_UNIT = """\
# Managed by Burrow's agent host. One instance per native agent; %i is the agent id.
# The per-agent drop-in in burrow-agent@<id>.service.d/ sets User, Group and paths.
[Unit]
Description=Burrow native agent %i
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
EnvironmentFile=/etc/burrow-agents/%i.env
Environment=BURROW_AGENT_ID=%i
Environment=SUITE_AGENT_ID=%i
Environment=BURROW_AGENT_SESSION=suite-agent
Environment=SUITE_AGENT_SESSION=suite-agent
Environment=BURROW_UNATTENDED=1
Environment=SUITE_UNATTENDED=1
Environment=DISABLE_AUTOUPDATER=1
Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
ExecStart=/usr/local/bin/bun run /opt/burrow/agent-host/src/runner.ts
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""

HOST_UNIT_NAME = "burrow-agent-host.service"
SETUP_UNIT_NAME = "burrow-agent-host-setup.service"
FULL_MACHINE_UNITS = (SETUP_UNIT_NAME, HOST_UNIT_NAME)
AGENT_TEMPLATE_UNIT_NAME = "burrow-agent@.service"
SETUP_SCRIPT = "burrow-agent-host-setup"
# The OS group of native agents (services/agent-host/src/ids.ts AGENTS_GROUP).
AGENTS_GROUP = "burrow-agents"
# templates.py's stack unit; named here too because templates imports this module.
STACK_UNIT_NAME = "burrow-stack.service"

VERSIONS_PATH = "/etc/burrow-agent-host/versions.env"
HOST_ENV_PATH = "/etc/burrow-agent-host.env"
SUDOERS_PATH = "/etc/sudoers.d/burrow-agents"
SUDOERS_MODE = 0o440
SECRET_MODE = 0o600
FILE_MODE = 0o644
EXEC_MODE = 0o755

# apt packages a full_machine host needs on top of docker. node is NOT here:
# Claude Code 2.x needs node >= 22 and Ubuntu noble ships 18, so
# install-tools.sh installs the pinned node from nodejs.org. Chromium is a
# snap on noble (its apt package is a transitional wrapper), installed by the
# setup script.
FULL_MACHINE_PACKAGES = ["tmux", "git", "curl", "ca-certificates", "xz-utils", "unzip", "cron"]


def _header(plan):
    from .templates import HEADER

    return HEADER.format(name=plan.name)


def host_env(plan, token):
    """/etc/burrow-agent-host.env: read by burrow-agent-host.service only."""
    return (
        f"# {_header(plan)}\n"
        f"# SECRET. Mode 0600, root. Read by {HOST_UNIT_NAME} only.\n"
        "AGENT_HOST_PROFILE=full_machine\n"
        f"AGENT_HOST_TOKEN={token}\n"
        f"BURROW_CORE_URL=https://{plan.primary}\n"
        f"SUITE_CORE_URL=https://{plan.primary}\n"
    )


def host_unit_dropin(plan):
    lines = [
        f"# {_header(plan)}",
        "# full_machine: the daemon and its tools are installed at first boot.",
        "[Unit]",
        f"Requires={SETUP_UNIT_NAME}",
        f"After={SETUP_UNIT_NAME} {STACK_UNIT_NAME}",
    ]
    return "\n".join(lines) + "\n"


def setup_unit(plan):
    lines = [
        f"# {_header(plan)}",
        "[Unit]",
        "Description=Install Burrow's agent host and its pinned tools",
        "Requires=docker.service",
        "After=docker.service network-online.target",
        "Wants=network-online.target",
    ]
    if plan.images_preloaded:
        # The daemon is copied out of the agent-host image: wait for it.
        lines.append(f"ConditionPathExists={INSTALL_ROOT}/.images-loaded")
    lines += [
        "",
        "[Service]",
        "Type=oneshot",
        "RemainAfterExit=yes",
        f"ExecStart={INSTALL_ROOT}/bin/{SETUP_SCRIPT}",
        "TimeoutStartSec=30min",
        "",
        "[Install]",
        "WantedBy=multi-user.target",
    ]
    return "\n".join(lines) + "\n"


def setup_script(plan, image):
    pull = "never" if plan.images_preloaded else "missing"
    trust = ""
    if plan.tls == "internal":
        trust = f"""\
# tls = internal: agents (node, bun, git, curl) must trust this install's root.
install -m 0644 {INSTALL_ROOT}/tls/root.crt /usr/local/share/ca-certificates/burrow-{plan.name}-root.crt
update-ca-certificates >/dev/null
"""
    return f"""\
#!/bin/sh
# {_header(plan)}
# Installs Burrow's agent host on THIS host (full_machine, task 01a10322).
# Idempotent; run by {SETUP_UNIT_NAME} before {HOST_UNIT_NAME}.
set -eu
image='{image}'
dest={INSTALL_ROOT}/agent-host
getent group {AGENTS_GROUP} >/dev/null || groupadd --system {AGENTS_GROUP}
{trust}# Agents reach core at its public URL, through Caddy on this host.
grep -q ' {plan.primary}$' /etc/hosts || printf '127.0.0.1 {plan.primary}\\n' >> /etc/hosts
# The daemon ships in the agent-host image, the artefact `contained` runs.
ctr="$(docker create --pull {pull} "$image")"
trap 'docker rm -f "$ctr" >/dev/null 2>&1 || true' EXIT
rm -rf "$dest.incoming"
docker cp "$ctr:{INSTALL_ROOT}/agent-host" "$dest.incoming"
chown -R root:root "$dest.incoming"
chmod -R go-w,a+rX "$dest.incoming"
rm -rf "$dest"
mv "$dest.incoming" "$dest"
if command -v snap >/dev/null 2>&1 && ! snap list chromium >/dev/null 2>&1; then
  snap install chromium
fi
sh "$dest/packaging/install-tools.sh" {VERSIONS_PATH}
"""


def full_machine_files(plan, host_env_text):
    """{path: (text, mode)} for cloud-init write_files; absolute or install-relative."""
    image = plan.agent_host_image
    return {
        SUDOERS_PATH: (SUDOERS, SUDOERS_MODE),
        VERSIONS_PATH: (VERSIONS_ENV, FILE_MODE),
        HOST_ENV_PATH: (host_env_text, SECRET_MODE),
        f"/etc/systemd/system/{HOST_UNIT_NAME}": (HOST_UNIT, FILE_MODE),
        f"/etc/systemd/system/{HOST_UNIT_NAME}.d/10-full-machine.conf": (
            host_unit_dropin(plan),
            FILE_MODE,
        ),
        f"/etc/systemd/system/{AGENT_TEMPLATE_UNIT_NAME}": (AGENT_TEMPLATE_UNIT, FILE_MODE),
        f"/etc/systemd/system/{SETUP_UNIT_NAME}": (setup_unit(plan), FILE_MODE),
        f"bin/{SETUP_SCRIPT}": (setup_script(plan, image), EXEC_MODE),
    }


def systemd_init_compose():
    """Compose keys for a systemd-as-PID-1 container under rootful docker.

    systemd needs a writable cgroup tree and tmpfs /run. Docker mounts
    /sys/fs/cgroup read-only for an unprivileged container, so this uses the
    host cgroup namespace with the tree mounted read-write. That is the cost of
    running the agent host's systemd under DOCKER: it is network and filesystem
    containment (no Postgres, no host files, no docker socket), and NOT a
    privilege boundary. Rootless podman (the reference install's quadlet, core-ops) is the
    measured contained profile, where container root is not host root.
    """
    return {
        "cgroup": "host",
        "tmpfs": ["/run", "/run/lock", "/tmp"],
        "stop_signal": "SIGRTMIN+3",
    }


# Appended to a systemd-init service's volumes (see systemd_init_compose).
SYSTEMD_INIT_VOLUME = "/sys/fs/cgroup:/sys/fs/cgroup:rw"
