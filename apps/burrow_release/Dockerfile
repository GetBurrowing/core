# The WITH-modules image (ADR 0055, task 01a0ee08 stage 4): the release of the
# apps/burrow_release host, whose deps are core plus the selected build-time
# modules (today: Play, apps/game_stream). apps/platform/Dockerfile builds the
# WITHOUT-modules image from apps/platform alone and is unchanged.
#
# Build from the repo root, like core's:
#   podman build -f apps/burrow_release/Dockerfile .
#
# The RUNTIME stage below is core's, line for line, except the one
# `COPY --from=build` line that names where the release was built.
# apps/platform/test/platform/image_flavours_test.exs holds that, so the two
# images cannot drift apart in what they install, expose or run.

# ── Stage 1: Build ────────────────────────────────────────────
FROM ghcr.io/getburrowing/elixir:1.20.4-otp-28-slim@sha256:a61672ebbafaf93ec6baeee14657fa73407e4f7fe57e92b2e3f063d25d0d3244 AS build

RUN apt-get update -y \
 && apt-get install -y build-essential git curl ca-certificates \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app/apps

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Build identity (task 01a089d5), exactly as core's Dockerfile: it ships as
# the file priv/build_commit inside core's app, which /health reports.
ARG GIT_SHA

# Every project's mix.exs and lockfile first, so the hex deps layer is cached
# across source edits. The host resolves core's and the module's deps by path,
# so their mix.exs files must be in place before `deps.get`.
COPY apps/platform/mix.exs apps/platform/mix.lock platform/
COPY apps/game_stream/mix.exs apps/game_stream/mix.lock game_stream/
COPY apps/social/mix.exs apps/social/mix.lock social/
COPY apps/burrow_release/mix.exs apps/burrow_release/mix.lock burrow_release/

# tailwind and the precompiled NIFs (wasmex, vix) are GitHub release
# downloads that OTP 28's httpc fails on (header_too_long, 2026-10-23). The
# script fetches them with curl into the paths the deps check first; see its
# header.
COPY scripts/fetch-github-release-binaries.sh /usr/local/bin/

WORKDIR /app/apps/burrow_release
RUN mix deps.get --only $MIX_ENV
# Hex deps only: the path deps (core and the module) have no source yet.
RUN sh /usr/local/bin/fetch-github-release-binaries.sh nifs . && mix deps.compile --skip-local-deps

WORKDIR /app/apps
COPY apps/platform/config platform/config
COPY apps/platform/assets platform/assets
COPY apps/platform/priv platform/priv
COPY apps/platform/lib platform/lib
COPY apps/game_stream/config game_stream/config
COPY apps/game_stream/assets game_stream/assets
COPY apps/game_stream/priv game_stream/priv
COPY apps/game_stream/lib game_stream/lib
COPY apps/social/config social/config
COPY apps/social/assets social/assets
COPY apps/social/priv social/priv
COPY apps/social/lib social/lib
COPY apps/burrow_release/config burrow_release/config

# The ADR corpus and the build commit go into CORE's priv/, where
# Platform.Responsibilities.ContextProviders and Platform.BuildInfo read them,
# and above `mix release`, which snapshots priv/ (see core's Dockerfile and
# Platform.Regression.ADRCorpusPackagingTest).
WORKDIR /app/apps/platform
COPY docs/decisions priv/adr_decisions
# Burrow Docs, compiled into Platform.Org.BurrowDocs, which fails the build
# when it resolves no docs (Platform.Regression.BurrowDocsPackagingTest).
COPY docs/burrow priv/burrow_docs
RUN printf '%s' "${GIT_SHA:-unknown}" > priv/build_commit

RUN cd assets && npm ci

# Assets. The host's `assets.deploy` builds app.css from the generated wrapper
# stylesheet, app.js with `@extensions` bound to the generated entry, and
# core's two islands, all into apps/burrow_release/priv/static/assets. The
# Endpoint serves `from: :platform`, so they then move into core's
# priv/static (inside this image only), beside the Excalidraw runtime assets
# core's script copies there, and `phx.digest` writes core's
# cache_manifest.json over the whole directory, as core's own build does.
WORKDIR /app/apps/burrow_release
RUN sh /usr/local/bin/fetch-github-release-binaries.sh tailwind . ../platform/config/config.exs && mix assets.deploy
RUN cd ../platform/assets && node scripts/copy_excalidraw_assets.mjs
RUN mkdir -p ../platform/priv/static/assets \
 && cp -a priv/static/assets/. ../platform/priv/static/assets/
RUN mix phx.digest ../platform/priv/static
RUN mix compile
RUN mix release

