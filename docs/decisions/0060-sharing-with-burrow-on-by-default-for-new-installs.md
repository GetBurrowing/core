# ADR 0060: Sharing with Burrow, On by Default for New Installs

- **Status:** Proposed. Not approved by the core maintainer.
- **Date:** 2026-11-07
- **Owners:** Team
- **Task:** 01a1b678-8bb4-7000-96d2-c691eb9b13b5 (stage 1 registry, switches and defaults; stage 2
  usage counts; stage 3 agent-filed reports; stage 4 the feedback inbox; stage 5 the owner UI).
  Hosted installs: dependent task 01a1b67c-bee4-7000-be9f-4304ca7fc104.
- **Departs from:** [ADR 0056](0056-supporting-customer-installs.md) B.1 ("Default: OFF"). 0056 is
  not edited.
- **Related:** [ADR 0053](0053-install-manifest-and-renderers.md)

## Context

An install can send four things to the vendor: feedback a person or agent sends, anonymous usage
counts, agent friction reports, and bug reports posted in Help & feedback. ADR 0056 B.1 makes
out-of-band reporting opt-in. Opt-in left the vendor with almost no signal about what installs
need.

## Decision

People are named by role here because the tree carries no person names
(`InstallIdentityGuardTest`); task 01a1b678 names them.

1. **The sponsor directed ON by default for new installs (2026-11-07).** The core maintainer has
   not approved this. This record states the direction and the departure; it does not record an
   approval, and no other tracked file may claim one.
2. **The departure from 0056 B.1** is the same kind task 01a1b362 made for vendor support access:
   a switch the install owner controls, seeded on for new installs only, and never flipped on for an
   install that already exists.
3. **One registry, as data.** `Platform.Sharing.registry/0` lists every part with its title,
   plain description, exactly what is sent, and its new-install default. Each part has its own
   switch in the `install_sharing` singleton row. Support access (01a1b362) and automatic updates
   (01a1b35d) each add one entry later.
4. **New installs only.** The self-host installer's `setup init` writes `[sharing]` with all four
   keys explicitly true into a NEW manifest. An absent key renders exactly what it rendered before,
   so existing manifests are unchanged. The row is seeded once from `FEEDBACK_POLICY`,
   `USAGE_COUNTS`, `FRICTION_REPORTS` and `HELP_CHANNEL_REPORTS`. Unset means off. After that the
   row wins, so re-rendering can never flip a switch.
5. **Existing installs are untouched** until automatic updates (01a1b35d) gives them a path to
   receive the new defaults with the owner's disclosure.
6. **The feedback inbox (stage 4) is a core page on the broker-host install**, not GitHub labels
   plus a view:
   - the broker host already holds the shared `feedback_submissions` ledger, where every install's
     submissions dedupe to one fingerprint;
   - counting distinct installs needs a per-install key, and putting that key on labels in the
     public repository would publish it;
   - it needs no new service and no new credential.
7. **Friction knobs are data** (`config :platform, :friction_reports`: threshold 3, window 7
   days, a per-install weekly cap), so they can be tuned without a code change.

## Exactly what is sent

### Anonymous usage counts (stage 2)

When `usage_counts` is on, the install sends one batch per window (hourly by default,
`config :platform, Platform.Sharing.UsageBatcher, interval_ms`) to `<broker base>/usage`, the same
broker base every feedback submission uses. The body is:

```json
{"sharing_install_id": "<random uuid>", "window": {"start": 1762531200, "seconds": 3600},
 "counts": {"message.posted": 41, "meeting.started": 2}}
```

`counts` holds only names from this pinned list (`Platform.Sharing.UsageEvents.events/0`), each a
non-negative integer:

