# Contributing

## Local setup (macOS, Homebrew)

Install Elixir, Erlang (pulled in by Elixir), and PostgreSQL 16:

```bash
brew install elixir postgresql@16
brew services start postgresql@16
```

The Phoenix dev/test config in `apps/platform/config/{dev,test}.exs` defaults to `PGUSER=postgres` / `PGPASSWORD=postgres`. Homebrew's PostgreSQL initializes with your macOS username as the default superuser and no `postgres` role, so create one:

```bash
psql postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
```

Then install Elixir toolchain bits and project deps:

```bash
cd apps/platform
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
```

## Running the dev server

Create + migrate the dev database once, then start the Phoenix endpoint:

```bash
cd apps/platform
mix ecto.create
mix ecto.migrate
mix phx.server
```

The server listens on http://localhost:4000. The default `config/dev.exs` points `Platform.Repo` at `postgresql://postgres:postgres@localhost:5432/platform_dev` so `mix phx.server` works out of the box. Override via `DATABASE_URL` or the individual `PGUSER` / `PGPASSWORD` / `PGHOST` / `PGPORT` / `PLATFORM_DEV_DATABASE` env vars if you need a different instance.

### Bypassing OIDC in dev

Production requires an OIDC provider, but dev has a bypass. Visit http://localhost:4000/dev/login to auto-create a local user and get a session cookie. From there, navigate to `/chat`.

### Testing from a phone on the same WiFi

Phoenix binds to `127.0.0.1` by default. To reach the dev server from a phone on the same network (useful for testing mobile-only UX like the long-press menu), bind to all interfaces:

```bash
PHX_BIND_IP=0.0.0.0 mix phx.server
```

Then on your phone, open `http://<your-mac-ip>:4000` (find your Mac's IP with `ipconfig getifaddr en0`). Don't leave the server on `0.0.0.0` outside of a trusted network — there's no prod-style auth in dev.

### Channel plugin (`claude-code-suite-channel`)

If you also work on the Claude Code channel plugin, install Bun (it's the runtime the plugin targets) and pull its deps:

```bash
brew install oven-sh/bun/bun
cd path/to/claude-code-suite-channel
bun install
bun run typecheck
```

## Running checks

Match what CI runs (`.github/workflows/ci.yml`):

```bash
cd apps/platform
mix format --check-formatted
mix ecto.create
mix ecto.migrate
mix test
```

The full-suite test run auto-creates and migrates the test database on each invocation.

For a fuller local-only check, the repo also supports `mix precommit` (compile with warnings-as-errors, unused-dep check, format, test). CI does not gate on warnings-as-errors, so pre-existing warnings may block precommit even when CI is green.

## Overriding DB defaults

If you already have a Postgres instance and don't want a separate `postgres` role, export the credentials before running mix:

```bash
PGUSER=$USER PGPASSWORD='' mix test
```

`config/test.exs` reads `PGUSER`, `PGPASSWORD`, `PGHOST`, and `PGPORT` via `System.get_env/2`.

## More

See `CLAUDE.md` for architecture, domain-context boundaries, Elixir/Phoenix idioms, and the ADR index under `docs/decisions/`.
