# ADR 0001: Repository Shape and Public/Private Boundary

- **Status:** Accepted
- **Date:** 2026-03-13
- **Owners:** Team

## Context

Startup Suite Core is being designed as a professional, collaborative, realtime-first business platform for small teams.

Several architectural decisions are already established:

- the system should feel plain, explicit, and businesslike
- Chat ships first, but the product should not be modeled as Chat-only
- the backend should begin as a modular Phoenix monolith
- experiments, variants, promotions, reversals, review artifacts, and safe undo are first-class concerns
- deterministic automation is preferred for mechanical system behavior
- LLMs should be used where judgment or language generation is genuinely useful
- personal or host-specific operational details must not leak into the public repo

We need a repository shape that preserves those decisions from the beginning instead of retrofitting them later.

## Decision

We will use a **two-repo model**:

1. **Core** — the public product repository
2. **Core Ops** — the private operations repository

### Public repo: Core

Core owns:

- product code
- frontend surfaces
- Phoenix platform code
- shared contracts and schemas
- reusable deployment contracts
- generic deployment templates and examples
- architecture and decision documents
- CI for build, test, and artifact publication

Core must not contain:

- host-specific production values
- personal domains or private environment details
- real deployment targets
- target-specific promotion state
- operator runbooks tied to private infrastructure
- secret material

### Private repo: Core Ops

Core Ops owns:

- real deployment targets
- target-specific configuration
- release promotion records
- private networking and host-specific details
- production operator workflows
- deploy, rollback, migration, and status procedures

### Product surfaces vs platform domains

We explicitly distinguish between **product surfaces** and **platform domains**.

#### Product surfaces

These are the user-facing parts of the suite:

- **Chat**
- **Tasks**
- **Shell** (later)

#### Platform domains

These are backend capabilities inside the shared Phoenix platform:

- Accounts
- Workspaces
- Chat
- Execution
- Experiments
- Review
- Artifacts
- Automations
- Integrations
- Audit

Important clarification:

- **Tasks** is the user-facing product surface
- **Execution** is the broader platform domain underneath it

This keeps the model honest. The system underneath Tasks is not only a task list; it also owns experiments, variants, promotions, reversals, and controlled execution logic.

### Backend shape

The backend will start as a **modular Phoenix monolith** rather than separate services.

This means:

- one shared Elixir/Phoenix application
- strong internal boundaries
- shared auth, realtime transport, policy, audit, and orchestration state
- no early microservice split

### Sequencing

We will sequence work as follows:

1. build **Chat** first
2. keep **Tasks** visible as a sibling surface in the repo shape from the beginning
3. add **Shell** later as the suite-level container

### Target public repo shape

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

### Target private repo shape

```text
core-ops/
├─ targets/
│  └─ <target-name>/
│     ├─ compose/
│     ├─ env/
│     ├─ overrides/
│     ├─ releases/
│     └─ runbooks/
├─ inventories/
├─ scripts/
├─ state/
└─ secrets/
```

## Consequences

### Positive

- protects the public repo from private operational sprawl
- makes product boundaries explicit before implementation grows
- lets Chat ship first without pretending it is the whole suite
- preserves room for Tasks and Shell without premature service fragmentation
- gives experiments, reversals, and review a first-class home in the platform model
- makes deployment abstraction public and deployment instance private

### Tradeoffs

- requires discipline to avoid convenience leaks from ops into product
- adds a second repo before heavy implementation begins
- requires explicit contracts between Core and Core Ops for deployment

### Guardrails

To preserve this decision:

- do not add host-specific deploy values to the Core repo
- do not use a generic catch-all top-level `workers/` directory until a real pattern emerges
- do not collapse Tasks and Execution into one ambiguous concept
- do not treat Chat as a permanent one-surface architecture

## Follow-up

Near-term follow-up work should:

1. define the public deployment contract in `deployment/schema/`
2. describe platform domain boundaries under `docs/architecture/`
3. scaffold the Phoenix app under `apps/platform/`
4. keep deployment target instances in the private Core Ops repo
