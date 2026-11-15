# Named mention groups — #158 design contract

Status: accepted by Calcifer; implementation in progress. Exact-org external human recipients are permitted only with current org membership, participation and read access; external actors cannot discover or invoke groups.

Source baseline: private core-work main `ae7018c72982f6bf54c4043b89a6620ce046e897`. Integration branch: `feat/mention-groups`; checkout: `work/core-mention-groups`.

## Outcome

A member selects a named group in the chat composer and addresses its eligible human and agent members in one action. Groups are reusable within one organization. Overlapping groups and individually mentioned members produce one recipient decision per identity. Mentioning a group grants no space participation, organization membership, read permission, history visibility or task pins. No nested or dynamic groups.

This proposal covers the existing web composer, including thread and mobile web layouts, server message entry points and existing human/agent delivery consumers. Native applications must retain readable group labels in rendered messages; separate native group-management/composer features are outside the first slice. This boundary is explicit rather than a claim that all clients already understand a new token.

## Options and recommendation

1. Expand a picker selection into existing individual name chips. Smallest change, but loses group identity and feeds the existing agent-summon path. Reject.
2. Resolve named groups from their current membership whenever routing runs. Simpler persistence, but delayed delivery, historical queries and retries change recipients after edits to a group. Reject.
3. Stable group identity plus a server-written send-time snapshot. Recommend. More integration work, but preserves identity and makes the recipient contract inspectable.

## Ownership and management

Groups belong to `space.org_id`, not to an individual space or the install. Never infer an organization from a globally visible name. A space without an org offers no org groups.

For the first slice, exact-org, non-external admins create, rename, edit membership and archive groups. Use `Tenancy.org_admin?/2` in context writes and management-page authorization; visibility or root membership alone is insufficient. Non-external org members may discover/use groups in readable spaces. An agent author may use an org's groups only from its existing, authorized participation in a space of that org. External users cannot discover/invoke groups initially. A forged token does not bypass that restriction.

Group user members must be current users in that org, including externally marked target users where their existing read permission allows delivery. Group agent choices must already participate in at least one space in the group's org. This avoids inventing agent org membership: agents have `workspace_id`, not `org_id`. Group membership is not an agent invitation. Archived/deletion-scheduled orgs and archived users/agents are unavailable for new management selections and resolution. Existing access/wake/roster checks still decide delivery in each destination space.

Use a new org-scoped group-management view, linked from the appropriate Settings surface, with authorization repeated for every mutation. This does not repurpose install-level `/admin/orgs` as an org-admin surface. A member editor lists only candidates permitted by the rules above; submitting an arbitrary foreign ID fails closed.

## Storage and wire contract

Add `mention_groups` with UUIDv7 identity, org FK, display name, normalized name, creator user FK, timestamps and `deleted_at`. Active normalized names are unique within an org. Names are bounded, nonblank and exclude brackets/newlines. Renames retain the UUID; deletion is a tombstone. Reusing a deleted name creates a different UUID.

Add `mention_group_members` with group FK and exactly one of user FK or agent FK, enforced by a database CHECK. Separate uniqueness indexes prevent duplicate membership. Do not store a `chat_participants.id` as reusable group membership: that row belongs to one space and can be removed.

Emit a namespaced readable token `@[group:<uuid>|<label>]`. UUID is authority; label is display text, never an identity lookup. Render the friendly label with a distinct group icon/type. Preserve the label written with the message through rename/deletion. Treat the entire token as a group token before ordinary name matching; it must not become a person's mention, `here`, a legacy keyword match or a People appearance. Existing individual token syntax remains intact. Document the extension alongside `0037-mention-wire-format.md § Decision` and `0037-mention-wire-format.md § Alternatives considered`.

Add server-owned `chat_message_mention_groups` rows recording message ID, original group UUID and name snapshot. Add `chat_message_group_recipients` rows recording message ID, typed underlying user/agent ID, send-time space participant PK and originating group UUIDs. Unique `(message_id, principal_type, principal_id)` deduplicates overlap. Preserve underlying identity when a participant is deleted; a removed/recreated participant must not gain delayed delivery from an old snapshot.

Recipient rows are written only by the resolver, never accepted from request metadata, structured content or supplied attributes. `Message.changeset/2` currently accepts arbitrary metadata, so a metadata-only authority scheme is unsuitable. Batch-load recipient rows for routing/render/context consumers rather than querying once per participant.

## Send and eligibility

Within each message-creation transaction, resolve authorized group IDs from the message's org and content, snapshot the groups and intersect their members with eligible existing participants. Serialize group-membership updates and snapshot reads on the group row so a concurrent change produces a coherent old or new set. Persist the snapshot before publishing the message event: AttentionRouter reloads the message asynchronously.

Unknown, deleted, foreign-org and unauthorized group tokens are non-delivering references; never resolve by label or expose foreign group details. A visible group with no eligible current members addresses nobody. The composer should show eligible recipient counts for authorized groups, without promising that later access changes cannot prevent delivery.

At dispatch, require that the snapshotted participant is still current, the principal still exists/is active, and current access permits the message. Agents additionally require existing principal/member roster status and the current AgentWake/runtime-owner checks. A snapshot is an upper bound, never a grant. Removed or newly added group members do not change it. An agent added to the space after send does not become an old message recipient.

Keep direct parsing separate: existing explicit individual mentions may still summon when authorized. Group members must not enter `reinvite_and_pin_mentioned/1`, its task-pin propagation or after-the-fact attention's summon writer. Direct plus group overlap still permits the direct mention's existing explicit authorization, then unions the recipient once.

Preserve suppression for `skip_mention_scan`, untrusted inbound, voice records, log-only events and other existing routing early exits. Groups confer no extra route around those gates. For human policies, use the same attention-mode precedence and push preferences as an equivalent individual mention; do not silently rewrite all/active/heartbeat behavior in this feature.