# ── Stage: ffmpeg (static binaries) ──────────────────────────
# Clip rendering needs ffmpeg + ffprobe with libass. Debian's apt package
# pulled ~417 MB of shared libraries into every image; one pinned static
# build (johnvansickle.com 7.0.2, libass 0.17.3) is two files, ~51-59 MB
# compressed per arch. Fetched and sha256-verified here so curl and xz never
# reach the runtime stage, which only COPYs the two binaries.
#
# Source: a byte-identical mirror on the GetBurrowing/core GitHub release
# vendor-ffmpeg-7.0.2, so a build does not depend on johnvansickle.com being
# up. The repo is private, so the mirror is fetched through the API asset
# endpoint with an optional BuildKit secret `gh_token`
# (`--secret id=gh_token,env=GH_TOKEN`); the token is read from
# /run/secrets only and never reaches a layer, ENV or ARG. With no token, or
# if the mirror download fails, it falls back to FFMPEG_FALLBACK_BASE. The
# sha256 check runs once on whichever file was fetched, and a mismatch fails
# the build: it never falls back after a checksum failure.
#
# To bump: upload the new tarballs to a new vendor-ffmpeg-<version> release,
# then change FFMPEG_VERSION, both checksums (sha256 of each arch's tarball)
# and both asset ids (gh api repos/GetBurrowing/core/releases/tags/<tag>).
FROM ghcr.io/getburrowing/elixir:1.20.4-otp-28-slim@sha256:a61672ebbafaf93ec6baeee14657fa73407e4f7fe57e92b2e3f063d25d0d3244 AS ffmpeg
ARG TARGETARCH
ARG FFMPEG_VERSION=7.0.2
ARG FFMPEG_SHA256_AMD64=abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67
ARG FFMPEG_SHA256_ARM64=f4149bb2b0784e30e99bdda85471c9b5930d3402014e934a5098b41d0f7201b1
ARG FFMPEG_ASSET_ID_AMD64=679857169
ARG FFMPEG_ASSET_ID_ARM64=679857160
ARG FFMPEG_FALLBACK_BASE=https://johnvansickle.com/ffmpeg/releases
RUN --mount=type=secret,id=gh_token,required=false \
    apt-get update -y \
 && apt-get install -y --no-install-recommends curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "$arch" in \
      amd64) sha="$FFMPEG_SHA256_AMD64"; asset="$FFMPEG_ASSET_ID_AMD64" ;; \
      arm64) sha="$FFMPEG_SHA256_ARM64"; asset="$FFMPEG_ASSET_ID_ARM64" ;; \
      *) echo "no pinned ffmpeg build for $arch" >&2; exit 1 ;; \
    esac \
 && if [ -s /run/secrets/gh_token ] \
      && curl -fsSL -o /tmp/ffmpeg.tar.xz \
           -H "Authorization: Bearer $(cat /run/secrets/gh_token)" \
           -H 'Accept: application/octet-stream' \
           "https://api.github.com/repos/GetBurrowing/core/releases/assets/${asset}"; then \
      echo 'ffmpeg source: release'; \
    else \
      rm -f /tmp/ffmpeg.tar.xz \
      && curl -fsSL -o /tmp/ffmpeg.tar.xz \
           "${FFMPEG_FALLBACK_BASE}/ffmpeg-${FFMPEG_VERSION}-${arch}-static.tar.xz" \
      && echo 'ffmpeg source: fallback'; \
    fi \
 && echo "${sha}  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xJf /tmp/ffmpeg.tar.xz -C /out --strip-components=1 \
      "ffmpeg-${FFMPEG_VERSION}-${arch}-static/ffmpeg" \
      "ffmpeg-${FFMPEG_VERSION}-${arch}-static/ffprobe" \
 && rm -f /tmp/ffmpeg.tar.xz \
 && chmod 0755 /out/ffmpeg /out/ffprobe \
 && /out/ffmpeg -hide_banner -filters | grep -qE ' subtitles ' \
 && /out/ffmpeg -hide_banner -filters | grep -qE ' ass ' \
 && /out/ffprobe -version

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM ghcr.io/getburrowing/elixir:1.20.4-otp-28-slim@sha256:a61672ebbafaf93ec6baeee14657fa73407e4f7fe57e92b2e3f063d25d0d3244 AS app

# Same build arg re-declared for this stage (ARGs do not cross stages) so the
# image carries its commit as an OCI label:
#   podman inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
# answers without dumping the environment.
ARG GIT_SHA
LABEL org.opencontainers.image.revision="${GIT_SHA:-unknown}"

# ffmpeg: clip rendering (9:16 crop, burned-in captions, end card) shells
# out to ffmpeg/ffprobe at runtime. The static build from the `ffmpeg` stage
# is built with libass, so the `subtitles` and `ass` filters the captions need
# are present; caption fonts come from the release's priv via `fontsdir`, so
# no system fonts or fontconfig are installed. Every image carries it,
# because image_flavours_test requires the runtime stages to be identical.
COPY --from=ffmpeg /out/ffmpeg /out/ffprobe /usr/local/bin/

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      git libstdc++6 openssl libncurses6 locales ca-certificates wget curl python3 \
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

COPY --from=build --chown=app:app /app/apps/burrow_release/_build/prod/rel/platform ./

EXPOSE 4000

CMD ["/bin/sh", "-c", "/app/bin/platform eval 'Platform.Release.migrate()' && /app/bin/platform start"]
