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
