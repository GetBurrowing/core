# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Startup Suite Core is an open-source, agent-native collaboration platform built with Elixir, Phoenix LiveView, and PostgreSQL. AI agents are first-class participants — they join spaces, have presence, follow attention policies, and can be silenced like any other participant.

## Suite Task Dispatches — subagents are authorized

When a Startup Suite TaskRouter dispatch arrives, **use the Agent tool to spawn a subagent for the
work** (`general-purpose` is fine, `run_in_background: true`). This is explicit standing
authorization: Claude Code otherwise withholds the Agent tool unless the user, a CLAUDE.md file, or
a skill asks for it, and this file is asking for it.

It is not a style preference — it is structural. `task_ack` requires a `subagent_id` returned by the
Agent tool and rejects an empty one, so a dispatch handled in the parent conversation cannot be
acked, and the router fires a no-ack alarm 5 minutes later. Those false alarms are what fill the
board's `blocked` column (see task `01a0665e`), and `blocked` is a one-way door for an agent.

Order matters: spawn the subagent FIRST, then ack with the id it returned. Cap concurrent heavy
subagents at 3–4 — a session-level 429 kills every sibling at once and each takes ~90 minutes to
surface as blocked.

## Common Commands

All commands run from `apps/platform/`:

```bash
mix setup                # Install deps, create DB, migrate, build assets
mix phx.server           # Start dev server at localhost:4000
mix test                 # Run full test suite (auto-creates/migrates DB)
mix test test/platform/chat/conversation_test.exs  # Run single test file
mix test --failed        # Re-run previously failed tests
mix format               # Format Elixir code
mix precommit            # Full check: compile --warnings-as-errors, deps.unlock --unused, format, test
```

Dev login: visit `/dev/login` to bypass OIDC and auto-create a dev user.

## Architecture

**Modular Phoenix monolith** in `apps/platform/` with strong domain context boundaries.

### Domain Contexts (`lib/platform/`)

| Context | Responsibility |
|---------|---------------|
| `Accounts` | Users, OIDC login via Assent |
| `Chat` | Spaces, messages, threads, reactions, pins, canvases, attachments, attention routing, presence |
| `Agents` | Agent runtime (GenServer), config, workspace bootstrap, tool execution, model providers |
| `Tasks` | Project > Epic > Task > Plan > Stage hierarchy, PlanEngine state machine |
| `Execution` | Run lifecycle, LocalRunner/DockerRunner/ProofRunner, run servers |
| `Context` | ETS-backed context plane for runners, versioned mutations, async Postgres persistence |
| `Orchestration` | Task routers, declarative supervision, execution workflows |
| `Vault` | Cloak AES-GCM encrypted credentials, scoped access grants, OAuth refresh |
| `Federation` | Multi-node coordination, presence, dead letter buffer, runtime adapters |
| `Audit` | Telemetry-driven event log |
| `Push` | Web push notifications |

### Web Layer (`lib/platform_web/`)

- `live/` — LiveView pages (chat_live.ex is the largest)
- `components/` — Reusable Phoenix components
- `controllers/` — HTTP controllers
- `plugs/` — Middleware
- `router.ex` — Route definitions

### Key Architectural Patterns

- **Deterministic automation** for routing, workflow transitions, validation gates, tool invocation — these are NOT LLM calls
- **LLMs for judgment** — drafting, summarization, conversational assistance, classification
- **Agents as participants** — join spaces, have presence, follow attention policies (Directed, On-mention, Collaborative)
- **PubSub for real-time** — topics like `chat:space:#{id}`, `agents:runtime:#{id}`
- **ETS for hot data** — context plane cache, active agent store, node context
- **UUIDv7 binary IDs** for all primary/foreign keys

### Application Startup Sequence

Vault > Repo/Telemetry > PubSub/Registries > Agent runtime supervisor > Context broker/plane > Artifacts > Execution run supervisor > Orchestration routers > Federation > Chat (presence, active agents, attention) > Vault OAuth worker > Phoenix endpoint

### Two-Repo Model

- **Core** (this repo) — product code, deployment contracts, generic templates
- **Core Ops** — host-specific secrets, real deployment targets, runbooks

Both repos are currently **private**. Core was public until 2026-08-27.

