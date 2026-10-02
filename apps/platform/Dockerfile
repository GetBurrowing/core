# ── Stage 1: Build ────────────────────────────────────────────
FROM elixir:1.20.2-otp-28-slim AS build

RUN apt-get update -y \
 && apt-get install -y build-essential git curl ca-certificates \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Build identity (task 01a089d5). CI passes the commit it is building from;
# a local `podman build` without the arg gets "unknown". The value ships as a
# FILE inside the release (see below), never as a runtime env var, so it
# cannot be overridden by an EnvironmentFile and does not appear in
# `podman inspect .Config.Env` next to the secrets.
ARG GIT_SHA

COPY apps/platform/mix.exs apps/platform/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY apps/platform/config config
COPY apps/platform/assets assets
COPY apps/platform/priv priv
COPY apps/platform/lib lib

# The ADR corpus lives at the repo root, outside this app. It is copied into
# the app's `priv/` so it ships inside the release: the running image has no
# `docs/decisions/` to walk to, so without this the ADR index resolves as
# unreachable and the drift check silently reports "no decisions".
#
# This COPY must stay ABOVE `mix release` — the release snapshots `priv/` as
# it runs, so a copy landing afterwards ships nothing. The same holds for the
# `priv/build_commit` write below: it is what `Platform.BuildInfo.commit/0`
# reads and `/health` reports, and it has to be in `priv/` before the release
# snapshots it. `Platform.BuildInfoTest` guards the ordering.
COPY docs/decisions priv/adr_decisions
RUN printf '%s' "${GIT_SHA:-unknown}" > priv/build_commit

RUN cd assets && npm ci
RUN mix assets.deploy
RUN mix compile
RUN mix release

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM elixir:1.20.2-otp-28-slim AS app

# Same build arg re-declared for this stage (ARGs do not cross stages) so the
# image carries its commit as an OCI label:
#   podman inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
# answers without dumping the environment.
ARG GIT_SHA
LABEL org.opencontainers.image.revision="${GIT_SHA:-unknown}"

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      git libstdc++6 openssl libncurses6 locales ca-certificates wget curl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen \
 && git config --system safe.directory '*'

# GitHub CLI. NOT optional: the running platform shells out to `gh` to open
# the stack rollup PR (Platform.Tasks.StackDeployer.GitShellRunner), to
# auto-merge task PRs (Platform.Tasks.AutoMerger) and to resolve a PR number
# from a branch (PlatformWeb.GithubWebhookController). The image shipped
# without it, so every one of those paths died with an opaque
# `ErlangError: :enoent` that looked like a git failure — see the
# `System.find_executable("gh")` guards those modules now carry.
#
# Installed from the official apt repo rather than a pinned tarball so the
# arch is derived from the build platform (`dpkg --print-architecture`).
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -y \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && gh --version

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

RUN useradd -m -u 1000 app

# Chat attachment storage root. Operators must mount a persistent volume at
# /data/platform/chat_uploads in their deployment manifest — otherwise
# attachments are written to the container's ephemeral layer and vanish on
# every restart/redeploy. See Platform.Chat.AttachmentStorage.
RUN mkdir -p /data/platform/chat_uploads && chown -R app:app /data/platform
VOLUME ["/data/platform/chat_uploads"]

USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/platform ./

EXPOSE 4000

CMD ["/bin/sh", "-c", "/app/bin/platform eval 'Platform.Release.migrate()' && /app/bin/platform start"]
