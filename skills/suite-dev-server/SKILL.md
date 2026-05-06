---
name: suite-dev-server
description: Start and manage a local Startup Suite Phoenix dev server from any `core` worktree, cross-platform (macOS, Linux, Windows/WSL2). Provides toolchain install pointers (asdf-pinned Erlang/OTP 27 + Elixir 1.19), a generic Postgres 16 setup via `docker compose`, and helper scripts that pick a free port, run migrations, and start `mix phx.server` in the background. Use when an agent needs to run the exact code in its worktree on a free local port, validate a feature in the browser, and shut the server down cleanly.
---

# Suite Dev Server

This skill describes how any contributor — or any federated agent on any host — can
stand up a Startup Suite Phoenix dev server from a `core` worktree. It is the
common path for in-review validation, screenshots, and browser proof.

The skill ships three helper scripts under `scripts/`:

- `start-server.sh <worktree_path>` — picks a free port, runs migrations, starts
  `mix phx.server` in the background, prints the chosen port to stdout.
- `wait-for-server.sh <port>` — polls `/dev/login` until the server responds.
- `stop-server.sh <port>` — kills the server using a PID file written at start.

Every helper is plain `bash` and works on macOS, Linux, and WSL2. Native Windows
users should run the helpers from a WSL2 prompt.

## 1. Toolchain install (one-time)

