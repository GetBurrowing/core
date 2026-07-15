# ADR 0042 — Org / Project Topology and Context Inheritance

**Status:** Proposed
**Date:** 2026-06-18
**Author:** Dalton (drafted at Rowan's request)

---

## Context

Suite has two parallel hierarchies in the schema that don't intersect:

1. **Orgs** (`orgs`): hierarchical via `parent_org_id`, with a partial unique index (`orgs_single_root`) enforcing **exactly one root**. Today: `Fabrikam` (root) → 4 tenant children (`Soylent`, `Wayne-Tech`, `SXI`, `Paragon`). Membership lives in `org_memberships(user_id, org_id, role)` with `role ∈ {admin, member}` and a `roles_locked_at` lock against the email-domain auto-promote rule (ADR-adjacent — see migration `20260519160000_refine_fabrikam_admin_membership_by_email_domain.exs`).

2. **Projects** (`projects`): flat — **no `org_id` FK, no `parent_project_id`**. Today: `Soylent`, `Startup Suite`, `Stark Industries`. The cascade chain is project → epics / tasks / task_stacks / meetings. All work units hang off a project.

The naming overlap between projects and tenant orgs (`Soylent` project / `Soylent` org; `Stark Industries` project / `SXI` org) is **coincidence/convention only** — the database doesn't know they're related.

`chat_spaces` does have `org_id` (`ON DELETE SET NULL`), so chat is org-scoped. So we already have one piece of UX that's org-scoped (chat) and one that's project-scoped (tasks/epics/meetings). They speak past each other.

[ADR 0033](./0033-org-level-context-management.md) ships an org-context store (`org_context_files` + `org_memory_entries`) with a nullable `workspace_id` "single-org in v1; nullable for future multi-tenancy." [ADR 0041](./0041-org-memory-v2-wiki-system.md) conceptualizes a 3-level scope (`org/*` always, `project/<id>/*` when scoped to a task, `space/<id>/*` when scoped to a space) — but the on-branch `Platform.Org.WikiPage` schema still constrains `file_key` to the three flat `ORG_*.md` strings; namespacing was deferred. The `PreambleBuilder` already takes `(agent, space, task)` args specifically to support this future model.

The Files module currently in plan-review (task `019ebd47-bb4e-7a7c-bcf9-67d5dab2c729`, plan `019ed691-…` v2) sits squarely on this gap: scoping Files at the org level groups every project's docs into one bag; scoping only at project level orphans tenant-level brand/governance docs across multiple projects per client.

The user (Rowan) confirmed the model on 2026-06-18: **one org has many projects**; root Fabrikam gets "super-context" of all tenant orgs; agents operating in a tenant org get inherited Fabrikam context plus their own tenant context but NOT sibling-org context.

---

## Decision

### 1. Projects belong to orgs (1-to-many, required)

Add `projects.org_id uuid NOT NULL` with FK → `orgs(id) ON DELETE RESTRICT`.

`ON DELETE RESTRICT` — deleting an org with live projects must require explicit reassignment first, not silently nuke them. Aligned with existing FK strictness on `runtime_events.owner_org_id` and `execution_leases.owner_org_id`.

**Backfill rules** for existing projects (by name match):
- `Startup Suite` → Fabrikam (root)
- `Soylent` project → Soylent org
- `Stark Industries` project → SXI org

All three match cleanly today. No orphans.

**New project creation** (UI + the follow-up `project_create` MCP tool) requires an `org_id`. UI default is the currently-active org, or Fabrikam (root) when no org is selected.

The `projects.workspace_id` column (nullable, unused, no FK) stays vestigial for now; ADR 0033's "future multi-tenancy" escape hatch overlaps with the org model this ADR makes real, and that vestige can be dropped in a follow-up cleanup.

### 2. Three-level context scope, made real

ADR 0041's deferred namespacing lands. The scope levels:

| Level | Path prefix | Cardinality |
|-------|-------------|-------------|
| Root org | `org/fabrikam/` | 1 (the root) |
| Tenant org | `org/<tenant-slug>/` | N (Soylent, SXI, Wayne-Tech, Paragon, …) |
| Project | `project/<project-id>/` | M per tenant |
| Space | `space/<space-id>/` | K per project (or per tenant for non-project spaces) |

**Schema changes:**
- `org_wiki_pages.file_key` constraint loosens to accept path-style keys.
- `org_wiki_pages` and `org_wiki_journal_entries` grow explicit `org_id` (required) and `project_id` (nullable) columns so the preamble builder can filter by namespace without parsing the path string.

### 3. Context inheritance rules

Context flows **upward** in the org tree (a child inherits its ancestors' context) and **downward only from the root** (the root sees all descendant context, the "super-context" position).

**Per operating context:**

- **Operating at root Fabrikam (no scoped tenant org):** preamble loads `org/fabrikam/*` (full) + a summary surface for each descendant (`org/<tenant>/IDENTITY.md` + a single auto-curated `org/fabrikam/TENANTS_SUMMARY.md` paragraph per tenant). Full per-tenant memory loads only on explicit search via `memory_search` filtered by `org_id`. This avoids blowing the 4096-token preamble budget with N×tenant-full-context.

- **Operating in a tenant org (e.g. SXI) on a tenant project (e.g. Orion):** preamble loads `project/<orion_id>/*` + `org/sxi/*` + inherited `org/fabrikam/*` (root). Sibling-org content (`org/wayne-tech/*`) is **excluded** — strict tenant isolation between siblings.

- **Operating in a tenant org with no specific project context:** `org/<tenant>/*` + inherited `org/fabrikam/*`. No project memory loaded.

- **Within a chat space:** add `space/<space_id>/*` on top of whichever org/project context applies.

**Eviction order** when the 4096-token budget is exceeded: project > org (direct) > org (ancestors) > space. Direct-scope content evicts last; inherited and space-attached evict first. The historian agent is responsible for keeping `org/fabrikam/TENANTS_SUMMARY.md` short enough that the root-level summary always fits.

### 4. Cross-tenant attention signals (not preamble)

Rowan's concern is preserving the ability to cross-pollinate without polluting every agent with every tenant's context. The split:

- **Preamble** (always loaded) follows the strict inheritance rules above. Sibling orgs are invisible to each other in the preamble.
- **Attention signals** (event-driven, scoped to the routing model in ADR 0013) can still hop sibling-org boundaries when a user explicitly mentions or @-tags across orgs. The router doesn't gate by org scope; the agent reads sibling-org context on-demand via `memory_search`.

### 5. Default channel rename

All tenant-org default channels rename to `General` (display name) with slug `general`. Today:

| Org | Current default channel | Becomes |
|-----|------------------------|---------|
| Fabrikam | "General" / `general` | unchanged |
| Soylent | "Soylent" / `soylent` | "General" / `general` |
| Wayne-Tech | "Wayne-Tech" / `wayne-tech` | "General" / `general` |
| SXI | "Stark Industries" / `stark-industries` | "General" / `general` |

The existing unique index `chat_spaces_unique_slug` on `(workspace_id, slug)` is partial: since all four rows have `workspace_id IS NULL`, PostgreSQL treats each NULL as distinct under the btree default and allows multiple `(NULL, 'general')` rows. The rename is safe under the current schema.

**Forward path:** add a follow-up partial unique index on `(org_id, slug) WHERE org_id IS NOT NULL` so future tenant-org default channels can't accidentally collide, and the system reads more intent-clearly. Out of scope for this ADR; flagged as a follow-up.

### 6. MCP surface extensions

- `memory_search` learns `project_id` and `org_id` filters (in addition to the existing `memory_type` filter from the Files module v2 plan).
- New `org_list_descendants(org_id)` so agents can enumerate child orgs when operating at root.
- Existing `project_list` grows an `org_id` filter so listing projects under a given org is one call.

### 7. Explicitly out of scope for this ADR

- `chat_spaces.project_id` direct FK. Today the chat_space → project link goes via `chat_spaces.metadata.task_id` → tasks → project. A direct FK would simplify joins but is additive scope; deferred to a separate proposal.
- Dropping `projects.workspace_id`. Vestigial; deferred to a cleanup task.
- Renaming the tightened slug constraint to `(org_id, slug)`. Deferred per Section 5.

---

## Topology after this ADR

```
Fabrikam (root org)                    ← "super-context" vantage point
├── Suite (project)                ← internal Fabrikam work
├── Soylent (tenant org)
│   └── Soylent (project)         ← moved under Soylent org
├── SXI (tenant org)
│   └── Stark Industries (project — Orion work)
├── Wayne-Tech (tenant org)
└── Paragon (tenant org)
```

---

## Migration sequence

1. **Schema** — add `projects.org_id` (nullable initially), backfill, then alter to NOT NULL + FK. Same migration adds the org_id/project_id columns to `org_wiki_pages` and `org_wiki_journal_entries`, loosens the file_key constraint, and renames the tenant default chat_spaces.
2. **PreambleBuilder** — drop the `@preamble_whitelist` v1 hack; implement real namespace resolution + the super-context-at-root summary aggregation.
3. **Historian / dreaming agent** — extend to maintain `org/fabrikam/TENANTS_SUMMARY.md` as the auto-curated short-form aggregate.
4. **MCP surface** — `memory_search` filters, `org_list_descendants`, `project_list` filter.
5. **UI** — project switcher in the shell respects `org_id`; project creation form requires choosing an org; project list groups by org.

The Files module v2 plan (task `019ebd47-…`, plan `019ed691-…`) becomes much simpler with `projects.org_id` in place — `platform_files.project_id` (required) + `platform_files.org_id` (nullable, for tenant-level docs) gives Rowan the "co-locate per project but also have org-level docs" goal directly.

---

## Consequences

- **Positive:** the two parallel hierarchies merge into one coherent tree. Tenant isolation has a clear data-model boundary. The preamble system stops being half-built (ADR 0041 P4's deferred namespacing finally lands). The Files module gets its scoping question answered for free.
- **Negative:** schema migration is non-trivial (NOT NULL after backfill); every place that reads `projects` must now also be conscious of `org_id`. Agents at root see less per-tenant context by default (only summaries, full content via search), which is the intended trade-off but is a behavior change for agents currently relying on global single-org assumptions.
- **Risk:** the historian's `TENANTS_SUMMARY.md` curation is a new responsibility — if it goes stale, root-level agents lose situational awareness. Mitigation: telemetry on summary freshness + a heartbeat job that re-summarizes weekly even without explicit dreaming runs.