| Sent as | Counted from (`:telemetry`) |
|---|---|
| `message.posted` | `[:platform, :chat, :message_posted]`, posts by people and agents |
| `message.edited` | `[:platform, :chat, :message_edited]` |
| `message.deleted` | `[:platform, :chat, :message_deleted]` |
| `thread.created` | `[:platform, :chat, :thread_created]` |
| `reaction.added` | `[:platform, :chat, :reaction_added]` |
| `pin.added` | `[:platform, :chat, :pin_added]` |
| `canvas.created` | `[:platform, :chat, :canvas_created]` |
| `space.created` | `[:platform, :chat, :space_created]` |
| `meeting.started` | `[:burrow, :interaction, :meeting_started]` |
| `meeting.transcription_failed` | `[:platform, :meetings, :transcription_failed]` (a drop-off point) |
| `access.blocked` | `[:platform, :auth, :access_blocked]` (a drop-off point) |

Never sent: message content, names, emails, space or agent names, ids of people, spaces or agents,
or any free text. The collector reads the event name only, never its metadata. Before a batch
leaves, the scrubber drops any unpinned name and any value that is not a non-negative integer,
runs `Platform.Feedback.Redaction.redact/1` over the encoded body, and refuses the batch if it
finds email-shaped text or any string other than the install id, the pinned names and the body's
own keys. Turning the switch off drops every pending count; nothing counted before is sent.

The broker host stores the counts per window in `sharing_usage_counts`, keyed by the sharing
install id, and refuses any body with an unpinned name, a non-integer, or an extra key.

**One emission family.** User-choice interactions emit ONE `:telemetry` family,
`[:burrow, :interaction, ...]`, which both these counts and the learned-defaults work (task
01a1b6a1) consume; there is no second emission framework. `meeting.started` is the first event
in that family. A new pinned event means one entry in `UsageEvents`, one literal in
`Platform.Sharing.UsageEventsTest` and one row in this table.

## The feedback inbox and shipped notices (stage 4)

The inbox is `/admin/feedback-inbox` on the broker-host install. It answers 404 unless the node
runs the broker (`FEEDBACK_BROKER_SERVER`) and the viewer is a root-org admin.

- **Distinct installs.** Each install's broker request carries its random `sharing_install_id`.
  The broker records one row per (fingerprint, sharing install id) in `feedback_inbox_installs`,
  so the same install sending a report twice counts once. A missing or malformed id counts no
  install. The id never leaves the broker host.
- **Titles.** `feedback_inbox_requests` keeps the sanitized title per fingerprint: the same
  redacted text the public issue already carries.
- **Shipped.** A signed GitHub `issues` delivery that closes a feedback-repository issue as
  `completed` marks its requests shipped. `reopened` clears it. `GET /issues/:fingerprint` answers
  `shipped`.
- **The notice.** On each usage-batch cycle a reporting install asks about its own published
  fingerprints only, and posts one in-app notice (a system row in `--color-info`) to whoever filed:
  the person, in their conversation with Burrow, or the agent, in the space it filed from. It
  follows the feedback switch.

## Who asked, decided by the server (stage 4)

A tool call carries only what the agent chose to send. So `Platform.Federation.DispatchOrigin`
remembers, for each runtime, the space and the person behind every chat attention sent to it in the
last ten minutes. The tool context gets both:

- `sharing_set` authorizes the person who asked, not the agent's owner. The one person whose message
  reached the agent in the window must be a root-org admin. With no one, or with two different
  people, the call is refused. The audit row names that person and the agent.
- The Help & feedback gate on `feedback_submit` checks every recent originating space as well as the
  optional `space_id`, so leaving `space_id` out cannot skip the gate.

## Revisit trigger

When the install count reaches 20, revisit every sharing and access default. This trigger lives
in this document only, not in code.

## Consequences

- An owner sees every part in plain words and can turn each off in one tap. Owner-facing copy never
  says "telemetry" or "analytics".
- `Platform.Feedback.Policy.enabled?/0` now also requires the owner's feedback switch.
  `FEEDBACK_POLICY` stays the operator's capability; the switch sits on top.
- The sharing install id is random (UUIDv4), is not the federation install id, and is linked to
  no account.