Suite is Elixir/Phoenix and targets **Erlang/OTP 27+** and **Elixir 1.19+**. The
recommended cross-platform installer is [asdf](https://asdf-vm.com/), which gives
you a single `.tool-versions`-pinnable workflow on every host.

### macOS (Homebrew + asdf)

```bash
brew install asdf coreutils autoconf openssl@3 wxwidgets libxslt fop unixodbc
echo '. "$(brew --prefix asdf)/libexec/asdf.sh"' >> ~/.zshrc && exec zsh
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.3.4
asdf install elixir 1.19.0-otp-27
asdf set -u erlang 27.3.4
asdf set -u elixir 1.19.0-otp-27
```

If you'd rather not use asdf, `brew install elixir` installs a recent Elixir +
Erlang. CONTRIBUTING.md walks through the Homebrew-native path.

### Linux (apt + asdf)

```bash
sudo apt-get update
sudo apt-get install -y build-essential autoconf m4 libssl-dev libncurses5-dev \
  libwxgtk3.2-dev libwxgtk-webview3.2-dev libgl1-mesa-dev libglu1-mesa-dev \
  libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils git curl
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc && exec bash
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.3.4
asdf install elixir 1.19.0-otp-27
asdf set -u erlang 27.3.4
asdf set -u elixir 1.19.0-otp-27
```

### Windows

Use **WSL2 + Ubuntu** and follow the Linux steps above. Native Windows works for
some Elixir workflows but the helper scripts in this skill assume a POSIX shell.

If you genuinely want native Windows, install via [Scoop](https://scoop.sh/):

```powershell
scoop install erlang elixir postgresql
```

…and translate the helper scripts to PowerShell yourself.

### Verify

```bash
elixir --version
# Erlang/OTP 27 [erts-15.x] ...
# Elixir 1.19.x (compiled with Erlang/OTP 27)
```

## 2. PostgreSQL via `docker compose`

The simplest cross-platform Postgres setup is the `docker-compose.yml` shipped at
the repo root. It provisions a single Postgres 16 container with a host port
binding to the standard `5432`.

```bash
docker compose up -d postgres
docker compose ps postgres   # should show "healthy"
```

Defaults match `apps/platform/config/dev.exs`:

| Setting   | Value      |
|-----------|------------|
| Username  | `postgres` |
| Password  | `postgres` |
| Host      | `localhost`|
| Port      | `5432`     |
| Database  | `platform_dev` (created by `mix ecto.setup`) |

If port `5432` is taken on your host, edit the compose file's port mapping to e.g.
`"55432:5432"` and export `PGPORT=55432` before running mix. Or, if you already
run a Postgres on the host, skip the container entirely and just point at it via
the env vars below.

If you don't want to run docker, install Postgres natively (`brew install
postgresql@16`, `apt-get install postgresql-16`, or `scoop install postgresql`)
and ensure a `postgres` superuser role exists:

```bash
psql postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
```

## 3. Start the server

### Manual path (one-liner)

From a fresh checkout, this is the entire dev-server bootstrap:

```bash
cd apps/platform
mix deps.get
mix ecto.setup       # ecto.create + ecto.migrate
mix phx.server       # listens on http://localhost:4000
```

Visit <http://localhost:4000/dev/login> to bypass OIDC and auto-create a dev user.

### Helper-script path (free port + background)

When multiple worktrees are running side by side, port 4000 is already taken.
Use `scripts/start-server.sh` to pick a free port in `4001-4099`:

```bash
PORT=$(skills/suite-dev-server/scripts/start-server.sh "$(pwd)")
skills/suite-dev-server/scripts/wait-for-server.sh "$PORT"
echo "Suite dev server: http://localhost:$PORT/dev/login"
# ... do the work ...
skills/suite-dev-server/scripts/stop-server.sh "$PORT"
```

The start script:

1. Resolves `apps/platform` from the worktree path.
2. Picks a free TCP port in `4001-4099` (uses `ss` on Linux when present,
   falls back to `lsof`, then to a `bash`/`/dev/tcp` probe — works on macOS too).
3. Exports `MIX_ENV=dev`, `SECRET_KEY_BASE`, `PHX_BIND_IP=127.0.0.1`,
   `APP_URL=http://localhost:<port>`. Honors any `DATABASE_URL` /
   `PG{HOST,PORT,USER,PASSWORD}` you've already set, otherwise inherits the
   defaults from `config/dev.exs`.
4. Runs `mix deps.get` only if `_build/dev` is missing, then `mix ecto.migrate`.
5. Starts `mix phx.server` via `nohup` in the background. Logs to
   `/tmp/suite-dev-<port>.log`. PID lands in `/tmp/suite-dev-<port>.pid`.
6. Prints the chosen port to stdout.

To bind to all interfaces (e.g. for testing from a phone on the same Wi-Fi):

```bash
PHX_BIND_IP=0.0.0.0 skills/suite-dev-server/scripts/start-server.sh "$(pwd)"
```

## 4. Configuration env vars

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | picked by helper, `4000` if launching mix directly | TCP port the endpoint listens on |
| `PHX_BIND_IP` | `127.0.0.1` | Bind address (`0.0.0.0` to expose on LAN) |
| `DATABASE_URL` | unset; falls back to `PGUSER`/`PGPASSWORD`/etc. | Full Postgres URL, takes precedence |
| `PGUSER` / `PGPASSWORD` / `PGHOST` / `PGPORT` | `postgres`/`postgres`/`localhost`/`5432` | Per-component DB config |
| `PLATFORM_DEV_DATABASE` | `platform_dev` | Database name |
| `SECRET_KEY_BASE` | dev placeholder set by helper script | Signing key (>= 64 chars in dev) |
| `APP_URL` | `http://localhost:<port>` | Used for absolute-URL generation |

## 5. Optional: seed a federation-friendly dev space

The repo ships an idempotent dev seed that creates a `general` channel, a `main`
agent record, and a couple of project rows useful for federation testing:

```bash
cd apps/platform
mix run priv/repo/seeds/dev_federation_seed.exs
```

For task-tree fixtures:

```bash
mix run priv/repo/seeds/tasks_seed.exs
```

Both seeds are safe to re-run; they upsert by slug.

## 6. Validate

Without a browser:

```bash
curl -sSI http://localhost:$PORT/dev/login   # -> HTTP/1.1 302
```

With a browser, follow the `agent-chrome-cdp` skill to attach to a dedicated
Chrome on `127.0.0.1:9222`, navigate to `http://localhost:$PORT/dev/login`, and
capture a screenshot via the `agent-screenshot-and-canvas` skill.

## 7. Stop

```bash
skills/suite-dev-server/scripts/stop-server.sh "$PORT"
```

The stop script sends `SIGTERM` to the PID written at start, waits up to 10 s,
and removes the PID file. If the PID file is gone, it refuses to kill the
listener it finds — pass `--force` only after you've confirmed the listener is
yours (via `lsof -nP -i :$PORT` on macOS / `ss -tlnp "sport = :$PORT"` on
Linux).

## 8. Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `:eaddrinuse` on startup | Another worktree or stale PID file took the port between the scan and `phx.server`. | `rm /tmp/suite-dev-<port>.pid` and rerun. |
| DB connection error | Postgres not running, or wrong host/port. | `docker compose ps postgres` (or `pg_isready -h localhost`). |
| `mix: command not found` | asdf not initialized in this shell. | `. "$HOME/.asdf/asdf.sh"` (or restart the shell). |
| Stale code in browser | Wrong worktree or wrong port. | Confirm the port you got from `start-server.sh` matches the URL. |
| `/dev/login` 404 | `dev_routes` is off — you're running prod env. | Ensure `MIX_ENV=dev`. |
