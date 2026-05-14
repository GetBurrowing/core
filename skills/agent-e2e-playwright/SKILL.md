---
name: agent-e2e-playwright
description: Run the `e2e/` Playwright suite against a freshly-started Suite dev server in any `core` worktree. Composes `suite-dev-server` (free-port server + migrations) with per-worktree asset builds and the version-pinned Playwright + Chromium under `e2e/node_modules`. Use when an agent needs browser-level proof — phx-click hooks firing, LiveView state transitions, JS-owned DOM subtrees — and the existing `e2e/README.md` doesn't apply because the worktree isn't running on port 4000.
---

# Agent e2e (Playwright)

This skill is the agent-facing wrapper around the `e2e/` Playwright suite. It
exists because the suite's own `README.md` assumes a single dev server already
running on port 4000 — which is rarely true on a multi-worktree dev machine, and
never true when a review subagent is dropped into a fresh worktree.

The one-shot wrapper script handles the wiring; this doc explains what it does
and how to run it by hand when something fails.

## TL;DR — one command

```bash
cd <worktree>                     # e.g. ~/projects/core-task-09
scripts/run-e2e.sh tests/chat_reactions.spec.ts
```

What it does, in order:

1. Picks a free port in `4001-4099` and starts `mix phx.server` in the
   background. (Delegates to `skills/suite-dev-server/scripts/start-server.sh`.)
2. Waits for `/dev/login` to respond.
3. Builds `apps/platform/assets/` if `priv/static/assets/js/app.js` is missing.
4. Runs `npm install` in `e2e/` if `node_modules` is missing.
5. Runs `npm run install-browsers` (idempotent — no-op if the right Chromium
   revision is already cached).
6. Runs `playwright test <args>` with `BASE_URL=http://localhost:<port>`.
7. Stops the dev server on exit, even if tests fail or you Ctrl-C.

Without arguments it runs every spec. Common invocations:

```bash
scripts/run-e2e.sh                              # all specs
scripts/run-e2e.sh tests/chat_reactions.spec.ts # one spec
scripts/run-e2e.sh --headed                     # see the browser
scripts/run-e2e.sh --grep "double-tap"          # filter by name
scripts/run-e2e.sh tests/meeting_av.spec.ts     # needs LIVEKIT_* env (see below)
```

## Prereqs (one-time per machine)

The wrapper assumes the host already has the toolchain documented in
[`../suite-dev-server/SKILL.md`](../suite-dev-server/SKILL.md):

- **Postgres 16** running locally (or `docker compose up -d postgres`).
- **Erlang/OTP 27+ and Elixir 1.19+** on `PATH` (asdf or Homebrew).
- **Node 20+** on `PATH` for the Playwright runner and the asset bundler.

There is no separate "install Playwright" step — the wrapper runs
`npm run install-browsers` from `e2e/` on every invocation. That command pulls
the **exact** Chromium revision pinned to the Playwright version in
`e2e/package.json` and exits in milliseconds if it's already cached. This is the
key version-matching guard: it eliminates the most common agent failure where
the global `playwright` CLI on `PATH` is one minor newer than the
`e2e/node_modules` version and the cached browser doesn't match either.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `WORKTREE` | `$PWD` | Worktree path. Pass this when invoking from outside the worktree. |
| `PHX_BIND_IP` | `127.0.0.1` | Server bind address. Set `0.0.0.0` to expose on LAN. |
| `E2E_SKIP_ASSETS=1` | unset | Skip the asset-rebuild check (faster on warm runs). |
| `E2E_SKIP_INSTALL=1` | unset | Skip `npm install` + `install-browsers` (faster on warm runs). |
| `LIVEKIT_URL` / `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | unset | Required only for `meeting_av.spec.ts`. Pulled from your shell env. |

## What it does not do

- **Does not seed the dev DB.** Specs create their own alice/bob slugs and
  unique message bodies; collisions across runs are intentional and handled in
  the specs themselves. If you need a populated dev DB for visual review,
  run `mix run priv/repo/seeds/dev_federation_seed.exs` manually.
- **Does not run Phoenix integration tests** (`mix test`). Those exercise
  LiveView server-side; this wrapper covers browser-only paths only.
- **Does not handle the "stale build" silent-failure case** where assets exist
  but `window.liveSocket` never connects. See "Common failures" below.

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERROR: $WORKTREE does not look like a core checkout` | Ran from outside a worktree without setting `WORKTREE`. | `cd` into the worktree, or pass `WORKTREE=/path/to/worktree`. |
| `Phoenix failed to stay running` | Postgres not reachable, or migrations failed. | Check `/tmp/suite-dev-<port>.log`. |
| Playwright "browser not found" / wrong revision | `npm run install-browsers` was skipped via `E2E_SKIP_INSTALL=1` on a cold cache. | Unset `E2E_SKIP_INSTALL` and rerun. |
| Specs time out waiting for LV reactions, no JS errors | "Silent stale build" — `priv/static/assets/` is from a different worktree's source tree. | Use the diagnostic helper if available: `~/saru-tools/build-worktree-assets.sh --port <port>`. Or simply `rm -rf apps/platform/priv/static/assets && rerun`. |
| `meeting_av.spec.ts` fails immediately | LiveKit creds missing from the dev server's env. | Export `LIVEKIT_URL`/`LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` *before* running, so the wrapper inherits them and passes them to `mix phx.server`. |

## Doing it by hand

When the wrapper fails partway through and you want to drive each step yourself,
this is what it expands to:

```bash
cd <worktree>

# 1. start
PORT=$(skills/suite-dev-server/scripts/start-server.sh "$PWD")
skills/suite-dev-server/scripts/wait-for-server.sh "$PORT"

# 2. assets (only if priv/static/assets/js/app.js is missing)
(cd apps/platform/assets && npm install)
(cd apps/platform && mix assets.build)

# 3. e2e deps + browsers (only if missing)
(cd e2e && npm install && npm run install-browsers)

# 4. run
BASE_URL="http://localhost:$PORT" \
  e2e/node_modules/.bin/playwright test tests/chat_reactions.spec.ts

# 5. stop
skills/suite-dev-server/scripts/stop-server.sh "$PORT"
```

Trace artifacts from failed runs land in `e2e/test-results/`. Open them with:

```bash
cd e2e && node_modules/.bin/playwright show-trace test-results/.../trace.zip
```

## Why a wrapper at all

The pieces below already existed — this skill just makes the chaining a single
command:

- `skills/suite-dev-server` provides per-worktree start/stop/wait.
- `e2e/` has the Playwright config, specs, and `install-browsers` script.
- `apps/platform` knows how to build its own assets via `mix assets.build`.

What was missing was the single entry point an agent could invoke without
needing to discover and assemble those three independently. That's all this is.
