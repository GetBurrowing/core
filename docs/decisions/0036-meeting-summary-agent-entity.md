# ADR 0036: Promote Meeting-Summary Config to an Agent Entity

**Status:** Proposed
**Date:** 2026-04-16
**Deciders:** Rowan
**Related:** ADR 0030 (Meetings — LiveKit Voice/Video), ADR 0034 (MCP endpoint & capability bundles), existing `Platform.Agents` schema

---

## Context

Meeting transcripts are summarized by `Platform.Meetings.Summarizer`. As of this ADR the summarizer is configured via a gitignored YAML at `apps/platform/priv/meetings.yml` (template at `meetings.yml.example`):

```yaml
summary:
  provider: ollama            # anthropic | openai | ollama | none
  base_url: http://build-host.local:11434/v1
  model: gemma4:e4b
  max_tokens: 2048
  temperature: 0.3
  api_key_env: null
```

This was a deliberately small step to get the summarizer off hardcoded Anthropic while leaving a clean path to a durable config surface. The YAML approach has two limitations worth addressing:

1. **No UI** — operators have to edit a file and restart (or re-read on next summary) to switch providers. Not tenable for multi-tenant Suite deployments.
2. **Duplicates work already done by `Platform.Agents`** — the `agents` table already models configurable units of work (slug, workspace_id, model_config, tools_config, runtime_type, …). The summarizer is functionally an agent: input = transcript, output = summary, model/provider configured.

## Decision

Replace `Platform.Meetings.Config` with a lookup into the existing `agents` table, keyed by a well-known slug.

### Data model

- An **Agent row** with `slug: "meeting-summarizer"` is the canonical config source.
- `model_config` (existing JSON column) carries `{provider, model, base_url, max_tokens, temperature, api_key_env}`.
- `status` gates whether summaries run (`active` → run, any other → skip, equivalent to today's `provider: none`).
- `workspace_id` scopes configs per workspace, enabling different tenants to pick different providers without file edits.

### Runtime flow

1. `Platform.Meetings.Summarizer.run_summary/1` resolves the agent via `Platform.Agents.get_agent_by_slug(workspace_id, "meeting-summarizer")`.
2. If the agent exists and `status == "active"`, dispatch to the provider named by `model_config["provider"]`.
3. If no agent or status suppresses it, behave as today's `provider: none` (skip LLM, finalize with empty summary).

### Migration plan

1. **Data migration**: create a `meeting-summarizer` agent row per workspace, seeded from the current YAML on first summary attempt. One-shot migration, idempotent.
2. **Code change**: `Summarizer` reads from `Platform.Agents` instead of `Platform.Meetings.Config`. `Platform.Meetings.Config` is retired.
3. **UI**: surface the agent under the existing Control Center / agent admin flows. No new UI surface needed.
4. **Deprecate YAML**: after one release cycle, remove `priv/meetings.yml.example` and the `yaml_elixir` dep if no other consumer exists.

## Consequences

### Positive

- **Single source of truth**: agents are already the configuration primitive. No parallel config system.
- **Per-workspace config**: multi-tenant deployments can mix and match providers without file edits.
- **Admin UI is free**: Control Center already edits agents.
- **Audit history**: agent config changes go through Ecto timestamps + any audit layer applied to `agents`.

### Negative / tradeoffs

- Requires a data migration and UI pass — bigger surface than a YAML edit.
- Loses the "zero-DB bootstrap" property of YAML: you can't summarize in a fresh install until the seed runs. Acceptable since summaries are non-critical and the seed is idempotent.
- Couples meeting summaries to the agents schema — if that schema evolves heavily we may need to revisit.

### Out of scope

- Promoting the **meeting-transcriber** STT config (`STT_BASE_URL`, `STT_MODEL`) to an agent entity. That lives in the external Python worker's env and is governed by its deployment, not Suite's DB. A separate ADR would be needed if we wanted Suite-driven config push.
- Unifying with ADR 0034's MCP agent bundle system. The summarizer doesn't expose tools — it's a single-shot completion — so the bundle model doesn't apply.

## Sequence

1. This ADR accepted.
2. Seed migration + `Summarizer` lookup change (one PR).
3. Control Center UI verifies it can edit the new agent (likely no changes needed).
4. Announce deprecation of `priv/meetings.yml`.
5. Remove YAML + `yaml_elixir` dep one release later.

Estimate: 1–2 days of implementation work once prioritized.
