# ADR 0051: TaskRouter Dispatch as a Debounced Reconcile, and Ack Durability Outside the Lease

**Status:** Accepted
**Date:** 2026-08-18
**Deciders:** Rowan
**Supersedes:** ADR 0025 (Task Router and Execution Orchestration) — dispatch-trigger and ack-liveness sections only
**Related:** ADR 0025, ADR 0011 (Execution Runners), ADR 0018 (Tasks Persistent Model and Plan Engine)

---

## Context

ADR 0025 established the task router and, in its 2026-07-15 amendment, the
event-driven lease model that replaced the polling heartbeat. Two production
incidents in August 2026 changed how dispatch is triggered and where ack state
lives. Neither change is described by ADR 0025, and both are the kind of thing
the next person extends by reading the document rather than the code.

This ADR records what shipped. ADR 0025's context assembly, payload discipline
and per-stage-kind timeout map are unchanged and still govern — only its
dispatch-trigger and ack-liveness sections are superseded.

**On why this is a new ADR rather than an edit.** ADR 0025 carries an in-place
amendment from 2026-07-15. That is history, and it stays. Going forward we do
not change decisions from the past; we make new decisions that supersede old
ones, so the record shows what was believed and when.

---

## Decision 1 — `:dispatch` is a request to reconcile, not a command to dispatch

Landed by `81a0c363` (PR #748, task `01a00587`).

Nine in-module senders each observe a genuine state change and each ask for a
dispatch. One state change therefore fans in as a burst: the `01a00571` trace
recorded **12 duplicate `:dispatch` messages inside 137ms** from a single state
change, each producing a full prompt payload.

The fix does not remove senders. Every one of them is correct — each is
reporting something real. The fix changes what the message means.

- **`:dispatch` only schedules.** Receiving it arms a `:dispatch_now` timer and
  does nothing else (`task_router.ex`, `handle_info(:dispatch, state)`).
- **If a timer is already armed, the message is DROPPED.** Not cancelled, not
  restarted, not extended. This is the non-obvious half and it is deliberate: a
  restart-on-every-message debounce can be starved indefinitely by a steady
  arrival stream, while drop-if-scheduled bounds the delay at exactly one
  window.
- **`:dispatch_now` carries no payload.** It re-reads the task and plan at fire
  time, so the FINAL state wins rather than whichever message arrived first.
  That is what makes it a reconcile rather than a queued command.
- **The window is 50ms**, `@dispatch_debounce_ms`, overridable at
  `:task_router_dispatch_debounce_ms`. It is chosen to absorb a fan-in burst
  while adding latency far below anything a human or agent perceives, and an
  order of magnitude below the 1s endpoint-not-ready retry inside
  `do_dispatch/2` — which deliberately still sends `:dispatch`, so the retry
  coalesces too.
- The pending timer ref lives in router state and is deliberately not surfaced
  through the public state.

### Consequence for anyone adding a sender

**Adding a new `send(self(), :dispatch)` is safe and needs no de-duplication at
the call site.** Send it whenever you observe a real state change. The router
coalesces.

The corollary matters more: **if dispatch volume looks high, do not go hunting
for senders to delete.** Each sender is individually correct, and removing five
of the nine converts a coalescing problem into an unverifiable completeness
problem — you would then have to prove the remaining four observe every
transition the deleted five did. The coalescing is the fix; the senders are not
the bug.

---

## Decision 2 — ack durability lives in `runtime_events`, not in the lease row

Landed by `daa8f590` (PR #757, task `01a007bf`).

**The defect.** The no-ack alarm asked the ETS lease row whether the stage had
been acked. `clear_liveness/1` deletes that row wholesale, so a dispatch after a
clear re-armed a fresh no-ack countdown against a stage whose executor had
already acked and had no reason to ack again. On 2026-08-15 it fired six times
against live, working agents.

**Where the answer comes from now.** `maybe_fire_no_ack/3` consults
`Platform.Orchestration.stage_acked?/2`, which queries the `runtime_events`
table for an `execution.acked` row whose `payload->>'stage_id'` matches the
lease's stage. That is Postgres, not ETS: it survives `clear_liveness/1`, a
`LeaseManager` restart, and a node restart.

Two decisions inside that function are load-bearing and should not be "tidied":

- **A nil or empty `stage_id` returns `false` without querying.** Planning-phase
  acks are emitted with `stage_id: ""`, and matching those would answer "acked"
  for stages nobody acked. An alarm that suppresses itself everywhere is
  strictly worse than one that fires spuriously.
- **The query is deliberately un-indexed.** There is no composite
  `(task_id, event_type)` index and none on `payload`, so it plans as an index
  scan on `task_id` plus an in-memory filter. Rows per task run
  tens-to-hundreds and this is called only on the alarm path — once per elapsed
  deadline, never in a request hot path. Do not add a speculative index.

### What `clear_liveness/1` may and may not clear

`clear_liveness/1` is `LeaseManager.clear(task_id)`. It deletes the **entire ETS
lease row** for the task. That includes `ack_at`, `no_ack_at`,
`no_ack_fired?`, `safety_net_at` and `silenced_until`.

It **cannot** clear the durable ack, because the durable ack is a
`runtime_events` row and nothing in the liveness path deletes those.

So, for anyone adding a call site:

- **Safe:** the no-ack alarm will not spuriously re-fire for a stage that has
  already been acked. `stage_acked?/2` still answers true after your clear.
- **Not safe to assume:** you are also dropping the safety-net deadline and any
  operator `silenced_until`. If the stage is still live, the next dispatch must
  re-arm those, and an operator silence set before your clear is gone.
- **Scope:** the clear is task-keyed, not stage-keyed. It affects every stage's
  liveness state for that task, not only the one you are reasoning about.

`record_ack/1` returning `{:error, :not_found}` is now logged with a diagnostic
naming the likely cause (the lease was cleared between dispatch and ack) rather
than being discarded — task `01a007bf` stage 4. A silent `:not_found` there was
how the original defect stayed invisible.

---

## Consequences

**Positive**

- One state change produces one dispatch, and the dispatch reflects state at
  fire time rather than at any sender's observation time.
- New senders are cheap. Correctness of the fan-in no longer depends on every
  author knowing about every other sender.
- The no-ack alarm answers a durable question, so it is correct across lease
  clears, restarts, and re-dispatches.

**Negative**

- Dispatch carries up to one debounce window of added latency. At 50ms this is
  not perceivable, but it is real and it is a floor, not an average.
- `stage_acked?/2` is a database round-trip on the alarm path where the old
  check was an ETS read. That is deliberate — see the query-cost note above —
  but it does mean the alarm path now depends on the database being reachable.
- Ack state and liveness state now live in two stores with different
  lifetimes. Anyone reasoning about "has this been acked" must know which
  question they are asking.

**Not addressed**

- Cross-agent liveness on parallel stages, unchanged from ADR 0025.
- Per-project timeout overrides, unchanged from ADR 0025.
- Whether the nine senders should eventually be consolidated. They should not
  be, for the reason given above, but no mechanism prevents someone trying.
