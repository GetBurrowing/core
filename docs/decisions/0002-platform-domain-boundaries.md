# ADR 0002: Platform Domain Boundaries and Surface Mapping

- **Status:** Accepted
- **Date:** 2026-03-13
- **Owners:** Team

## Context

ADR 0001 established the two-repo boundary and the high-level repository shape for Startup Suite Core.

The next decision is how to divide the shared Phoenix platform internally so that:

- Chat can ship first without turning into the whole architecture
- Tasks has a clear place in the product model without flattening the backend into a simple task-list concept
- experiments, variants, promotions, reversals, review artifacts, and safe undo are first-class concerns
- authentication, realtime collaboration, and audit are not treated as afterthoughts
- the system stays understandable as a modular monolith

The goal is to define a stable internal language for the platform before implementation expands.

## Decision

We will model Startup Suite Core as **product surfaces** built on top of **shared platform domains**.

## Product surfaces

The product surfaces are the user-facing entry points:

- **Chat** — first surface to ship
- **Tasks** — execution-oriented sibling surface
- **Shell** — later suite-level container for navigation across surfaces

These are the visible products users interact with.

## Platform domains

The shared Phoenix platform will be organized around these domains:

- **Accounts** — identity, authentication, membership, and user/session concerns
- **Workspaces** — team/container boundary, membership context, and collaboration scope
- **Chat** — conversations, threads, messages, participants, and realtime collaboration primitives for chat itself
- **Execution** — execution-oriented workflows, task state, orchestration, variants, promotions, reversals, and controlled automation
- **Experiments** — experiment definitions, routing, comparisons, promotion candidates, and evaluation metadata
- **Review** — approvals, human gates, feedback, and review decisions
- **Artifacts** — durable outputs, generated assets, attachments, evidence, and comparison material
- **Automations** — deterministic workflow actions, triggers, policies, and orchestration rules
- **Integrations** — external systems, connectors, tool contracts, and inbound/outbound sync points
- **Audit** — traceability, event history, operator visibility, and change accountability

## Surface-to-domain mapping

### Chat surface

The Chat surface primarily sits on top of:

- Chat
- Accounts
- Workspaces
- Audit
- Integrations

It may also touch Experiments, Review, and Artifacts where needed.

### Tasks surface

The Tasks surface primarily sits on top of:

- Execution
- Experiments
- Review
- Artifacts
- Automations
- Audit

This is why **Tasks** must not be treated as the backend domain name.

The backend capability is broader than tasks alone. It includes experimentation, reversibility, controlled execution, and human review.

### Shell surface

The Shell surface primarily sits on top of:

- Accounts
- Workspaces
- Audit

It acts as the suite-level navigation and composition layer across surfaces.

## Naming rule

We explicitly keep this distinction:

- **Tasks** = product surface
- **Execution** = backend/platform domain

This naming rule prevents the backend architecture from collapsing into UI terminology.

## Cross-cutting principles

The following principles apply across all domains:

1. **Deterministic first** for mechanical system behavior
2. **LLMs only where they add real value**
3. **Realtime collaboration is a first-class concern**
4. **Human review remains authoritative**
5. **Reversibility and auditability are part of the design, not cleanup work**

## Initial implementation implication

The existing Phoenix app is already bootstrapped under:

- `apps/platform/lib/platform`
- `apps/platform/lib/platform_web`

We will preserve that application namespace for now and scaffold the domain boundaries inside it rather than renaming the bootstrapped app prematurely.

That means the near-term shape should look conceptually like:

```text
apps/platform/lib/platform/
├─ accounts/
├─ workspaces/
├─ chat/
├─ execution/
├─ experiments/
├─ review/
├─ artifacts/
├─ automations/
├─ integrations/
└─ audit/
```

And the web layer should remain capable of supporting multiple surfaces over time:

```text
apps/platform/lib/platform_web/live/
├─ chat/
├─ tasks/
└─ shell/
```

## Consequences

### Positive

- gives the platform a stable internal language early
- lets Chat ship first without distorting the full product model
- preserves room for Tasks and Shell as real surfaces
- gives experimentation, review, and reversibility first-class homes
- keeps the modular monolith understandable and evolvable

### Tradeoffs

- introduces architectural vocabulary before full implementation exists
- requires discipline to keep product-surface language distinct from backend-domain language
- may lead to some empty directories or placeholder boundaries early on

### Guardrails

To preserve this decision:

- do not rename the backend domain to `tasks`
- do not put cross-cutting review/experiment logic directly into Chat or Tasks UI folders
- do not treat audit as optional
- do not collapse automations into vague LLM-driven behavior when deterministic workflow is sufficient

## Follow-up

Near-term follow-up work should:

1. scaffold the empty domain directories in the Phoenix app
2. scaffold the corresponding LiveView surface folders
3. add architecture notes describing responsibilities and boundaries for each domain
4. keep future implementation aligned to these names unless a later ADR explicitly changes them
