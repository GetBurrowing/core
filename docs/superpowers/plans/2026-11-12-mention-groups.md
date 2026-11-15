# Mention Groups Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for continuous integration. Independent storage and UI tasks may be delegated; Calcifer arranges the single independent private-PR review requested in the assignment.

**Goal:** Address eligible existing human/agent participants through reusable org groups, without granting access.

**Architecture:** Store stable groups and typed memberships. Snapshot resolved recipients transactionally at initial message creation; delivery unions that saved audience with ordinary individual mentions, preserving origin and current access gates. No edit expansion or durable exactly-once delivery extension.

**Tech Stack:** Existing Phoenix/LiveView, Ecto/PostgreSQL and composer JavaScript. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-12-mention-groups-design.md`, accepted by Calcifer with explicit same-org membership checks for external human recipients.

## Global constraints

- One private integration branch: `feat/mention-groups`, based on `ae7018c7`.
- No implicit participation, access, history grants or task pins from group recipients.
- Exact-org internal admins manage; external actors cannot discover/use; eligible same-org external human targets can receive.
- Snapshot once at creation. Edits never expand or notify a new group audience.
- Existing best-effort transport semantics; no outbox/global Inbox uniqueness changes.
- Keep all work in this checkout; no HTC material or code.

## Review focus

1. Removal after routing but before federation broadcast must not restore participation (Task 3 race test).
2. Client metadata cannot forge group recipients (Task 2 forged-attributes test).
3. A group chip must round-trip draft/edit state without losing its UUID (Task 4 JS test).
4. An external human recipient who loses org membership cannot receive even if still a space participant (Task 2/3 revocation tests).
5. A new group pasted into an edit must not address anybody, and retractions must preserve authorized original edit recipients (Task 3 edit tests).

## Shared interfaces

All Elixir paths below are under `apps/platform/`.

`Platform.Chat.GroupMentionToken`: `encode(id, name) :: String.t`, `parse(content) :: [%{id: uuid, name: string}]`, `strip(content) :: String.t`. Token is `@[group:<uuid>|<label>]`; ordinary mentions retain their format. Invalid group namespace tokens never become individual mentions.

`Platform.Chat.MentionGroups`: `list_groups(actor, org_id)`, `get_group(actor, id)`, `create_group(actor, org_id, attrs)`, `update_group(actor, id, attrs)`, `archive_group(actor, id)`, `list_candidates(actor, org_id)`. Each returns `{:ok, result} | {:error, reason}`. `attrs` contains `name` and optional `members: [%{type: "user" | "agent", id: uuid}]`, accepting string or atom keys. `groups_for_space(space, author_participant)` returns authorized groups for composer suggestions. Candidate maps contain `type`, `id`, `name`; groups expose `id`, `org_id`, `name`, `members`.

`Platform.Chat.GroupMentions`: `capture!(message)` writes initial snapshots inside caller transaction and returns a loaded Message; `load(message)` attaches persisted snapshots; `recipient?(participant, message)` checks immutable target identity/participant and current group-specific eligibility; `in_context_message_ids(participant, space_id)` returns a MapSet. `Message` virtual fields: `group_mentions` and `group_mention_recipients`, default nil. Snapshot rows remain authoritative, not input metadata. `load` batches rows for one message; consumers avoid per-recipient reloads.

`AttentionRouter.mentioned?/3` stays the individual-only predicate. New `addressed?/3` unions direct mention and `GroupMentions.recipient?/2` for delivery/edit consumers. Group-origin is retained for no-invite federation and learned choices.

## Task 1: Storage and authorized management

**Files:** new migration, `lib/platform/chat/mention_group.ex`, `mention_group_member.ex`, `mention_groups.ex`; `test/platform/chat/mention_groups_test.exs`.

- [ ] Write tests asserting exact-org internal-admin CRUD; reject member/external/foreign-org writes; reject duplicate normalized names and invalid typed members; archive retains stable identity; recipient candidate directory does not leak foreign principals.
- [ ] Run focused test, observe missing feature failure; implement schemas, constraints and context without dependencies.
- [ ] Run focused tests green. Record command/result in execution ledger.

## Task 2: Tokens and immutable snapshots

**Files:** new `group_mention_token.ex`, `group_mentions.ex`, snapshot schemas/migration; `lib/platform/chat/message.ex`; new token/snapshot tests.

- [ ] Write token round-trip and group namespace isolation tests.
- [ ] Write transactional snapshot tests: overlapping groups one typed recipient; exclude absent/archived/foreign/denied targets and external authors; client metadata ignored; membership/rename/delete cannot mutate captured audience; participant removal/rejoin cannot revive old delivery.
- [ ] Observe tests fail, then implement interfaces above. Snapshot/admin membership updates lock group rows coherently.
- [ ] Run focused tests green; verify current-org membership revocation after capture is respected.

## Task 3: Posting, routing and no-invite transport

**Files:** `lib/platform/chat.ex`, `chat/attention_router.ex`, `chat/agent_responder.ex`, `federation/attention_dispatch.ex`, `chat/dispatch_membership.ex` only if necessary; `chat/messages/edit.ex`; `habits/learned_attention.ex`; `people/appearances.ex`; focused integration/federation tests.

- [ ] Write tests for all four Chat post variants, direct/group/reply overlap, suppression flags, edit no-expansion, historical context, no learned individual choices from group expansion.
- [ ] Observe failures. Call capture inside each creation transaction before v1/publish; cover direct canvas message creation where its generated message contains a group token.
- [ ] Add `addressed?/3` at intended consumers only; preserve existing attention-mode/push preferences, author exclusion, AgentWake and roster checks.
- [ ] Add a federation membership mode `:existing_only`, requiring current exact participant/read scope and never calling an invite writer. Default existing dispatch remains unchanged. Group-only origin selects it.
- [ ] Mandatory test: capture then remove target before federation broadcast; no broadcast and no participant recreation. Check denied read and archived org/space as well.
- [ ] Verify current authorized original recipients receive edit updates after group token removal; new groups in edits create no snapshots/inbox/invocation.
- [ ] Run focused tests; record known baseline/retry boundaries without claiming exactly-once.

## Task 4: Management, picker and readable group chips

**Files:** new management LiveView/tests; router/ModuleGate/Settings link; `mentions_hooks.ex`, `partials/mention_list.ex`, `assets/js/lib/mention_field.js`, `assets/js/hooks/compose_input.js`, `chat/content_renderer.ex`; JS/LiveView/render tests; native label parser sites if present.

- [ ] Write JS test for friendly label + stable token hydration/serialization, and normal-name compatibility; run red before implementation.
- [ ] Write LiveView tests for authorized CRUD, distinct group suggestion, no external discovery, thread composer and exclusion from room-agent/after-send attention modes; run red.
- [ ] Implement shared context APIs and typed suggestion. Editor copy: “Group recipients are set when a message is sent. Send a new message to notify a new group.”
- [ ] Preserve mobile focus wrapper/keyboard behavior and verify existing mention geometry tests.
- [ ] Inspect native rendering compatibility; state native/browser checks not run where no usable environment exists.

## Task 5: Integration gates and private PR

- [ ] Run the combined focused suites and asset suite after integration.
- [ ] Run `mix precommit`, format check, warnings-as-errors compile and applicable repository regression gate on final code. Record exact failures and compare baseline when needed.
- [ ] Self-review final diff for snapshot authority, current access and no-invite paths; fix with failing regression tests.
- [ ] Commit/push only the private feature branch and open private PR with evidence and explicit coverage limits. Calcifer arranges the single independent review before public publication.

## Execution ledger

- Design accepted by Calcifer; external recipient distinction recorded. Starting source baseline `ae7018c7`; product changes not yet started.
- Ruling: no additional approval handoff for this plan expansion — Calcifer explicitly authorized proceeding with the written sequence on the isolated branch; the tasks refine that same accepted sequence.
- Token tests: standalone Elixir observed missing-module RED (2 failures), then GREEN; added invalid-label regression RED then GREEN, 3 tests pass. Database/UI tests authored before their implementation.
- Local setup: dependencies fetched using writable Mix/Hex homes and the Homebrew CA bundle; native `erlexec` compile stops at missing Command Line Tools/xcrun. No local PostgreSQL service. Node fails its system OpenSSL read; not retried/bypassed. Walter has offered his working compiler/test runner; exact checkpoint sent before further edits.
- Walter baseline at `ae7018c7`: 59 passed, zero failures. At `67194ba6`, database/token/federation: 4/20 pass; UI/render: 92/101 pass; JS: 81/85 pass. Expected missing-feature failures, no setup/fixture/compile errors. At tests-only `6a7fca18`: 70/77 pass, expected missing context/module-gate/push-label failures.
- First integrated implementation written after those RED results. New edge-case tests intentionally await their first execution before fixes: exclude author in eligible counts; exclude deleted history context; keep Markdown group labels readable. Local syntax and whitespace checks run; integrated compile/tests not yet verified. Walter receives an exact immutable checkpoint for the next pass.
- Walter at `c9160aaa`: warnings-as-errors compilation passed; JS 85/85; DB/token/delivery/federation 23/28; UI/render/push/gate 171/174. Three intended regressions reproduced. Five additional failures traced to fixture setup (router/store processes, missing participant join time, and asserting a LiveView redirect where the existing external HTTP plug halts with 403).
- Applied author-count and deleted-context fixes. Real Earmark renderer probe reproduced Markdown label splitting, then passed after opaque token protection/restoration; a separate real parser probe reproduced URL preview extraction from a group label, then passed after excluding group tokens. Added escaped-label coverage. Corrected fixture setup while retaining a successful admin-route control. Added real responder and router signal tests for group-only transport selection; these await the next runner pass.
- Applied Walter's formatter-only `421db10d` as `4257a258` (HEEx wrapping only). Native/browser manual coverage remains unrun. Local full application compilation remains unavailable; do not retry refused cache or Node reads.
