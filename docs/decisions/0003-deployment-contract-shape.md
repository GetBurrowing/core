# ADR 0003: Deployment Contract Shape Between Core and Core Ops

- **Status:** Accepted
- **Date:** 2026-03-13
- **Owners:** Team

## Context

ADR 0001 established that Core owns the reusable deployment model while Core Ops owns real deployment instances.

ADR 0002 established the platform/domain structure inside the Phoenix application.

To perform the first real production deployment of the Phoenix scaffold, we need a clear deployment contract that answers:

- what Core must publish
- what Core Ops must provide
- which runtime values are public target metadata versus private secrets
- how a real target instance should record promotion state

Without this contract, the boundary between product repo and private ops repo will drift immediately.

## Decision

We will use a **four-part deployment contract** for each deployable application target.

### 1. Artifact contract (public, owned by Core)

Core publishes a deployable OCI image.

For the current Phoenix platform app, the artifact is:

- image: `ghcr.io/startup-suite/core`

Core is responsible for:

- building the image in CI
- tagging the image
- documenting required runtime environment variables
- documenting the container port and release startup behavior

### 2. Shared runtime contract (public shape, private instance)

Core defines the shape of runtime configuration.

For the current Phoenix scaffold, the minimum runtime contract is:

#### Non-secret values

- `PHX_SERVER`
- `PHX_HOST`
- `PORT`
- `DNS_CLUSTER_QUERY`

#### Secret values

- `SECRET_KEY_BASE`

Core may publish templates and examples for these values, but the real instance values belong in Core Ops.

### 3. Route contract (public shape, private instance)

Core defines the shape of route metadata, but Core Ops owns the real live route.

The current target shape records:

- deploy target name
- public fqdn
- public scheme
- upstream service name
- upstream port
- healthcheck URL

### 4. Promotion contract (private instance)

Core Ops records what artifact is promoted to a real target.

For the current target, this is represented by:

- image reference
- promotion channel
- promotion ref

This promotion state remains private because it describes the real deployed instance.

## Contract file roles

### In Core (public repo)

Core should define the contract shape in reusable form under `deployment/`:

- `deployment/schema/` — contract documentation and field definitions
- `deployment/templates/` — reusable env templates and examples
- `deployment/examples/` — safe, non-personal examples only

### In Core Ops (private repo)

Core Ops should instantiate that contract under real targets:

- `targets/<target>/env/` — non-secret target runtime values
- `targets/<target>/overrides/` — route and target-specific metadata
- `targets/<target>/releases/` — promoted artifact state
- `secrets/<target>/` — local or private secret material
- `targets/<target>/compose/` — target-specific compose wiring
- `targets/<target>/runbooks/` — target-specific operator procedures

## LiveView posture

The platform should prefer **Phoenix LiveView wherever possible**.

Implication for deployment:

- the first deployment should optimize for a simple Phoenix release behind a reverse proxy
- no separate SPA hosting layer is required for the first surface
- server-rendered realtime behavior is the default posture unless a later surface has a clear reason to diverge

## Consequences

### Positive

- keeps the public/private boundary explicit during deployment work
- makes each deployment a concrete instance of a reusable model
- reduces the chance of host-specific drift leaking into Core
- gives future targets the same shape from the beginning
- matches the LiveView-first deployment posture with a simple release model

### Tradeoffs

- introduces more explicit files than a single ad hoc compose setup
- requires discipline to keep templates in Core and instances in Core Ops
- promotion state becomes an intentional operational concern instead of an implicit one

## Guardrails

To preserve this decision:

- do not commit real secrets to Core
- do not commit real host-specific values to Core
- do not move promotion state into the public repo
- do not let Core Ops become the home for reusable product deployment logic

## Follow-up

Near-term follow-up work should:

1. publish the current deployment contract in `deployment/schema/`
2. add reusable runtime templates in `deployment/templates/`
3. tighten the Core Ops target validator to include the full target shape
4. attempt the first production deployment of the Phoenix scaffold using this contract
