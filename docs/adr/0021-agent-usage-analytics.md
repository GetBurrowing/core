# ADR 0021 — Agent Usage Analytics Dashboard

**Status:** Accepted
**Date:** 2026-03-22
**Author:** Zip (requested by Rowan Member, approved by Rowan Ellis)

## Context

We need visibility into agent usage — request volume, token consumption, model selection, cost, and latency. This is the first observability surface in Burrow.

## Decision

### Phase 1: Burrow-Side (this ADR)

Build the data model, API endpoint, and LiveView dashboard. The plugin-side instrumentation (Phase 2) will follow as a separate PR.

**New Ecto schema: `Platform.Analytics.UsageEvent`**

Table: `agent_usage_events`

| Column | Type | Notes |
|---|---|---|
| id | UUIDv7 PK | |
| space_id | binary_id | FK → chat_spaces |
| agent_id | binary_id | FK → agents (nullable for unknown) |
| participant_id | binary_id | The agent's participant in the space |
| triggered_by | binary_id | User who triggered the interaction (nullable) |
| model | string | e.g. "anthropic/claude-sonnet-4-6" |
| provider | string | e.g. "anthropic" |
| input_tokens | integer | |
| output_tokens | integer | |
| cache_read_tokens | integer | default 0 |
| cache_write_tokens | integer | default 0 |
| total_tokens | integer | computed |
| cost_usd | float | estimated cost in USD |
| latency_ms | integer | total response time |
| tool_calls | {:array, :string} | list of tool names invoked |
| task_id | string | linked task ID if applicable (nullable) |
| session_key | string | OpenClaw session key |
| metadata | map | extensible JSON blob |
| inserted_at | utc_datetime_usec | |

**Indexes:**
- `[:space_id, :inserted_at]` — per-space time queries
- `[:agent_id, :inserted_at]` — per-agent time queries
- `[:inserted_at]` — global time range

**API Endpoint:**

```
POST /api/internal/usage-events
Authorization: Bearer <agent-token>

{
  "space_id": "...",
  "session_key": "...",
  "model": "anthropic/claude-sonnet-4-6",
  "provider": "anthropic",
  "input_tokens": 1523,
  "output_tokens": 847,
  "cache_read_tokens": 12000,
  "cache_write_tokens": 0,
  "cost_usd": 0.0234,
  "latency_ms": 3200,
  "tool_calls": ["read", "exec", "web_search"],
  "task_id": null,
  "metadata": {}
}
```

Authentication: Reuse the existing agent token middleware (`/api/*` auth chain).

**Analytics Context Module: `Platform.Analytics`**

- `record_usage_event(attrs)` — insert
- `usage_summary(filters)` — aggregated stats (total requests, tokens, cost, avg latency)
- `usage_time_series(filters, granularity)` — bucketed by hour/day
- `recent_events(filters, limit)` — paginated list

**LiveView Dashboard: Agent Resources → "Usage" tab**

Add a new tab/section within ControlCenterLive (or a sub-live-view) accessible at `/control/usage`:
- Summary cards: total requests, total tokens, estimated spend, avg latency
- Time-series chart: requests + tokens over time (using a simple SVG/CSS chart or Chart.js hook)
- Event log table: individual interactions with model, tokens, cost, linked task
- Filters: agent, space, date range

### Phase 2: Plugin Instrumentation (separate PR)

The OpenClaw plugin SDK already emits `DiagnosticUsageEvent` (`model.usage` type) via `onDiagnosticEvent`. The Burrow plugin will:

1. Subscribe to `onDiagnosticEvent` during initialization
2. On `model.usage` events, POST to Burrow's `/api/internal/usage-events`
3. Include the space_id from the session context

This is a ~30-line addition to the plugin's `index.ts`.

## Consequences

- First analytics/observability surface in Burrow
- Cost tracking enables data-driven decisions about model selection
- Foundation for the trust-scoring system (Sage's intake refinement accuracy tracking needs similar instrumentation)
- Phase 1 ships independently — dashboard works as soon as the first event hits the API
