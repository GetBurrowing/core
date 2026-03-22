# ADR 0023: UUIDv7 Primary Keys and Persistent Unread Counts

## Status

Accepted

## Context

Suite currently uses UUIDv4 for all primary keys (via Ecto's `:binary_id`). UUIDv4 is random — not sortable by time. This creates two problems:

1. **Unread counts require timestamp joins.** We can't do `WHERE id > :last_read_id` because v4 UUIDs don't sort chronologically. The workaround is storing a `last_read_at` timestamp and joining on `inserted_at`, which is slower and more complex.

2. **Index locality is poor.** Random UUIDs scatter inserts across B-tree pages, causing write amplification on large tables. UUIDv7's time-prefix means inserts are append-mostly.

Meanwhile, the current unread badge system (ADR 0022) uses ephemeral per-session counters that reset on page reload. Users want persistent unread counts that survive across sessions and devices.

## Decision

### 1. UUIDv7 for all new records

Adopt UUIDv7 (RFC 9562) as the default ID generator for all Ecto schemas.

**Format:** 48-bit Unix millisecond timestamp | 4-bit version (0111) | 12-bit random | 2-bit variant (10) | 62-bit random

**Key property:** Lexicographic sort of UUIDv7 strings = chronological order.

**Implementation:**
- Custom `Platform.Types.UUIDv7` Ecto type with `autogenerate/0`
- Update `@primary_key` in schemas to use the new type
- Existing v4 UUIDs remain untouched — v4 and v7 coexist in `uuid` columns
- No data migration needed

### 2. Persistent unread counts via `last_read_message_id`

With UUIDv7, `last_read_message_id` becomes viable:

```sql
-- Count unread messages: simple, index-friendly, no timestamp join
SELECT COUNT(*) FROM chat_messages
WHERE space_id = :space_id
  AND id > :last_read_message_id
  AND thread_id IS NULL
  AND deleted_at IS NULL
```

**Schema changes:**
- Migrate `chat_participants.last_read_message_id` from `:bigint` to `:binary_id`
- Add `Chat.mark_space_read/2` and `Chat.unread_counts_for_user/1`

### 3. Clean up ephemeral approach

Remove the in-memory `unread_counts` assign and `dm_unread` tracking from Sage's PR. Replace with DB-backed counts loaded on mount.

## Data Flow

```
┌─────────────────────────────────────────────────────────┐
│                     Page Load                            │
│                                                          │
│  mount() → Chat.unread_counts_for_user(user_id)         │
│          → %{space_id => count} from DB                  │
│          → assign(:unread_counts, counts)                │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│                  Navigate to Space                        │
│                                                          │
│  handle_params → Chat.mark_space_read(participant, msg)  │
│               → UPDATE last_read_message_id = latest     │
│               → clear @unread_counts[space_id]           │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│              Background Message Arrives                   │
│                                                          │
│  {:new_message, msg} where msg.space_id != active        │
│  → increment @unread_counts[space_id] in memory          │
│  (stays in sync because we started from DB value)        │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Active Space Message Arrives                 │
│                                                          │
│  {:new_message, msg} where msg.space_id == active        │
│  → Chat.mark_space_read(participant, msg)                │
│  → no badge increment                                    │
└─────────────────────────────────────────────────────────┘
```

## Migration Plan

1. Add `Platform.Types.UUIDv7` Ecto type
2. Migration: alter `chat_participants.last_read_message_id` from `:bigint` to `:binary_id`
3. Update Message schema to use UUIDv7 autogenerate
4. Update all other schemas to use UUIDv7 (one `@primary_key` line per schema)
5. Add `Chat.mark_space_read/2` and `Chat.unread_counts_for_user/1`
6. Update ChatLive: load counts on mount, mark read on navigate, increment on background messages
7. Remove ephemeral `dm_unread` / `unread_counts` in-memory-only tracking
8. Sidebar badges read from the persistent counts

## What Survives

| Scenario | Ephemeral (ADR 0022) | Persistent (this ADR) |
|----------|---------------------|-----------------------|
| Page reload | ❌ Lost | ✅ Loaded from DB |
| Multiple devices | ❌ Independent | ✅ Shared via DB |
| Push notification → open app | ❌ Badge gone | ✅ Shows unread |
| Background tab messages | ✅ Counted | ✅ Counted |
| Multiple tabs, read in one | ❌ Other tab stale | ✅ Next mount accurate |

## Consequences

- All new records get time-sortable IDs without changing column types
- Old v4 UUIDs coexist — they just won't sort chronologically (irrelevant for existing data)
- `id >` comparisons work for any two v7 UUIDs in the same table
- One small DB write per space-open (mark read) — negligible at our scale
- Unread query uses the existing primary key index — no new indexes needed
