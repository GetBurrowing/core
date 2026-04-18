# ── Stage 1: Build ────────────────────────────────────────────
FROM elixir:1.19.5-otp-28-slim AS build

RUN apt-get update -y \
 && apt-get install -y build-essential git curl ca-certificates \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config config
COPY assets assets
COPY priv priv
COPY lib lib

RUN cd assets && npm ci
RUN mix assets.deploy
RUN mix compile
RUN mix release

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM elixir:1.19.5-otp-28-slim AS app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      git libstdc++6 openssl libncurses6 locales ca-certificates wget \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen \
 && git config --system safe.directory '*'

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
