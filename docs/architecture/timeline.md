# Architecture Timeline

Append-only log of architecture-relevant landings — one line per ADR-flagged
task that shipped. Entries are appended automatically by
`Platform.Responsibilities.TimelineAppender` when a task with
`metadata.adr_flag == true` transitions to `done`; backfill entries below
predate the auto-append helper (ADR-0044 stage 5) and were mined from
`git log --grep="ADR-004"`.

## Format

```
- YYYY-MM-DD | ADR-XXXX | PR #NNN | task-uuid | one-line description
```

`PR #NNN` may be `-` for entries that landed on a stack rollup branch
without a per-task PR (see `[Stack rollup ship]` in ORG_MEMORY). Task
uuid may be truncated to the first 8 characters when the full uuid is
recorded elsewhere in the commit trailer.

## Entries

- 2026-07-08 | ADR-0044 | PR pending | 019f3da3 | Architect responsibility bundle — plan-review + drift-audit + weekly cron sweep + timeline auto-append
- 2026-07-02 | ADR-0042 | PR #475 | 019f2c86 | Task Sponsor field: nullable human shepherd distinct from technical assignee
- 2026-07-02 | ADR-0042 | PR #472 | - | ADR 0042 shipped — Task Sponsor as human shepherd distinct from current-phase assignee
- 2026-06-25 | ADR-0041 | PR #461 | 019e9014 | Responsibilities M8 — Hal + meetings.summarize migrated to declarative framework
- 2026-05-04 | ADR-0041 | PR #453 | 019e2a45 | Responsibilities M1 — registry + provider behaviour landed as stack

## Auto-append contract

Every task transition to `done` that carries `metadata: %{"adr_flag" => true, "adr_number" => "0044", "pr_number" => "492"}` (or the string-keyed equivalents) gets one line appended by
`Platform.Responsibilities.TimelineAppender.maybe_append/1`. The helper is
guarded behind `try/rescue` — a filesystem write failure never stalls the
task transition.

To backfill from git log:

```bash
git log --grep="ADR-004" --oneline --pretty=format:"%h %ad | %s" --date=short
```

Then pick the ADR number, PR number (from `(#NNN)` in the subject), and
task uuid from either the commit trailer or the parenthesised `(019f...)`
short-id and add a line above.
