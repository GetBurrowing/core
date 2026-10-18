# Claude Channel Bridge — Rolling Out the `system_event` Envelope Fix

How to get a `claude_channel` runtime onto a build that renders responsibility
dispatches, and how to read `mix platform.runtime_wake_report` afterwards
without drawing the wrong conclusion from it.

The procedure is three commands. Everything else in this runbook exists because
the obvious checks — "the version went up", "the pull succeeded", "a dispatch
arrived with a full body" — are all wrong here, each for a different reason.

## Context — what actually broke

Burrow emits attentions down three paths, and they do not share an envelope:

| Emitter | Body lives at | `message` key present? |
| --- | --- | --- |
| `task_router.ex` task dispatch | `message.content` | yes |
| chat mention / reply | `message.content` | yes |
| `AgentResponder.broadcast_system_event/3` (responsibility dispatch) | `signal.prompt` | **no** |

A bridge that reads `payload.message.content` unconditionally renders the first
two perfectly and drops the third — the agent receives an attention with an
empty body and nothing to act on. Fixed upstream in `7288017` (PR #15) by
falling back: `payload.message?.content ?? payload.signal?.prompt ?? ""`.

**A task dispatch reaching a runtime with a full body proves nothing.** It comes
from `task_router.ex`, which sets `message.content`, and renders identically on
a broken and a fixed client. Do not accept it as evidence, yours or anyone
else's.

## Why the version string is not the check

`package.json` in `Startup-Suite/claude-code-suite-channel` reads
`"version": "0.2.0"`, and `src/suite-client.ts` derives the reported version
straight from it:

```ts
export const CLIENT_INFO = {
  product: "claude_channel" as const,
  version: (pkg as { version?: string }).version ?? "unknown",
};
```

`7288017` did not touch `package.json`. Neither did the capability commit. So
every `claude_channel` runtime reports `0.2.0` before the fix and `0.2.0` after
it, and the VERSION column of the report discriminates nothing.

This is not an oversight to correct by bumping the version. **The version is not
a function of the code that changed** — it is a function of whoever last decided
to edit that line, which is a different thing and always will be. The check has
to be something the changed code itself emits.

That is what `client_info.features` is. The bridge declares
`features: ["system_event_prompt"]` from the same module that contains the
fallback behavior, the server persists it on the `agent_runtimes` row at join
(`runtime_channel.ex`, `resolve_client_info/1`), and
`AgentRuntime.client_supports?/2` reads it back. A declaration emitted by the
build that contains the behavior cannot drift from the behavior it claims.

## Two commits, two PRs, and the ordering between them

This is the part that trips people. There are **two** independent changes, they
merge at different times, and pulling one without the other is a normal
intermediate state, not a failure:

| | What it does | Where it is | Merge gate |
| --- | --- | --- | --- |
| `7288017` (PR #15) | The actual fix. Renders `signal.prompt`. | **already on `origin/main`** | merged |
| `aec46fe` (PR #16) | Declares `features: ["system_event_prompt"]`. | branch `task/019fa56b-system-event-capability` | **after core stages 2–3 are in production** |

**The ordering constraint:** the pre-stage-2 server's `resolve_client_info/1`
builds its map from `product` and `version` only. A `features` key sent to it is
not rejected and does not error — it is **silently dropped on the floor** and
never persisted. Merging PR #16 before the core side is live therefore produces
runtimes that declare the capability, get it discarded at join, and read
`unproven` forever after — with no error anywhere to explain why. Land the
server first.

### The consequence for anyone pulling today

If you pull `origin/main` before PR #16 lands, you get **the fix but not the
proof**: responsibility dispatches render correctly, and the report still says
`unproven`.

That is the correct output. Do not chase it. `unproven` means "has not declared
the capability", and a build without PR #16 has nothing to declare. Re-pull and
restart once PR #16 is merged to flip the row to `proven`.

## What `unproven` does and does not mean

The verdict is three-valued in wording and two-valued in code, and the wording
is load-bearing:

- **`proven`** — declared `system_event_prompt` on its most recent join. The
  build renders `signal.prompt`.
- **`unproven`** — has not declared it. This covers **two** distinct states that
  the server genuinely cannot tell apart:
  1. a runtime running an old build, and
  2. a runtime running a **new** build that has not reconnected since the server
     started recording.

  `AgentRuntime.client_supports?/2` fails closed, so everything that is not a
  positive declaration lands here.
- **`revoked`** — printed in its own section and **excluded from the unproven
  count**. A revoked runtime cannot authenticate, cannot join, cannot declare and
  cannot receive a dispatch. It is not a delivery risk, and counting it as
  unverified inflates the number an operator reads. It comes off the risk list
  rather than sitting on it.

**`unproven` is not a defect count.** The report never prints the word `broken`,
and neither should you when quoting it. Absence of a declaration is absence of
evidence. Writing `broken` in a status update turns "we have not confirmed this
one yet" into "this one is failing", which is a claim about someone else's
machine that you cannot support and that will be read as an accusation.

Note the second state is reachable on a fully fixed fleet: a runtime that
joined *before* the core deploy and has not reconnected since reads `unproven`
no matter how current its build is. **Reconnection after the server deploy is
required, not just the pull.**

## Procedure

### 1. Pull

```bash
git -C <checkout> fetch origin
git -C <checkout> merge --ff-only origin/main
```

Find `<checkout>` from the MCP server config that launches the bridge, not from
memory — see [Restarting](#2-restart-every-bridge-process) below for why.

**Verify by content, not by "the pull succeeded".** Task `019fa469` shipped a
code-only no-op to production that passed CI and was caught only by reading the
production row before and after. Grep for the behavior:

```bash
grep -n 'signal?\.prompt' <checkout>/src/attention.ts
# 89:    const text = payload.message?.content ?? payload.signal?.prompt ?? "";
```

**`src/index.ts` is the wrong file to grep.** On older checkouts the attention
handler lived at `src/index.ts:256`; on current `main` it has moved to
`src/attention.ts`. Grepping `index.ts` after a successful pull finds nothing
and reads exactly like a failed pull. Grep `src/attention.ts`.

Once PR #16 has landed, also confirm the declaration:

```bash
grep -n 'system_event_prompt' <checkout>/src/suite-client.ts
```

### 2. Restart every bridge process

The bridge is an MCP **stdio** server owned by the Claude Code session that
launched it. Pulling the checkout does not affect a process that is already
running: it re-reads nothing. The session must be restarted (or `/mcp`
reconnected).

**Count the processes first.** One checkout commonly backs several sessions —
each `mcpServers` entry pointing at that path spawns its own `bun`:

```bash
ps -eo pid,etime,args | grep -F '<checkout>/src/index.ts' | grep -v grep
```

On the hive box on 2026-07-27 this was **four** live processes with uptimes of
19d, 19d, 16d and 2d19h. Restart fewer than all of them and the survivors keep
running the pre-fix build after a successful pull — the report then shows a
mix of `proven` and `unproven` rows for what looks like one machine, which is
the single most confusing state this system can produce. If you restart some
now and some later, say so out loud rather than letting the report say it.

**An executing agent cannot do this step for its own bridge.** Restarting the
process that hosts the session kills the session, including any other agents on
it. This is a human action every time. A stage that claims to have verified its
own restart did not.

### 3. Confirm from the server

```bash
mix platform.runtime_wake_report
```

In production, without a deploy (`report/0` is Mix-free and a pure read, so it
is safe to run before, during and after a rollout to watch rows flip):

```bash
bin/platform eval 'Mix.Tasks.Platform.RuntimeWakeReport.report()'
```

The row for the restarted runtime should read `proven`. For the underlying row:

```elixir
Platform.Federation.get_runtime_by_runtime_id("rowan-claude-agent-1")
```

Two things about that call, both of which have bitten this rollout already:

- **It is `get_runtime_by_runtime_id/1`, not `get_runtime/1`.** `get_runtime/1`
  is `Repo.get(AgentRuntime, id)` on the **primary key**, which is a UUIDv7. Pass
  it a human-readable runtime id like `"rowan-claude-agent-1"` and you get a cast
  error, not the row — which reads like the runtime is missing.
- **The row has no `last_seen_at`.** The `agent_runtimes` schema carries
  `last_connected_at`; `last_seen_at` exists only in
  `Platform.Federation.RuntimePresence`, an in-memory presence store surfaced
  through `Platform.Federation.federation_status/0`. Looking for `last_seen_at`
  on the struct finds nothing, and the in-memory value resets when the server
  restarts, so it is the wrong thing to hang a rollout check on.

So the two checks on the row are:

- `metadata["client_info"]["features"]` contains `"system_event_prompt"`
- `last_connected_at` has moved (this is the persisted one)

Quote both verbatim, before and after. "The report looks right" is not a record;
the row is.

## Handing off a runtime you cannot reach

Runtimes on other people's machines cannot be updated from here, and no test
can honestly assert they are fixed — manufacturing that assertion against a dev
fixture tests nothing about them. What we hand over instead is:

1. **An observable scoreboard.** `mix platform.runtime_wake_report` makes each
   runtime's true state visible from the server the moment it reconnects. No
   access to the machine required.
2. **This runbook**, posted to the owner in Burrow.

That is coverage. Claiming the runtime is fixed because we sent someone a
message is not.

**Before any outreach, read the report.** A runtime whose owner also authored or
reviewed the fix may already be on the current build and merely disconnected —
in which case it needs a reconnect, not a lecture. Check the row first; the
assumption that a given runtime is "someone else's unpatched machine" is worth
about as much as the version column.