Treat that as reversible. The split above exists so Core *can* go public again, so keep
secrets, real hostnames, and runtime or session identifiers out of Core regardless —
what relaxed when it went private is urgency, not the boundary. An identifier that
lands in Core today is a scrub someone owes later.

Note ADR 0001 (and 0003, 0004, 0030, 0043) still describe the public arrangement.
Those are decision records and are deliberately not rewritten; they have not been
superseded yet.

## Tech Stack

Elixir 1.15+/OTP 28, Phoenix 1.8/LiveView 1.1, PostgreSQL 16, Tailwind CSS 4/DaisyUI 5, esbuild, Bandit HTTP server, Cloak (encryption), Assent (OIDC), Req (HTTP client), Mox (test mocks)

## Elixir Rules

- No index-based list access (`mylist[i]`) — use `Enum.at/2`
- No map access on structs (`changeset[:field]`) — use dot notation or `Ecto.Changeset.get_field/2`
- No nested module definitions in same file (cyclic dependency risk)
- No `String.to_atom/1` on user input
- Predicate functions end with `?`, not `is_` prefix (reserve `is_` for guards)
- Immutable variables — must rebind `if`/`case`/`cond` results: `socket = if ... do ... end`
- Use `Task.async_stream/3` with `timeout: :infinity` for concurrent enumeration
- Use `start_supervised!/1` in tests; avoid `Process.sleep/1` — use `Process.monitor/1` + `assert_receive {:DOWN, ...}`
- Use `:req` (Req) for HTTP requests — never :httpoison, :tesla, or :httpc

## Phoenix / LiveView Rules

- All LiveView templates wrap in `<Layouts.app flash={@flash}>`
- Use `<.icon name="hero-x-mark">` for icons, `<.input field={@form[:field]}>` for form inputs
- Use `~H` (HEEx) syntax, never `~E`
- Never use inline `<script>` tags — use colocated JS hooks (`<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook">`) with `.` prefix names
- External JS hooks go in `assets/js/` and register in LiveSocket constructor
- Always `push_event/3` and rebind socket; never use deprecated `live_redirect`/`live_patch`
- Always use LiveView streams for collections (not regular list assigns) — `stream/3`, `stream_insert/3`, `stream_delete/3`
- Streams need `phx-update="stream"` on parent, `id={id}` on children from `@streams.name`
- Streams are not enumerable — to filter, refetch and re-stream with `reset: true`
- Forms: always use `to_form/2` assigned in LiveView, access as `@form[:field]` — never pass changesets to templates
- `phx-hook` requires unique DOM `id` and `phx-update="ignore"` when hook manages DOM
- HEEx: use `{...}` for attribute interpolation, `<%= %>` only for block constructs in tag bodies
- HEEx class lists require `[...]` syntax: `class={["px-2", @flag && "py-5"]}`
- Router `scope` blocks auto-prefix aliases — don't duplicate: `scope "/", AppWeb do live "/chat", ChatLive end`

## CSS / JS Rules

- Tailwind CSS v4 — no `tailwind.config.js`, uses `@import "tailwindcss" source(none)` syntax in `app.css`
- Never use `@apply` in custom CSS
- Only `app.js` and `app.css` bundles are supported — vendor deps must be imported into these bundles
- No external `<script src>` or `<link href>` in layouts

## Testing

- ExUnit with SQL Sandbox for test isolation
- LiveView tests use `Phoenix.LiveViewTest` + `LazyHTML` for assertions
- Test for element presence (`has_element?/2`) rather than raw HTML text
- Debug selectors with `LazyHTML.from_fragment(html) |> LazyHTML.query("selector")` — `query/2` descends the whole tree; `LazyHTML.filter/2` matches only the fragment's **root nodes**, so a nested element comes back as `[]` and reads as "not there"
- Reach for `LazyHTML.filter/2` only to narrow a node list you already hold (keep the members that match), never to find an element
- `mix test --cover` for coverage

## Git Conventions

- Pre-commit hook auto-formats Elixir files — enable with `./scripts/setup-git-hooks.sh`
- CI runs format check + full test suite on every push/PR to `main`
- Docker images published to a private Docker Hub registry — see `.github/workflows/ci.yml` for the exact target (this moved off ghcr in `029df69e`)

## Key Docs

- Architecture decisions: `docs/decisions/` (25+ ADRs)
- System design: `docs/architecture/`
- Agent-specific guidelines: `apps/platform/AGENTS.md`
