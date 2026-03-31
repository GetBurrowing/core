---
name: suite-dev-server
description: Start and manage an ephemeral Startup Suite Phoenix development server from any `core` worktree for in-review validation, screenshots, and browser proof. Use when an agent needs to run the exact code from its own worktree on a free local port, wait for `/dev/login`, validate the feature in the browser, and shut the server down cleanly afterward.
---

# Suite Dev Server

Use this skill during `in_review` work whenever a UI task needs real browser validation or screenshots from the agent's own worktree.

All worktrees share the same `platform_dev` database. That is fine for additive local development, but destructive migrations in feature branches are risky because they affect every worktree using that database.

## Use the helper scripts, not ad-hoc shell loops

This skill ships three scripts under `skills/suite-dev-server/scripts/`:

- `start-server.sh <worktree_path>`
- `wait-for-server.sh <port>`
- `stop-server.sh <port>`

If the task payload references `skills/...`, resolve those paths from the active workspace root.

## Lifecycle

### 1) Pick the target worktree

Use the worktree that contains the code under review, not the main checkout.

Pass the worktree root to the start script:

```bash
/Users/rock/.openclaw/workspace/skills/suite-dev-server/scripts/start-server.sh /path/to/core-worktree
```

The script accepts either the worktree root or `apps/platform`. It resolves the Phoenix app directory automatically.

### 2) Start the server

Run the start script with the exec tool and capture stdout as the chosen port.

What the script does for you:

- scan ports `4001` through `4099`
- export `MIX_ENV=dev`
- export `SECRET_KEY_BASE=dev_secret_key_base_at_least_64_chars_padding_padding_padding_padding`
- export `DATABASE_URL=${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1/platform_dev}`
- run `mix deps.get` when `_build/dev` is missing
- run `mix ecto.migrate`
- start `PORT=<port> mix phx.server` in the background
- write the PID to `/tmp/suite-dev-<port>.pid`
- print the selected port to stdout

Treat the printed port as the source of truth.

### 3) Wait for readiness

Do not open the browser immediately after startup. Wait until `/dev/login` responds successfully. In practice that may be `200` or a redirect (`302`) from the dev login flow.

```bash
/Users/rock/.openclaw/workspace/skills/suite-dev-server/scripts/wait-for-server.sh <port>
```

The wait script polls `http://localhost:<port>/dev/login` every two seconds for up to sixty seconds and prints progress dots to stderr.

If readiness fails:

1. inspect `/tmp/suite-dev-<port>.log`
2. fix the real problem
3. rerun the start and wait sequence

"The dev server is not configured for my worktree" is not a valid review outcome when this skill applies.

### 4) Validate in the browser

Once the wait script exits successfully:

1. open `http://localhost:<port>/dev/login`
2. use the dev login flow
3. navigate to the feature under review
4. capture screenshots or other evidence
5. mention the port in the evidence so reviewers know exactly what was validated

### 5) Stop the server

When validation is complete, stop only the server you started:

```bash
/Users/rock/.openclaw/workspace/skills/suite-dev-server/scripts/stop-server.sh <port>
```

The stop script first tries `/tmp/suite-dev-<port>.pid`, then falls back to the process currently listening on that port, and removes the PID file after a successful shutdown.

## Notes

- Do not default to port `4000`; another worktree may already own it.
- Do not kill unrelated Phoenix servers.
- If the browser shows old code, you probably used the wrong worktree or wrong port.
- If startup fails, read the log before guessing.
