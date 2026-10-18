# 0022 — DM Unread Badge

**Date:** 2026-03-21  
**Status:** Accepted  
**Author:** Sage (a team member)

---

## Context

Users had no visual indication of missed direct messages or group conversations when
they were viewing a different channel. The sidebar showed all DM/group spaces but
provided no unread count, forcing users to manually cycle through conversations to
check for new activity.

## Decision

Add a per-conversation unread message counter rendered as a circle badge next to each
DM/group entry in the sidebar (desktop and mobile overlay). The count is ephemeral —
stored in LiveView socket assigns only, with no database changes required.

### Approach

1. **Background PubSub subscriptions** — on `mount/3`, subscribe to all DM/group
   space PubSub topics so the LiveView receives `{:new_message, msg}` events even
   when that space is not active.

2. **Increment on background message** — in `handle_info({:new_message, msg})`,
   if the message's `space_id` does not match `active_space.id` and was not sent
   by the current participant, increment `dm_unread[space_id]`.

3. **Clear on navigation** — `handle_params` calls `clear_dm_unread(socket, space.id)`
   when switching into a space, resetting its counter to zero.

4. **Badge rendering** — a small filled circle (`bg-primary / text-primary-content`)
   appears to the right of the conversation name. Values 1–8 display as digits; 9 or
   more display as `9+`.

### Why ephemeral?

- Unread state is highly session-specific and does not need to survive page reloads
  for the initial implementation.
- Avoids schema changes, migrations, and cross-session sync complexity.
- Can be promoted to persistent (DB-backed per-participant read cursors) in a future
  ADR if multi-device or reload persistence becomes a requirement.

## Consequences

- **Simple, zero-migration** — pure LiveView state change.
- **Accurate within a session** — counts reset on page reload (acceptable tradeoff now).
- **No double-counting** — own messages are excluded from the counter.
- **Scales with conversation count** — one PubSub subscription per DM space; negligible
  overhead for typical user with <20 conversations.

## Future Work

- Persistent read cursors (DB-backed) for cross-device / reload persistence.
- Extend unread indicator to channel list (currently only DMs).
- Bold/highlight conversation name when unread > 0 for additional visual weight.
