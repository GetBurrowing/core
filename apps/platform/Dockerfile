# ── Stage 1: Build ────────────────────────────────────────────
FROM elixir:1.19.5-otp-28-slim AS build

RUN apt-get update -y \
 && apt-get install -y build-essential git \
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

RUN mix assets.deploy
RUN mix compile
RUN mix release

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM elixir:1.19.5-otp-28-slim AS app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates wget \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

RUN useradd -m -u 1000 app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/platform ./

EXPOSE 4000

CMD ["/app/bin/platform", "start"]
