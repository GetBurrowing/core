# Core

Core is the **public product repository** for Startup Suite.

## Local git hooks

This repo ships a versioned pre-commit hook that auto-runs `mix format` for staged
Elixir/HEEx files under `apps/platform`.

Enable it once per clone with:

```bash
./scripts/setup-git-hooks.sh
```

That configures:

- `core.hooksPath=.githooks`
- executable `.githooks/pre-commit`

The hook formats only staged `apps/platform/**/*.ex`, `*.exs`, and `*.heex` files,
then re-stages them before the commit continues.

It holds the open-source application code, shared contracts, architecture decisions, and the reusable deployment model for the suite.

It does **not** hold personal infrastructure details, host-specific production configuration, real deployment targets, or operator-specific workflows.

Those belong in the companion private repository: **Core Ops**.

---

## Product stance

Core is being designed to feel like a professional business suite:

- clear names over cute names
- explicit structure over magic
- clean, restrained Elixir/Phoenix architecture
- deterministic automation wherever possible
- LLMs only where they add real value
- cost-conscious operation as a first-class concern

The target feel is plain, disciplined, and unsurprising.

---

## Product model

Startup Suite is being designed as **multiple product surfaces over one shared platform**.

### Product surfaces

These are the user-facing parts of the suite:

- **Chat** — the first surface to be built and shipped
- **Tasks** — the execution-oriented sibling surface
- **Shell** — the later suite-level container for navigation across surfaces

### Platform domains

These are the backend capabilities that power the surfaces:

- Accounts
- Workspaces
- Chat
- **Execution**
- Experiments
- Review
- Artifacts
- Automations
- Integrations
- Audit

Important distinction:

- **Tasks** is the product surface
- **Execution** is the broader platform/domain capability underneath it

That separation keeps the backend model honest: execution is larger than task lists, because it also covers experiments, variants, promotions, reversals, review, and controlled automation.

---

## Sequencing

Current sequencing remains:

1. build **Chat** first
2. keep **Tasks** visible as a real sibling surface from the beginning
3. add **Shell** later as the suite-level container

This avoids designing Chat as a dead-end one-off while still keeping first delivery focused.

---

## Backend architecture

The backend should begin as a **modular Phoenix monolith**.

That means:

- one shared Elixir/Phoenix backend
- strong internal domain boundaries
- shared auth, realtime transport, audit, orchestration state, and policy
- no premature split into services

The goal is to preserve conceptual modularity without paying distributed-systems cost too early.

---

## Automation philosophy

Core should prefer deterministic system behavior for mechanical work:

- routing
- workflow transitions
- validation gates
- promotion and reversal flows
- tool invocation
- policy and permission enforcement
- deployment orchestration steps where the rules are known

LLMs should be used where judgment or language generation is genuinely helpful:

- drafting
- summarization
- extraction
- planning support
- conversational assistance
- classification where brittle rules are a bad fit

The system should not depend on LLMs as hidden glue for simple control flow.

---

## Repository boundary

This repository is intentionally scoped to the **public product** and the **reusable system model**.

### This repo should contain

- application code
- frontend code
- shared contracts and schemas
- reusable deployment contracts
- generic templates and examples
- architecture and decision documents
- CI for build, test, packaging, and artifact publication

### This repo should not contain

- host-specific production values
- personal domains or private environment details
- real deployment targets
- production secret material
- operator-specific workflows
- private promotion state

Those belong in **Core Ops**.

---

## Relationship to Core Ops

The boundary is simple:

- **Core defines the deployment model**
- **Core Ops owns deployment instances**

In practice:

- Core defines schemas, templates, contracts, and examples
- Core Ops defines real targets such as `production`
- Core may publish artifacts
- Core Ops chooses, promotes, and deploys those artifacts

This boundary is intentional and should remain permanent.

---

## Target repository shape

This is the intended target shape of the public repo:

```text
core/
├─ apps/
│  └─ platform/
│     ├─ lib/
│     │  ├─ core/
│     │  │  ├─ accounts/
│     │  │  ├─ workspaces/
│     │  │  ├─ chat/
│     │  │  ├─ execution/
│     │  │  ├─ experiments/
│     │  │  ├─ review/
│     │  │  ├─ artifacts/
│     │  │  ├─ automations/
│     │  │  ├─ integrations/
│     │  │  └─ audit/
│     │  └─ core_web/
│     ├─ priv/
│     └─ test/
│
├─ frontends/
│  ├─ chat/
│  ├─ tasks/
│  └─ shell/
│
├─ packages/
│  ├─ ui/
│  ├─ contracts/
│  └─ deployment-contracts/
│
├─ deployment/
│  ├─ schema/
│  ├─ templates/
│  └─ examples/
│
├─ docs/
│  ├─ architecture/
│  └─ decisions/
│
└─ .github/
   └─ workflows/
```

### Notes on shape

- `apps/platform/` is the shared Phoenix application
- `frontends/` holds user-facing surfaces
- `packages/` holds reusable cross-surface assets and contracts
- `deployment/` stays generic and reusable
- avoid a generic top-level `workers/` catch-all until a real pattern emerges

---

## Current repository status

Right now, this repository is still an **early design scaffold**.

That means the repo should currently be treated as the source of truth for:

- public architecture decisions
- boundary definitions
- platform shape
- naming and modularity rules
- deployment abstraction design

It should **not** pretend implementation is further along than it is.

---

## How to continue the design correctly

If you are continuing the design:

1. preserve the public/private boundary with Core Ops
2. keep naming plain and explicit
3. treat Chat as first delivery, not as the whole product
4. keep Tasks visible as a sibling surface
5. model **Execution** as the underlying platform domain
6. keep experiments, variants, review, and reversals first-class
7. keep deployment abstractions generic and reusable
8. do not leak host-specific reality into this repo

---

## Immediate next design moves

Near-term work in this repo should focus on:

- locking the domain and repository boundaries
- defining the Phoenix app structure
- documenting the public deployment contract
- clarifying how Chat, Tasks, and Shell relate
- describing how experiments and reversals fit the platform model

---

## Status

This repository is currently an initial public scaffold for Startup Suite Core.

The primary job of the repo today is to make the architecture, boundaries, and future module structure explicit before implementation expands.