## Edits, history and retries

Resolve groups once when the message is created. Edits never resolve a new group, refresh membership, summon agents, create a new mention inbox row or start a fresh agent turn. Removing/re-adding a group token does not alter the saved addressed audience. A newly typed group in an edit is a reference; sending a new message is required to address new recipients. The editor must communicate this behavior. Original group recipients remain eligible for the existing edit-update/context contract, subject to current access, including retractions that remove the token.

Historical context/freezing must query saved recipients, not the group's current name/membership or SQL matching of the group label. Ordinary message/edit history keeps the original token labels. Learned attention must continue learning individual author choices; group expansion must not train a separate manual choice for every member.

Deduplication here means one resolved recipient per typed identity for one stored message and one fan-out pass, including overlap with direct mentions/reply targets. It is **not** a promise of end-to-end exactly-once execution after a crash or duplicate transport delivery. Existing posts have no request idempotency key; Inbox intentionally allows repeated source triples; AttentionRouter has no durable per-message delivery claim. Retrying a post can create a different message. Preserve and document the existing best-effort delivery boundary; test immutable expansion on replay and expose any duplicate side effects rather than claiming retry safety.

If durable retry suppression is required for #158 acceptance, widen the plan explicitly to a delivery ledger/outbox and consumer acknowledgment contract before implementation. A claim-before-send alone is insufficient: it trades duplicates for lost delivery after a crash. Do not bolt a unique index onto all Inbox producers because their repeated-source semantics are intentional.

Group-originated federation delivery must use a no-invite mode with current membership/read checks. `AttentionDispatch.broadcast/3` currently calls `DispatchMembership.ensure_writable/3`; a removal between context construction and broadcasting can otherwise resurrect the agent. Preserve normal explicit dispatch behavior, while making the group-only path incapable of creating participation. Carry group origin in the signal so a runtime can understand why a message not naming it individually arrived.

## Source map and implementation seams

All paths below are under `apps/platform/`.

| Area | Existing source and required change |
| --- | --- |
| Identity/auth | `lib/platform/tenancy.ex` — `org_admin?/2`, `internal_member?/2`; `tenancy/org_membership.ex`; `agents/agent.ex`; `chat/participant.ex`. New group context owns authorization and typed member validation. |
| Creation | `lib/platform/chat.ex` — `do_post_message/2`, `do_post_message_with_attachments/3`, both existing-attachment post variants. Snapshot inside every transaction before message/v1 publication. Also cover `create_canvas`'s direct message insert, without turning arbitrary canvas content into live group mentions. |
| Direct summon | `chat.ex` — `reinvite_and_pin_mentioned/1`; `chat/mention_identity.ex`. Keep group tokens out. |
| Delivery predicate | `chat/attention_router.ex` — `mentioned?/3`, `extract_mention_tokens/1`, `route_agents_by_activity/5`, human routing. Introduce an explicit addressed-union helper; retain direct predicate for summoning/learning. |
| Inbox/push | `chat.ex` — `emit_inbox_for_mentions/1`, `emit_chat_mention_inbox/4`; existing push checks stay authoritative. |
| Agent/federation | `chat/agent_responder.ex` — `dispatch_to_runtime/2`, external signal; `federation/attention_dispatch.ex` — `broadcast/3`; `chat/dispatch_membership.ex`. Add group-only no-invite transport semantics. |
| Edits/context | `chat.ex` — `eligible_edit_recipients_for_message/1`, `in_context_message_ids_for_agent/2`, `mention_arm_message_ids/2`; `chat/messages/edit.ex`; preserve v1 snapshots. |
| Learning/People | `habits/learned_attention.ex` — `capture_mentions/2`; `people/appearances.ex` — `mention_appearances/1`. Preserve origin; groups are not people. |
| Picker/render | `lib/platform_web/live/chat/mentions_hooks.ex`; its `partials/mention_list.ex`; `assets/js/lib/mention_field.js`; `assets/js/hooks/compose_input.js`; `lib/platform/chat/content_renderer.ex`. Separate friendly chip label from stored token, and add groups only to composer mode, not room-agent or after-send attention pickers. Preserve mobile focus and draft serialization. |
| Entry points | Runtime reply/media and HTTP posting funnel through Chat; prove all four paths share snapshots. Native display/parser compatibility needs inspection/tests before declaring cross-client support. |

## Implementation sequence and verification

1. Add group storage/context authorization and lifecycle tests, including foreign IDs, archived orgs and typed membership constraints.
2. Add token parsing and transactional snapshots across message entry points; demonstrate metadata forgery and membership-change tests failing before implementation.
3. Integrate addressed-recipient union into inbox, routing, edit/context and group-only no-invite federation. Keep learned choices/direct summons unchanged.
4. Add management view and composer/render/native-label compatibility, with JS serialization and LiveView/mobile coverage.
5. Run focused tests, then required `mix precommit` and repository regression gate on the final revision; compare unrelated baseline failures explicitly. Arrange the independent private PR review through Calcifer before public publication.

Minimum matrix: mixed group; duplicate group tokens; overlapping groups/direct mentions/replies; same labels; foreign/forged IDs; absent/removed/archived/denied targets; removal between snapshot and federation broadcast; edits add/remove/re-add; rename/delete/name reuse; unchanged snapshot after membership changes; replay behavior; silence/awake/roster/human policy/push preferences; suppression flags; attachment/thread/canvas/API paths; historical context and learned-attention origin; keyboard/mobile selection and chip hydration.

No application dependencies have been installed and no tests run during this source-only design pass. The worktree is based on current private main; the existing Social design checkout is untouched.
