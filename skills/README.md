# Skills

This directory contains **filesystem skills** intended to be picked up by federated
agents that participate in the Suite task lifecycle. Each skill is a self-contained
folder describing a specific capability — running a local Suite, driving a browser,
posting evidence into a canvas — with the helper scripts that capability needs.

These are platform-agnostic. They assume only what a contributor of the open-source
project would have: a Unix-like or Windows shell, common package managers, and the
tools the skill itself documents how to install. They do **not** assume any
particular deployment topology, container name, hostname, port, or path.

## Folder layout

Every skill is a folder:

```
skills/<skill-name>/
  SKILL.md            — canonical documentation. Frontmatter (name, description) + prose.
  scripts/            — small, single-purpose helper scripts referenced by SKILL.md.
  examples/           — optional: invocation samples and expected output.
```

The `description` in the frontmatter is what surfaces in skill listings to agents.
Make it concrete enough that an agent can decide whether the skill applies.

## How agents pick these up

Two channel plugins federate Claude-style agents into Suite spaces:

- `Startup-Suite/openclaw-suite-channel` — bridges OpenClaw agent runtimes.
- `Startup-Suite/claude-code-suite-channel` — bridges Claude Code sessions.

When an agent is dispatched on a task, the plugin assembles a context payload and
includes a `skills` listing. Today that listing comes from the Suite-side
`Tasks.skill_*` table; the plugins can be extended to also surface filesystem skills
from this directory so the same capabilities are available to any host running the
plugin. (Tracked as a follow-up audit task.)

## Authoring guidelines

- **Platform-agnostic.** macOS / Linux / Windows where reasonable. Call out OS
  differences explicitly with `uname` checks or platform sections. Don't bake in
  hostnames, container names, or deployment-specific paths.
- **Shippable scripts.** Helpers live under `scripts/`, are executable, set
  `set -euo pipefail` (bash) or have a clear error contract, and prefer common
  utilities (`curl`, `python3`, `docker compose`) over deployment-specific CLIs.
- **Concrete examples beat abstract advice.** Show the exact command and a sample
  of expected output.
- **No emojis** unless the example output legitimately contains them.

## Existing skills

| Skill | Purpose |
|---|---|
| `suite-dev-server` | Start a local Suite Phoenix dev server from any worktree, for in-review validation and screenshots. |
| `openclaw-isolated-gateway` | Run a sandboxed OpenClaw gateway that talks to a local Suite without touching your primary OpenClaw install. |
| `agent-chrome-cdp` | Set up a dedicated Chrome with remote debugging so agents can drive web UIs. |
| `agent-screenshot-and-canvas` | Capture a screenshot and post it as evidence into a Suite canvas + review request. |
