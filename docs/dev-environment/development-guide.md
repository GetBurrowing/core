# Development guide

This guide says which command to run in which directory, and how to reproduce CI on your own machine. Every command here ran on a clean clone of this repo on 2026-11-04, on macOS arm64 with the versions below, branched from commit `056de28f8`.

For first-time setup, follow [CONTRIBUTING.md](../../CONTRIBUTING.md):

- [Installing Elixir, Postgres and project dependencies](../../CONTRIBUTING.md#local-setup-macos-homebrew)
- [Running the dev server](../../CONTRIBUTING.md#running-the-dev-server), [signing in locally](../../CONTRIBUTING.md#bypassing-oidc-in-dev) and [testing from a phone](../../CONTRIBUTING.md#testing-from-a-phone-on-the-same-wifi)
- [Adding a migration](../../CONTRIBUTING.md#adding-a-migration)
- [Pointing at a different Postgres](../../CONTRIBUTING.md#overriding-db-defaults)

## Versions

Nothing outside `.github/workflows/ci.yml` pins a toolchain: the repo has no `.tool-versions` or `.nvmrc`.

| Tool | CI uses | Ran for this guide |
|---|---|---|
| Elixir | 1.20.4 | 1.20.4 for everything. 1.19.5 for `apps/platform` compile, format check and one test file. |
| Erlang/OTP | 28 | 28 |
| Node | 24 | 24.22.2 |
| Postgres | 16 | 16 |
| Python | 3.12 | 3.12, in CI's image for the installer tests |
| bun | `bun:1` image | CI's image |

`apps/platform` compiles with no warnings on both Elixir versions in the table. The `~> 1.15` in `mix.exs` is the range Mix accepts. No older Elixir or OTP was tried, so use the CI version when you can.

## Where to run what

There is no `mix.exs` at the repo root. Change into the directory that owns the code first.

| Directory | What it is | Tooling |
|---|---|---|
| `apps/platform` | The core app | `mix`, and `npm` in `assets/` |
| `apps/game_stream` | Play, a build-time module | `mix`, and `npm` in `assets/` |
| `apps/social` | Social, a build-time module | `mix`, and `npm` in `assets/` |
| `apps/burrow_release` | Release host for the with-modules image. It has no tests of its own. | `mix` |
| `services/agent-host` | Agent host | bun, in CI's image |
| `services/meeting-voice-agent` | Meeting voice agent | `uv` |
| `deployment/installer` | Installer. Its tests run from the repo root. | Python 3.12, in CI's image |
| `clients/ios`, `clients/android` | Native apps | See the [iOS](../../clients/ios/README.md) and [Android](../../clients/android/README.md) READMEs |

## A private database for each checkout

Every checkout on one Postgres server shares `platform_test` and `platform_dev` by default, so two test runs at once collide. Give each checkout its own names, and export them in every shell you use for that checkout:

```bash
export PLATFORM_TEST_DATABASE=platform_test_mycheckout
export PLATFORM_DEV_DATABASE=platform_dev_mycheckout
```

Replace `mycheckout` with a name of your own. The commands below read these variables.

`mix test` creates and migrates its database before each run. If either step fails, it prints `the suite was NOT run` and exits non-zero. Keep migration experiments on a scratch database, as [Adding a migration](../../CONTRIBUTING.md#adding-a-migration) describes.

## Running tests

Run one file while you work:

```bash
cd apps/platform
mix test test/platform/product_name_guard_test.exs
```

CI splits the full `apps/platform` suite into six partitions, each with its own database, and includes the tests tagged `slow`. To run the same split on one machine, install the JavaScript dependencies once, because some tests build the JavaScript bundle:

```bash
cd apps/platform/assets
npm ci
cd ..
for p in 1 2 3 4 5 6; do
  MIX_TEST_PARTITION=$p PLATFORM_TEST_DATABASE=${PLATFORM_TEST_DATABASE}_p$p mix test --include slow --partitions 6 || echo "partition $p failed"
done
```

In the run for this guide, on a 10-core Mac, all six partitions passed: 26,750 tests in about 16 minutes.

CI's partitions retry failures once with `mix test --failed --max-cases 1 --include slow`. The loop above does not, so run that command with the same partition's `PLATFORM_TEST_DATABASE` when you want to tell a flake from a real failure.

## CI jobs and their local commands

Rows follow the order of the steps in `ci.yml`. The table leaves out steps that only prepare the runner: system packages, caches and Postgres log settings. CI sets `MIX_ENV=test` across its test jobs, so the rows set it wherever it changes what runs.

| CI job | Run from | Local command |
|---|---|---|
| `test-checks` | repo root | The duplicate timestamp check below |
| `test-checks` | repo root | `elixir scripts/check-module-lockfiles.exs` |
| `test-checks` | repo root | `sh scripts/check-surface-budget.sh` |
| `test-checks` | repo root | `sh scripts/test/surface_budget_check_test.sh` |
| `test-checks` | `apps/platform` | `mix deps.get` |
| `test-checks` | `apps/platform` | `sh ../../scripts/fetch-github-release-binaries.sh nifs .` |
| `test-checks` | `apps/platform/assets` | `npm ci` |
| `test-checks` | `apps/platform/assets` | `npx vitest run` |
| `test-checks` | `apps/platform/assets` | `node --test "test/**/*_test.mjs"` |
| `test-checks` | `apps/platform/assets` | `node scripts/check_no_direct_localstorage.mjs` |
| `test-checks` | `apps/platform` | `MIX_ENV=dev mix compile --force --warnings-as-errors` |
| `test-checks` | `apps/platform` | `MIX_ENV=test mix compile --force --warnings-as-errors` |
| `test-checks` | `apps/platform` | `mix format --check-formatted` |
| `test-checks` | `apps/platform` | `MIX_ENV=test mix ecto.create` |
| `test-checks` | `apps/platform` | `MIX_ENV=test mix ecto.migrate` |
| `test-checks` | `apps/platform` | `mix test --only isolated_beam` |
| `test-checks` | `apps/platform` | `mix test test/platform/audit/historian_latency_test.exs test/platform/accounts/external_admission_notifier_test.exs --seed 0` |
| `test-shard` | `apps/platform` | The loop in [Running tests](#running-tests) |
| `test` | N/A | No local command: it adds up the partitions' results |
| `first-run-green` | N/A | No local command: it fails when a partition's retry fired |
| `test-with-play` | `apps/game_stream` | `MIX_ENV=dev mix deps.get` |
| `test-with-play` | `apps/game_stream` | `MIX_ENV=test mix deps.get` |
| `test-with-play` | `apps/game_stream` | `sh ../../scripts/fetch-github-release-binaries.sh nifs .` |
| `test-with-play` | `apps/game_stream` | `MIX_ENV=dev mix compile --force --warnings-as-errors` |
| `test-with-play` | `apps/game_stream` | `MIX_ENV=test mix compile --force --warnings-as-errors` |
| `test-with-play` | `apps/game_stream` | `mix format --check-formatted` |
| `test-with-play` | `apps/game_stream` | `PLATFORM_TEST_DATABASE=${PLATFORM_TEST_DATABASE}_play mix test` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix deps.get` |
| `test-with-play` | `apps/burrow_release` | `sh ../../scripts/fetch-github-release-binaries.sh nifs .` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix compile --warnings-as-errors` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix format --check-formatted` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix platform.extensions.assets --out assets/generated` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix tailwind.install --if-missing` |
| `test-with-play` | `apps/burrow_release` | `MIX_ENV=dev mix tailwind platform --minify` |
| `test-with-play` | `apps/platform` | `MIX_ENV=test mix tailwind.install --if-missing` |
| `test-with-play` | `apps/platform` | `MIX_ENV=test mix tailwind platform --minify` |
| `test-with-play` | `apps/platform` | `sh ../../scripts/check-flavour-css.sh priv/static/assets/css/app.css ../burrow_release/priv/static/assets/css/app.css` |
| `test-with-play` | `apps/game_stream/assets` | `npm ci` |
| `test-with-play` | `apps/game_stream/assets` | `npx vitest run` |
| `test-with-play` | `apps/platform/assets` | The with-Play bundle guard below |
| `test-with-social` | `apps/social` | `MIX_ENV=dev mix deps.get` |
| `test-with-social` | `apps/social` | `MIX_ENV=test mix deps.get` |
| `test-with-social` | `apps/social` | `sh ../../scripts/fetch-github-release-binaries.sh nifs .` |
| `test-with-social` | `apps/social` | `MIX_ENV=dev mix compile --force --warnings-as-errors` |
| `test-with-social` | `apps/social` | `MIX_ENV=test mix compile --force --warnings-as-errors` |
| `test-with-social` | `apps/social` | `mix format --check-formatted` |
| `test-with-social` | `apps/social` | `PLATFORM_TEST_DATABASE=${PLATFORM_TEST_DATABASE}_social mix test` |
| `test-with-social` | `apps/social/assets` | `npm ci` |
| `test-with-social` | `apps/social/assets` | `npx vitest run` |
| `agent-host-checks` | repo root | The agent host command below |
| `meeting-voice-agent` | `services/meeting-voice-agent` | `uv run --locked --extra dev pytest --ignore=tests/live -q` |
| `installer` | repo root | The installer command below |
| `build-and-push`, `publish-manifest`, `build-and-push-play`, `build-and-push-agent-host` | N/A | No local command: see [RELEASING.md](../../RELEASING.md) |

The module test rows add a suffix to the database name because each module migrates its own tables into that database, and in CI each job has its own Postgres.

CI's module jobs also run `scripts/fetch-github-release-binaries.sh tailwind` before `mix tailwind.install`. That script handles Linux targets only and exits 1 on macOS, where `mix tailwind.install` downloaded the binary by itself. The rows above leave it out.

The duplicate timestamp check, from the repo root, prints nothing when it passes:

```bash
ls apps/*/priv/repo/migrations/*.exs | xargs -n1 basename | cut -d_ -f1 | sort | uniq -d
```

The with-Play bundle guard, from `apps/platform/assets`, after the `apps/burrow_release` rows:

```bash
BURROW_EXTENSIONS_JS="$(cd ../../burrow_release && pwd)/assets/generated/extensions.js" node --test test/no_excalidraw_in_app_bundle_test.mjs test/no_emoji_data_in_app_bundle_test.mjs
```

The agent host command, from the repo root, needs Docker. It is the command CI runs. Use it in place of a local bun: bun 1.3.12 could not read `bun.lock`, and rewrote the file.

```bash
docker run --rm -v "$PWD/services/agent-host:/src:ro" ghcr.io/getburrowing/bun:1@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d sh -c 'cp -r /src /w && cd /w && bun install --frozen-lockfile && bunx tsc --noEmit && bun test test/unit.test.ts test/legacy.test.ts test/no_suite_env_names.test.ts'
```

The installer command, from the repo root, needs Docker and uses CI's image. The tests need Python 3.11 or newer for `tomllib`. Run directly on macOS with Python 3.12, 4 of the 521 tests failed; two of those trip on macOS's `sha256sum` and one on its `/var` symlink.

```bash
docker run --rm -v "$PWD:/repo:ro" -w /repo -e PYTHONPATH=deployment/installer -e PYTHONDONTWRITEBYTECODE=1 ghcr.io/getburrowing/python:3.12-slim@sha256:5b8b1421ccb6a525860a77863c049eab5847076cda34e030c75a80c58faf3f3c python3 -m unittest discover -s deployment/installer/tests
```

## A second checkout on a free port

Port 4000 belongs to the first server you start. The helpers in [`skills/suite-dev-server`](../../skills/suite-dev-server/SKILL.md) pick a free port from 4001 to 4099 and run the server in the background. Read that skill for its other options, and take versions from this guide, since the skill names an older toolchain.

`start-server.sh` runs `mix ecto.migrate` but does not create the database, so create it first. It also leaves the JavaScript dependencies to you. From the root of the second checkout, with `PLATFORM_DEV_DATABASE` set as above:

```bash
cd apps/platform/assets
npm ci
cd ..
mix deps.get
mix ecto.create
cd ../..
PORT=$(skills/suite-dev-server/scripts/start-server.sh "$(pwd)")
skills/suite-dev-server/scripts/wait-for-server.sh "$PORT"
curl -sSI "http://localhost:$PORT/dev/login"
skills/suite-dev-server/scripts/stop-server.sh "$PORT"
```

`curl` should print `HTTP/1.1 302 Found`. The server log is at `/tmp/suite-dev-<port>.log`.

## Makefile targets

Run these from the repo root. `make help` lists all the targets, including some this guide does not cover.

| Command | What it does | Notes |
|---|---|---|
| `make help` | Lists the targets | N/A |
| `make db` | Starts Postgres 16 in a Docker container | Needs port 5432 free, or a container already running under the same name |
| `make setup` | Installs Hex and Rebar, then runs `mix setup` | Run `npm ci` in `apps/platform/assets` first: without it the JavaScript build exits with an error |
| `PORT=4097 make server` | Runs `mix phx.server` on the chosen port | Stop it with Ctrl-C |
| `make format` | Runs `mix format` in `apps/platform` | Rewrites files in place |
| `make test` | Runs `mix test` in `apps/platform` | The whole default suite, without the tests tagged `slow` |

## Git hook

```bash
./scripts/setup-git-hooks.sh
```

This points git at `.githooks`. The tracked `pre-commit` hook refuses commits on a branch named `gitbutler/workspace` and otherwise does nothing. A badly formatted Elixir file committed through it stayed badly formatted. Run `make format` yourself before you commit, because `mix format --check-formatted` fails CI.
