# Startup Suite Core

An open-source, agent-native collaboration platform built with Elixir, Phoenix LiveView, and PostgreSQL.

Startup Suite is a modular business suite where AI agents are first-class participants — not bolted-on assistants. Agents join conversations, create live canvases, manage tasks, and respond to natural attention cues, all within a real-time collaborative environment.

[![CI](https://github.com/Startup-Suite/core/actions/workflows/ci.yml/badge.svg)](https://github.com/Startup-Suite/core/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

---

## Features

### Chat
Real-time messaging with channels, direct messages, group conversations, threads, reactions, pins, search, and file attachments.

### Live Canvases
Collaborative canvases embedded directly in chat — tables, dashboards, code editors, and Mermaid diagrams. Agents can create and update canvases through tool calls during conversation.

### Attention Routing
Space-level attention policies that control how agents participate:
- **Directed** — every message goes to the agent (default for DMs)
- **On-mention** — agent responds only when @mentioned (default for channels)
- **Collaborative** — agent observes and engages when it can add value (default for groups)
- **Sticky engagement** — after being summoned, the agent stays in the conversation until dismissed or the topic drifts
- **Natural language silencing** — say "quiet" or "that's all" to disengage the agent

### Agent Runtime
A built-in agent runtime with workspace bootstrapping, tool execution (shell, file I/O, web fetch, canvas operations), and configurable model backends. Agents are managed through an Agent Resources UI.

### Authentication
Pluggable OIDC authentication with a dev-mode bypass for local development.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.15+ / OTP 28 |
| Web framework | Phoenix 1.8 / LiveView 1.1 |
| Database | PostgreSQL 16 |
| CSS | Tailwind CSS 4 / DaisyUI 5 |
| JS bundler | esbuild |
| HTTP server | Bandit |
| CI | GitHub Actions |
| Container | Docker (GHCR) |

---

## Getting Started

### Prerequisites

- **Elixir** ≥ 1.15 with OTP ≥ 26
- **PostgreSQL** ≥ 14
- **Node.js** ≥ 18 (for asset tooling)

### Setup

```bash
# Clone the repository
git clone https://github.com/Startup-Suite/core.git
cd core/apps/platform

# Install dependencies
mix setup

# Start the development server
mix phx.server
```

The app will be available at [http://localhost:4000](http://localhost:4000).

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `postgres://postgres:postgres@localhost/platform_dev` |
| `SECRET_KEY_BASE` | Phoenix secret key (generate with `mix phx.gen.secret`) | Dev default provided |
| `AGENT_WORKSPACE_PATH` | Path to the agent workspace directory | — |
| `PHX_HOST` | Production hostname | `localhost` |
| `PORT` | HTTP port | `4000` |

### Dev Login

In development, visit `/dev/login` to auto-create a dev user and bypass OIDC authentication.

---

## Project Structure

```
core/
├── apps/
│   └── platform/              # Phoenix application
│       ├── lib/
│       │   ├── platform/      # Backend contexts
│       │   │   ├── accounts/  # Users and authentication
│       │   │   ├── agents/    # Agent runtime and configuration
│       │   │   ├── audit/     # Event audit log
│       │   │   ├── chat/      # Spaces, messages, canvases, attention
│       │   │   └── ...
│       │   └── platform_web/  # LiveViews, controllers, components
│       ├── priv/
│       │   └── repo/migrations/
│       └── test/
│
├── deployment/                # Deployment contracts and templates
│   ├── schema/
│   ├── templates/
│   ├── examples/
│   └── operators/
│
├── docs/
│   ├── architecture/          # System design documents
│   └── decisions/             # Architecture Decision Records
│
├── scripts/                   # Development utilities
└── .github/workflows/         # CI configuration
```

---

## Architecture

The backend is a **modular Phoenix monolith** with strong internal domain boundaries and a shared real-time transport layer.

### Domain Contexts

| Context | Responsibility |
|---------|---------------|
| `Accounts` | Users, OIDC login, sessions |
| `Chat` | Spaces, participants, messages, threads, reactions, pins, canvases, attention routing |
| `Agents` | Agent configuration, workspace bootstrapping, model providers, tool execution |
| `Audit` | Telemetry-driven event log |

### Key Design Principles

- **Deterministic automation for mechanical tasks** — routing, workflow transitions, validation gates, and tool invocation are system behavior, not LLM calls.
- **LLMs where judgment is needed** — drafting, summarization, conversational assistance, and classification where brittle rules fail.
- **Cost-conscious operation** — attention modes implicitly control spend; no user-facing budget knobs.
- **Agents as participants, not plugins** — agents join spaces, have presence, follow attention policies, and can be silenced like any other participant.

### Architecture Decision Records

Design decisions are documented in [`docs/decisions/`](docs/decisions/):

| ADR | Topic | Status |
|-----|-------|--------|
| [0001](docs/decisions/0001-repository-shape-and-boundary.md) | Repository shape and public/private boundary | Accepted |
| [0002](docs/decisions/0002-platform-domain-boundaries.md) | Platform domain boundaries | Accepted |
| [0003](docs/decisions/0003-deployment-contract-shape.md) | Deployment contract shape | Accepted |
| [0004](docs/decisions/0004-authentication-strategy.md) | Authentication strategy | Accepted |
| [0005](docs/decisions/0005-event-stream-architecture.md) | Event stream architecture | Accepted |
| [0006](docs/decisions/0006-secure-credential-vault.md) | Secure credential vault | Accepted |
| [0007](docs/decisions/0007-agent-runtime-architecture.md) | Agent runtime architecture | Accepted |
| [0008](docs/decisions/0008-chat-backend-architecture.md) | Chat backend architecture | Accepted |
| [0009](docs/decisions/0009-suite-shell-architecture.md) | Suite shell architecture | Accepted |
| [0010](docs/decisions/0010-mobile-navigation-and-agent-resources.md) | Mobile navigation and agent resources | Accepted |
| [0011](docs/decisions/0011-execution-runners-context-plane-and-run-control.md) | Execution runners and run control | Accepted |
| [0012](docs/decisions/0012-agent-driven-live-canvas-architecture.md) | Live canvas architecture | Proposed |
| [0013](docs/decisions/0013-attention-routing-and-channel-policy.md) | Attention routing and channel policy | Proposed |

---

## Testing

```bash
cd apps/platform

# Run the full test suite
mix test

# Run a specific test file
mix test test/platform/chat/conversation_test.exs

# Run tests with coverage
mix test --cover
```

CI runs on every push and pull request against `main`, using a containerized Elixir + PostgreSQL environment.

---

## Deployment

Core publishes Docker images to GitHub Container Registry. The deployment model separates the public product (this repo) from operator-specific configuration:

- **Core** defines deployment schemas, templates, contracts, and examples
- **Core Ops** (private) owns real deployment targets, secrets, and production configuration

See [`deployment/`](deployment/) for the reusable deployment contracts and examples.

### Docker

```bash
# Build locally
docker build -t startup-suite-core .

# Or pull from GHCR (after CI publishes)
docker pull ghcr.io/startup-suite/core:latest
```

---

## Development

### Git Hooks

Enable the pre-commit hook (auto-formats staged Elixir files):

```bash
./scripts/setup-git-hooks.sh
```

### Code Style

- Elixir formatting is enforced via `mix format` (pre-commit hook)
- Follow Phoenix conventions for context boundaries
- Keep LiveView render functions in the same module (no separate template files)

---

## Product Roadmap

Startup Suite is designed as multiple product surfaces over one shared platform:

| Surface | Description | Status |
|---------|-------------|--------|
| **Chat** | Real-time messaging with agent participation | Active development |
| **Tasks** | Execution-oriented task management | Planned |
| **Shell** | Suite-level navigation container | Planned |

The platform layer underneath supports: accounts, workspaces, chat, execution, experiments, review, artifacts, automations, integrations, and audit.

---

## Contributing

Contributions are welcome. Please:

1. Check existing [issues](https://github.com/Startup-Suite/core/issues) and [ADRs](docs/decisions/) before proposing large changes
2. Open an issue to discuss significant design decisions before submitting a PR
3. Ensure `mix test` passes and `mix format` has been applied
4. Keep the public/private boundary intact — no host-specific configuration in this repo

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
