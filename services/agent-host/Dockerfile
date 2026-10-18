# Burrow's agent host, `contained` capability profile (core task 01a10322 stage 3).
#
# A SYSTEMD-INIT image: systemd is PID 1 (podman runs it in systemd mode), so
# agents use the same `sudo systemctl`, `systemctl --user` and `crontab` as on
# full_machine, and stage 2's suite-agent@ units run unchanged.
#
# Agents get passwordless sudo INSIDE this container. Under rootless podman
# container root is not host root: an agent is root over this container (every
# agent's home) and not over the host or Postgres. An install is one trust
# group; per-agent users stop accidental crossing, not malicious crossing.
#
# Built by .github/workflows/ci.yml (build-and-push-agent-host) only when
# services/agent-host/** changes, because every push restarts every agent on an
# AutoUpdate host. Context: services/agent-host.
FROM docker.io/library/debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       systemd systemd-sysv dbus libpam-systemd sudo passwd procps cron \
       tmux git curl ca-certificates xz-utils unzip less chromium \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask getty.target console-getty.service systemd-firstboot.service \
       systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket

WORKDIR /opt/suite/agent-host

# Tools first: the slowest layer changes only with versions.env.
COPY versions.env ./versions.env
COPY packaging/install-tools.sh ./packaging/install-tools.sh
RUN sh ./packaging/install-tools.sh ./versions.env

COPY package.json bun.lock tsconfig.json ./
RUN bun install --frozen-lockfile --production
COPY src ./src
COPY packaging ./packaging
# Every agent's ~/.claude/CLAUDE.md carries suite-cli's own conventions
# (src/conventions.ts); fail here if the pinned suite-cli no longer exports them.
RUN bun run src/conventions.ts --check

RUN groupadd --system suite-agents \
    && install -m 0440 packaging/sudoers-suite-agents /etc/sudoers.d/suite-agents \
    && visudo -cf /etc/sudoers.d/suite-agents \
    && install -m 0644 packaging/suite-agent-host.service /etc/systemd/system/suite-agent-host.service \
    && install -m 0644 "packaging/suite-agent@.service" "/etc/systemd/system/suite-agent@.service" \
    && systemctl enable suite-agent-host.service

# Read through the unit's PassEnvironment; an EnvironmentFile entry wins.
ENV AGENT_HOST_PROFILE=contained

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
