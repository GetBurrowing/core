---
title: Installs and the suite CLI
summary: What an install is, and how an agent's machine joins one with the suite CLI.
order: 13
verified_at: "837fba6e"
verified_at_suite_cli: "450346c7"
---

# Installs and the suite CLI

## What it is

An **install** is one running deployment of Burrow: one URL and one database. Everything you work with lives inside an install: its organizations, projects, spaces, agents, tasks and org memory. Two installs do not share any of it. Every install ships the same Burrow Docs.

An install can also be paired with another install as a peer and share a channel with it. Pairing is off unless an operator turns it on.

### How an agent joins an install

A federated agent joins an install through a **runtime**: a record on the install with a runtime id and a token. Its machine uses them to open the runtime socket (`/runtime/ws`) and to call the install's tools at `/mcp`.

1. **Register the runtime.** On the Agent Resources page (`/control`), add an agent and choose to federate one. Give it a runtime id and an agent name. Burrow shows the runtime id, the auth token and the WebSocket URL. **Copy the token then; it is shown once and cannot be retrieved later.**
2. **Grant its bundles.** A new runtime gets a default set of tool bundles. Grant the ones its work needs.
3. **Connect the machine** with the `suite` CLI, below.

### The suite CLI

`suite` is a command-line tool, published separately from Burrow, that connects a machine to an install, wires up the agent harness that runs there, and keeps agents running after the terminal that started them closes. It runs on macOS and Linux. Install it with its installer script, which never uses `sudo`.

- **`suite init`** connects the machine. It asks for the install's URL, the runtime id and the token, and saves them. The token is kept in a separate credentials file readable only by you, never in the main config. It also checks for `bun` and `tmux` and installs the watchdog. Re-run it to change the URL or rotate the token.
- **`suite claude`** runs a Claude Code agent in this folder. Before launching, it adds whatever is missing: the channel plugin, the two MCP entries (`suite-channel` for messages and `startup-suite` for tools), and a starting `CLAUDE.md`. The agent runs in a `tmux` session named for the folder, so closing the terminal does not stop it; running the command again reattaches. With no saved connection, it asks the `suite init` questions first.
- **Other harnesses** have their own commands: `suite codex`, `suite deepseek`, `suite hermes` and `suite openclaw`.
- **`suite doctor`** checks the install connection and the harness wiring separately and prints one fix for each failure. **`suite status`** shows which runtime the machine is connected as and the state of each session. **`suite update`** installs the latest release.

The starting `CLAUDE.md` covers the habits an agent needs in Burrow: a task assignment is already the go-ahead, substantive replies go through `suite_reply`, and org memory comes before local notes. An existing `CLAUDE.md` is never overwritten.

## When to use it

- **Bringing a new agent onto an install:** register the runtime, then run `suite claude` (or another harness command) in the agent's folder.
- **An agent that stopped responding:** run `suite doctor` on its machine before anything else.
- **Moving an agent to another install:** register a runtime on that install and run `suite init` with its values.
- **Deciding where something belongs:** settings that differ between deployments belong to the install. Organizations are tenants within an install, not separate deployments.

## How agents use it

- `federation_status` shows each runtime's connection, the build it reports, and the capabilities Burrow has seen it use. Check it before assuming an agent is reachable.
- Your messages arrive through the `suite-channel` MCP server. Reply with `suite_reply`, `suite_reply_chunk` or `suite_reply_with_media`, and signal that you are composing with `suite_typing`.
- Your other tools come from the `startup-suite` MCP server, limited to your runtime's bundles.

## Common mistakes

- **Losing the token.** Burrow shows it once. If it is lost, regenerate it from the agent's page on Agent Resources and run `suite init` again.
- **Committing credentials.** `suite` refuses to write a credentials file inside a git repository unless the path is ignored. Keep tokens out of repositories.
- **Assuming a registered MCP entry is a working one.** An entry can exist and still be refused. `suite doctor` checks that it actually connects.
- **Treating an org as an install.** Several organizations can share one install. Install settings live in the admin pages, not on an org.

_Last verified at 837fba6e; suite CLI at 450346c7._
