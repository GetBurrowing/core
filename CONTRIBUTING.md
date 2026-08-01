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

## Adding a migration

Every migration under `apps/platform/priv/repo/migrations` with a version at or after `20260520000000` must carry a `@moduledoc` of at least 40 characters saying why it exists, and must cite the work that admitted it: a Suite task id (`019fba52`), an ADR number (`ADR-0033`), or a PR number (`#647`). The guard is `apps/platform/test/platform/org/wiki/context_t4_e2e_test.exs`, and its failure message restates all of this.

There is no list to append to and no count to bump. Admission is a property of the migration file itself, so two branches adding migrations on the same day touch only the files they each created.

This replaced a hand-maintained allow-list (`@t4_allowed_new_migrations`), which every branch adding a migration had to append to. That put each of those branches behind a merge conflict in a file none of them were working on. On 2026-07-31 four PRs (#645, #648, #647, #651) each added a migration and each had to edit that one list; #648 merged while #647 was open, and #647 was rebased eight minutes later to absorb the line #648 had just added. Do not reintroduce a list.

To run a new migration before you commit it, point at a scratch database:

```bash
cd apps/platform
PLATFORM_TEST_DATABASE=platform_test_scratch mix test
```

`mix test`'s alias in `apps/platform/mix.exs` runs `ecto.create` and `ecto.migrate` inside a `try/rescue` that swallows every error and exit, so a broken migration run against the shared `platform_test` database reports nothing at the point of damage. A migration that succeeds is recorded in that database's `schema_migrations` and will not run again, which is the other reason to keep experiments off it.

## Overriding DB defaults

If you already have a Postgres instance and don't want a separate `postgres` role, export the credentials before running mix:

```bash
PGUSER=$USER PGPASSWORD='' mix test
```

`config/test.exs` reads `PGUSER`, `PGPASSWORD`, `PGHOST`, and `PGPORT` via `System.get_env/2`.

## More

See `CLAUDE.md` for architecture, domain-context boundaries, Elixir/Phoenix idioms, and the ADR index under `docs/decisions/`.
