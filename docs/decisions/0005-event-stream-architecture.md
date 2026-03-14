# ADR 0005: Event Stream Architecture

## Status

Accepted

## Context

The platform needs a consistent, idiomatic mechanism for capturing what happens
across every domain — auth, chat, execution, experiments, and future modules.
This mechanism must serve multiple consumers from a single emission point:

- **Audit**: Who did what, when, from where
- **Observability**: Metrics, tracing, anomaly detection
- **Replay**: Reconstruct sequences of events for debugging or analysis
- **Functional state derivation**: Derive current state by folding over events

Elixir provides strong primitives for this: Telemetry for emission, Streams for
lazy enumeration, `Enum.reduce/3` for state derivation, and pattern matching for
routing. The architecture should lean on these rather than introducing a CQRS/ES
framework.

### The linked list constraint

Elixir lists are singly-linked cons cells. Prepending is O(1), appending is O(n),
and length is O(n). Any architecture that accumulates events into a list — whether
in a GenServer, a LiveView assign, or a process mailbox — will silently degrade
under load.

Known-safe alternatives for ordered event buffering:
- **`:queue`** — amortized O(1) both ends (two-list trick with lazy reversal)
- **ETS `ordered_set`** — O(log n) insert/lookup, concurrent, ordering by key
- **Don't buffer** — write-through to Postgres, stream out with `Repo.stream/2`

This decision must be encoded as a project invariant: event-processing code must
never accumulate into a plain list where the size is unbounded.

## Decision

### Events are immutable facts

Every meaningful state change in the platform is recorded as an immutable event.
Events are append-only — never updated, never deleted. The event stream is the
source of truth; current state is always derivable by folding over it.

### Telemetry is the emission standard

All events are emitted via `:telemetry.execute/3`, following the BEAM ecosystem
convention. Event names are namespaced atom lists:

```
[:platform, <domain>, <action>]
[:platform, :auth, :login]
[:platform, :auth, :logout]
[:platform, :chat, :message_sent]
[:platform, :execution, :task_transitioned]
```

Measurements carry numeric data (durations, counts). Metadata carries context
(actor, resource, IP, session, result, error reason).

This gives us zero coupling between emitters and consumers. Auth code does not
know that audit exists. Adding a new consumer (metrics exporter, anomaly detector,
webhook dispatcher) requires zero changes to emitting code.

### Postgres is the durable store

Events are persisted to an append-only `audit_events` table with:

- `id` (bigserial) — monotonic ordering key, gap-free
- `event_type` (string) — dot-namespaced: `"auth.login.success"`
- `actor_id` (uuid, nullable) — who did it (nil for unauthenticated events)
- `actor_type` (string) — `"user"`, `"system"`, `"agent"`
- `resource_type` (string) — what was affected
- `resource_id` (string) — which instance
- `action` (string) — `"create"`, `"attempt"`, `"delete"`, etc.
- `metadata` (jsonb) — event-specific payload
- `session_id` (string, nullable) — correlate events within a session
- `ip_address` (inet, nullable) — for security audit
- `inserted_at` (utc_datetime_usec) — microsecond precision

**Why bigserial, not UUID**: Events are internal, ordered, and never referenced
externally. Bigserial gives gap-free monotonic ordering, smaller indexes, faster
range scans, and trivial keyset pagination (`WHERE id > ?`).

**Why Postgres, not a dedicated event store**: We already run Postgres. For the
foreseeable event volume, a well-indexed append-only table with JSONB metadata
is sufficient. When volume demands it, add native table partitioning by month —
no application code changes required.

### Streams are the replay mechanism

Replay is `Repo.stream/2` piped through `Stream` transformations. Never
`Repo.all/2` — that materializes the entire result set into a linked list,
violating the invariant above.

```elixir
# Replay auth events for a user
Audit.stream(actor_id: user_id, event_type: "auth.*")
|> Stream.each(&process/1)
|> Stream.run()

# Export to JSONL — constant memory
Audit.stream(since: start_of_month)
|> Stream.map(&Jason.encode!/1)
|> Stream.into(File.stream!("audit.jsonl"))
|> Stream.run()
```

For paginated API access: keyset pagination on `id`. Never offset-based — offset
degrades as the table grows.

### Reduce is the state derivation pattern

Deriving state from events is a fold — the most fundamental functional operation:

```elixir
Audit.stream(resource_type: "workspace", resource_id: id)
|> Enum.reduce(initial_state, &apply_event/2)
```

Each domain defines its own `apply_event/2` to interpret events into state. This
is how replay produces state adjustment: same events, same fold, same result.
Corrective actions are new events appended to the stream, never mutations of
existing ones.

### PubSub bridges real-time consumers

On successful persist, broadcast via `Phoenix.PubSub`:

```
"audit:all"
"audit:#{event_type}"
"audit:#{resource_type}:#{resource_id}"
```

LiveView dashboards, log tailers, and alerting hooks subscribe to relevant topics.
No polling.

### Telemetry handler is the integration point

A single `Audit.TelemetryHandler` module, attached in `Application.start/2`,
bridges Telemetry → Postgres → PubSub. It:

1. Receives `[:platform, domain, action]` events
2. Builds an `AuditEvent` struct from measurements + metadata
3. Inserts via `Repo.insert/2` (v1: synchronous, direct)
4. Broadcasts via `PubSub`

This handler is the only component that touches the database. Emitting code never
imports `Audit` or calls `Repo`.

### Scaling path (documented, not implemented)

When event volume outgrows synchronous INSERT:

1. **Batch writes**: Handler casts to a GenServer that buffers in `:queue`,
   flushes every N events or M milliseconds via `Repo.insert_all/3`
2. **Table partitioning**: Postgres native partitioning by `inserted_at` month
3. **Broadway pipeline**: For consuming external event sources with back-pressure
4. **Read replicas**: Route `Audit.stream/1` queries to a read replica

Each step is additive. No emitting code changes. No schema changes.

## Consequences

- Every domain emits Telemetry events following the `[:platform, domain, action]`
  convention. This is the only contract.
- The `audit_events` table is append-only. No migration will ever add UPDATE or
  DELETE operations against it.
- Replay and state derivation use `Stream` pipelines and `Enum.reduce/3`. Code
  review should flag any `Repo.all` call against audit data.
- The linked list invariant applies project-wide: never accumulate unbounded
  event data into a plain Elixir list.
- Observability (metrics, logging) attaches to the same Telemetry events. One
  emission point, many consumers.
